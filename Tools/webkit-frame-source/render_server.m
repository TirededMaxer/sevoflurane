#import "render_server.h"
#import <objc/message.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

// Declarative ABI and key provenance, pinned WebKit revision 7b548466:
// https://github.com/WebKit/WebKit/blob/7b548466/Source/WebCore/PAL/pal/spi/cocoa/QuartzCoreSPI.h
// iOS examples only (not a macOS implementation guarantee):
// https://github.com/WebKit/WebKit/blob/7b548466/Source/WebKit/UIProcess/API/ios/WKWebViewIOS.mm#L1323
// https://github.com/WebKit/WebKit/blob/7b548466/Source/WebKit/UIProcess/API/ios/WKWebViewIOS.mm#L4622
// The latter synchronizes then immediately creates a CG image reference:
// https://github.com/WebKit/WebKit/blob/7b548466/Source/WebCore/platform/graphics/cocoa/IOSurface.mm#L630
// This is not an explicit CPU-read fence contract for the macOS implementation.
// Runtime macOS acceptance still requires the fixture's unchanged pixel oracles.
typedef bool (*SnapshotFunction)(mach_port_t,NSDictionary *);

static NSString *snapshotString(const char *name) {
    const CFStringRef *address=(const CFStringRef *)dlsym(RTLD_DEFAULT,name);
    if (!address || !*address || CFGetTypeID(*address)!=CFStringGetTypeID()) return nil;
    return (__bridge NSString *)*address;
}

@implementation RenderServerFrameSource {
    __weak NSView *_sourceView;
    SnapshotFunction _snapshot;
    NSDictionary<NSString *,NSString *> *_keys;
    NSArray<NSString *> *_missing;
    NSString *_lastError;
    BOOL _available, _rendering, _lastSnapshotSucceeded;
    uint64_t _attempts, _successes;
    uint32_t _lastContextID;
}
@synthesize available=_available,lastError=_lastError;

- (instancetype)initWithSourceView:(NSView *)sourceView {
    if (!(self=[super init])) return nil;
    _sourceView=sourceView;
    _snapshot=(SnapshotFunction)dlsym(RTLD_DEFAULT,"CARenderServerSnapshot");
    NSMutableArray<NSString *> *missing=[NSMutableArray new];
    if (!_snapshot) [missing addObject:@"CARenderServerSnapshot"];
    const char *names[]={"kCASnapshotMode","kCASnapshotModeLayer","kCASnapshotDisplayName",
        "kCASnapshotContextId","kCASnapshotLayerId","kCASnapshotDestination",
        "kCASnapshotOriginX","kCASnapshotOriginY","kCASnapshotTransform","kCASnapshotTimeOffset"};
    NSMutableDictionary<NSString *,NSString *> *keys=[NSMutableDictionary new];
    for (size_t i=0;i<sizeof(names)/sizeof(names[0]);i++) {
        NSString *name=@(names[i]),*value=snapshotString(names[i]);
        if (value) keys[name]=value; else [missing addObject:name];
    }
    if (![CATransaction respondsToSelector:NSSelectorFromString(@"synchronize")])
        [missing addObject:@"CATransaction.synchronize"];
    _keys=[keys copy];_missing=[missing copy];_available=_snapshot && !missing.count;
    if (!_available) _lastError=@"render-server-spi-unavailable";
    return self;
}

- (NSDictionary<NSString *,id> *)metadata {
    return @{@"available":@(_available),@"missing_symbols_or_selectors":_missing,
        @"last_error":_lastError ?: (id)NSNull.null,@"attempts":@(_attempts),@"successes":@(_successes),
        @"last_snapshot_succeeded":@(_lastSnapshotSucceeded),@"last_context_id":@(_lastContextID),
        @"source_scope":@"bound-source-view-layer-only",@"source_geometry_modified":@NO,
        @"macos_experimental":@YES,@"cpu_completion_proven":@NO,
        @"synchronization_evidence":@"WebKit-iOS-immediate-CG-image-reference;CPU-completion-unproven",
        @"provenance_revision":@"7b548466"};
}

- (BOOL)fail:(NSString *)reason {
    _lastError=reason;_lastSnapshotSucceeded=NO;return NO;
}

- (BOOL)renderLayer:(CALayer *)source toSurface:(IOSurfaceRef)destination
            scaleX:(CGFloat)scaleX scaleY:(CGFloat)scaleY {
    if (!NSThread.isMainThread) return [self fail:@"render-requires-main-thread"];
    if (_rendering) return [self fail:@"render-reentrant-call"];
    _attempts++;_lastContextID=0;_lastSnapshotSucceeded=NO;
    if (!_available) return [self fail:@"render-server-spi-unavailable"];
    NSView *view=_sourceView;
    if (!view || !view.window || source!=view.layer)
        return [self fail:@"source-is-not-bound-window-attached-view-layer"];
    if (!destination || !isfinite(scaleX) || !isfinite(scaleY) || scaleX<=0 || scaleY<=0)
        return [self fail:@"invalid-destination-or-scale"];
    size_t width=IOSurfaceGetWidth(destination),height=IOSurfaceGetHeight(destination);
    size_t rowBytes=IOSurfaceGetBytesPerRow(destination),allocation=IOSurfaceGetAllocSize(destination);
    if (!width || !height || width>SIZE_MAX/4 || rowBytes<width*4 || height>SIZE_MAX/rowBytes ||
        allocation<rowBytes*height || IOSurfaceGetPlaneCount(destination)!=0 ||
        IOSurfaceGetBytesPerElement(destination)!=4 || IOSurfaceGetPixelFormat(destination)!=UINT32_C(0x42475241))
        return [self fail:@"destination-bgra-layout-invalid"];
    SEL contextSelector=NSSelectorFromString(@"context"),contextIDSelector=NSSelectorFromString(@"contextId");
    if (![source respondsToSelector:contextSelector]) return [self fail:@"source-layer-context-unavailable"];
    _rendering=YES;
    @try {
        [CATransaction flush];
        ((void (*)(id,SEL))objc_msgSend)(CATransaction.class,NSSelectorFromString(@"synchronize"));
        if (view.layer!=source || !view.window)
            return [self fail:@"source-detached-during-synchronization"];
        id context=((id (*)(id,SEL))objc_msgSend)(source,contextSelector);
        if (!context || ![context respondsToSelector:contextIDSelector])
            return [self fail:@"own-source-context-id-unavailable"];
        uint32_t contextID=((uint32_t (*)(id,SEL))objc_msgSend)(context,contextIDSelector);
        if (!contextID) return [self fail:@"own-source-context-id-zero"];
        _lastContextID=contextID;
        // CPU write synchronization is symmetric. Do not retain a CPU lock
        // across render-server access, and never inspect the surface on failure.
        kern_return_t lock=IOSurfaceLock(destination,0,NULL);
        if (lock!=KERN_SUCCESS) return [self fail:@"destination-write-lock-failed"];
        void *base=IOSurfaceGetBaseAddress(destination);
        if (base) memset(base,0,rowBytes*height);
        kern_return_t unlock=IOSurfaceUnlock(destination,0,NULL);
        if (unlock!=KERN_SUCCESS) return [self fail:@"destination-write-unlock-failed"];
        if (!base) return [self fail:@"destination-write-base-unavailable"];
        CATransform3D transform=CATransform3DMakeScale(scaleX,scaleY,1);
        NSDictionary<NSString *,NSString *> *k=_keys;
        // defaultDisplay is the exact WebKit macro value, not an enumerated
        // display or a guessed context. No secure/mask/ignore overrides are set.
        NSDictionary *options=@{k[@"kCASnapshotMode"]:k[@"kCASnapshotModeLayer"],
            k[@"kCASnapshotDisplayName"]:@"defaultDisplay",k[@"kCASnapshotContextId"]:@(contextID),
            k[@"kCASnapshotLayerId"]:@((uint64_t)(uintptr_t)(__bridge void *)source),
            k[@"kCASnapshotDestination"]:(__bridge id)destination,
            k[@"kCASnapshotOriginX"]:@0,k[@"kCASnapshotOriginY"]:@0,
            k[@"kCASnapshotTransform"]:[NSValue valueWithCATransform3D:transform],k[@"kCASnapshotTimeOffset"]:@0};
        if (!_snapshot(MACH_PORT_NULL,options)) return [self fail:@"render-server-snapshot-returned-false"];
        _lastError=nil;_lastSnapshotSucceeded=YES;_successes++;return YES;
    } @catch (NSException *exception) {
        (void)exception;return [self fail:@"render-server-source-snapshot-exception"];
    } @finally {
        _rendering=NO;
    }
}
@end
