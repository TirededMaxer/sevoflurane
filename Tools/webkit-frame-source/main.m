#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "frame_checks.h"

static const double CSSWidth = 768, CSSHeight = 480;
static const char *RegionNames[] = {"css_motion","scroll","canvas2d","webgl","video"};
static double milliseconds(CFTimeInterval a, CFTimeInterval b) { return (b-a)*1000; }
static NSArray *bgra(uint32_t p) { return @[@(p&255),@((p>>8)&255),@((p>>16)&255),@(p>>24)]; }
static id finiteValue(CGFloat n) { return isfinite(n) ? @(n) : (id)NSNull.null; }
static NSArray *rectValues(CGRect r) { return @[finiteValue(r.origin.x),finiteValue(r.origin.y),finiteValue(r.size.width),finiteValue(r.size.height)]; }

// Official WebKit 7b548466 WKWebViewPrivate.h / WKWebViewMac.mm signatures.
// These are gated diagnostic SPI, confined to this synthetic WK instance.
@interface WKWebView (FixtureDiagnosticSPI)
- (void)_setDrawsBackground:(BOOL)value;
- (BOOL)_drawsBackground;
- (void)_setWindowOcclusionDetectionEnabled:(BOOL)value;
- (BOOL)_windowOcclusionDetectionEnabled;
@end

static NSDictionary *layerInventory(CALayer *root) {
    NSMutableArray *nodes=[NSMutableArray new],*pending=[NSMutableArray new];
    NSMutableDictionary *counts=[NSMutableDictionary new];BOOL truncated=NO;
    if (root) [pending addObject:@{@"object":root,@"parent":@(-1),@"depth":@0}];
    for (NSUInteger cursor=0;cursor<pending.count && nodes.count<128;cursor++) {
        NSDictionary *item=pending[cursor];CALayer *layer=item[@"object"];
        NSUInteger index=nodes.count,depth=[item[@"depth"] unsignedIntegerValue];
        NSString *className=NSStringFromClass(layer.class);id contents=layer.contents;
        counts[className]=@([counts[className] unsignedIntegerValue]+1);
        [nodes addObject:@{@"index":@(index),@"parent":item[@"parent"],@"depth":@(depth),@"class":className,
            @"bounds":rectValues(layer.bounds),@"frame":rectValues(layer.frame),@"hidden":@(layer.hidden),
            @"opacity":finiteValue(layer.opacity),@"opaque":@(layer.opaque),@"contents_scale":finiteValue(layer.contentsScale),
            @"contents_class":contents ? NSStringFromClass([contents class]) : (id)NSNull.null}];
        NSArray<CALayer *> *children=layer.sublayers;
        if (depth>=12) { if (children.count) truncated=YES;continue; }
        for (CALayer *child in children) {
            if (pending.count>=128) { truncated=YES;break; }
            [pending addObject:@{@"object":child,@"parent":@(index),@"depth":@(depth+1)}];
        }
    }
    return @{@"limit":@128,@"max_depth":@12,@"truncated":@(truncated),@"class_counts":counts,@"nodes":nodes};
}
static NSDictionary *viewInventory(NSView *root) {
    NSMutableArray *nodes=[NSMutableArray new],*pending=[NSMutableArray new];BOOL truncated=NO;
    if (root) [pending addObject:@{@"object":root,@"parent":@(-1),@"depth":@0}];
    for (NSUInteger cursor=0;cursor<pending.count && nodes.count<64;cursor++) {
        NSDictionary *item=pending[cursor];NSView *view=item[@"object"];
        NSUInteger index=nodes.count,depth=[item[@"depth"] unsignedIntegerValue];
        [nodes addObject:@{@"index":@(index),@"parent":item[@"parent"],@"depth":@(depth),@"class":NSStringFromClass(view.class),
            @"bounds":rectValues(view.bounds),@"frame":rectValues(view.frame),@"hidden":@(view.hidden),
            @"hidden_ancestor":@(view.isHiddenOrHasHiddenAncestor),
            @"layer_class":view.layer ? NSStringFromClass(view.layer.class) : (id)NSNull.null}];
        if (depth>=12) { if (view.subviews.count) truncated=YES;continue; }
        for (NSView *child in view.subviews) {
            if (pending.count>=64) { truncated=YES;break; }
            [pending addObject:@{@"object":child,@"parent":@(index),@"depth":@(depth+1)}];
        }
    }
    return @{@"limit":@64,@"max_depth":@12,@"truncated":@(truncated),@"nodes":nodes};
}

@interface PassivePanel : NSPanel @end
@implementation PassivePanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface SurfaceSlot : NSObject
@property(nonatomic) IOSurfaceRef surface;
@property(nonatomic,strong) id<MTLTexture> texture;
@property(nonatomic,strong) id<MTLBuffer> completionByte;
@property(nonatomic) uint8_t *copy;
@property(nonatomic) size_t copySize;
@end
@implementation SurfaceSlot
- (void)dealloc { if (_surface) CFRelease(_surface); free(_copy); }
@end

@interface Phase : NSObject {
@public
    uint64_t frames, contentFailures, generationFailures, tearing, backwards;
    uint64_t transitions, duplicateFrames, orientationFailures, orientationChanges;
    uint64_t sourceReparentedFrames;
    uint64_t regionChanges[FC_REGION_COUNT], previousRegions[FC_REGION_COUNT];
    uint64_t occludedSamples, visibleSamples, hiddenSamples, activeSamples, lockFailures, gpuErrors;
    uint16_t lastGeneration;
    int firstOrientation;
    CFTimeInterval start, end;
}
@property(nonatomic,copy) NSString *name;
@property(nonatomic,strong) NSMutableArray<NSArray<NSNumber *> *> *timings;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *examples;
@property(nonatomic,strong) NSDictionary *inventory;
- (NSDictionary *)report;
@end
@implementation Phase
- (instancetype)init {
    if ((self=[super init])) { _timings=[NSMutableArray new];_examples=[NSMutableArray new];firstOrientation=-1; }
    return self;
}
- (NSDictionary *)report {
    NSMutableDictionary *metrics=[NSMutableDictionary new];
    NSArray *names=@[@"submission_ms",@"gpu_wait_ms",@"lock_ms",@"copy_ms",@"total_ms"];
    size_t n=self.timings.count;
    for (NSUInteger c=0;c<names.count;c++) {
        double *values=calloc(n ?: 1,sizeof(double));
        for (size_t i=0;i<n;i++) values[i]=self.timings[i][c].doubleValue;
        metrics[names[c]]=n ? @{@"p50":@(fc_percentile(values,n,.5)),@"p95":@(fc_percentile(values,n,.95))} : (id)NSNull.null;
        free(values);
    }
    NSMutableDictionary *changes=[NSMutableDictionary new]; BOOL allChanged=YES;
    for (int i=0;i<FC_REGION_COUNT;i++) {
        changes[@(RegionNames[i])]=@(regionChanges[i]);
        if (regionChanges[i]<2) allChanged=NO;
    }
    double duration=MAX(0,end-start);
    BOOL pass=frames>=8 && transitions>=8 && contentFailures==0 && generationFailures==0 &&
        tearing==0 && backwards==0 && orientationFailures==0 && orientationChanges==0 &&
        lockFailures==0 && gpuErrors==0 && sourceReparentedFrames==0 && allChanged;
    if ([self.name isEqual:@"visible"] && visibleSamples<8) pass=NO;
    if ([self.name isEqual:@"self_occluded"] && occludedSamples<8) pass=NO;
    if ([self.name isEqual:@"app_hidden"] && (hiddenSamples<8 || occludedSamples<8)) pass=NO;
    return @{@"name":self.name,@"passed":@(pass),@"duration_s":@(duration),
        @"frames":@(frames),@"distinct_generation_transitions":@(transitions),
        @"distinct_generation_fps":@(duration>0 ? transitions/duration : 0),
        @"duplicate_frames":@(duplicateFrames),@"content_failures":@(contentFailures),
        @"generation_failures":@(generationFailures),@"tearing":@(tearing),@"backwards":@(backwards),
        @"orientation_failures":@(orientationFailures),@"orientation_changes":@(orientationChanges),
        @"source_reparented_frames":@(sourceReparentedFrames),
        @"raw_bottom_up":firstOrientation<0 ? (id)NSNull.null : @(firstOrientation==1),
        @"region_changes":changes,@"lock_failures":@(lockFailures),@"gpu_errors":@(gpuErrors),
        @"source_visible_samples":@(visibleSamples),@"source_occluded_samples":@(occludedSamples),
        @"app_hidden_samples":@(hiddenSamples),@"app_active_samples":@(activeSamples),
        @"timings":metrics,@"first_samples":self.examples,@"own_fixture_inventory":self.inventory ?: (id)NSNull.null};
}
@end

@interface Fixture : NSObject <NSApplicationDelegate,WKScriptMessageHandler,WKNavigationDelegate,NSWindowDelegate>
@property(nonatomic,strong) PassivePanel *window;
@property(nonatomic,strong) PassivePanel *cover;
@property(nonatomic,strong) WKWebView *web;
@property(nonatomic,strong) id<MTLDevice> device;
@property(nonatomic,strong) id<MTLCommandQueue> queue;
@property(nonatomic,strong) CARenderer *renderer;
@property(nonatomic,strong) CALayer *pixelRoot;
@property(nonatomic,strong) CALayer *logicalCarrier;
@property(nonatomic,strong) NSArray<SurfaceSlot *> *slots;
@property(nonatomic,strong) NSMutableArray<Phase *> *phases;
@property(nonatomic,strong) NSMutableArray<NSString *> *errors;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,copy) NSString *outputDirectory;
@property(nonatomic,strong) NSDictionary *readyStatus;
@property(nonatomic,strong) NSDictionary *diagnosticSPI;
@property(nonatomic) FCGeometry geometry;
@property(nonatomic) CFTimeInterval launched, readyTime;
@property(nonatomic) BOOL ready, inFlight, finishing, written;
@property(nonatomic) NSUInteger nextSlot, skippedBusy;
- (void)finish;
- (void)beginPhase:(NSString *)name;
- (void)tick;
- (BOOL)prepareRenderer;
- (void)writeReportAndExit;
- (void)configureDiagnosticSPI;
@end

@implementation Fixture
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    self.launched=CACurrentMediaTime(); self.errors=[NSMutableArray new];self.phases=[NSMutableArray new];
    char directory[]="/tmp/sevo-webkit-frame-source-XXXXXX";
    if (!mkdtemp(directory)) { fprintf(stderr,"fixture: cannot create private temporary directory\n");exit(2); }
    self.outputDirectory=@(directory);
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    WKWebViewConfiguration *config=[WKWebViewConfiguration new];
    config.websiteDataStore=WKWebsiteDataStore.nonPersistentDataStore;
    config.mediaTypesRequiringUserActionForPlayback=WKAudiovisualMediaTypeNone;
    config.allowsAirPlayForMediaPlayback=NO;
    [config.userContentController addScriptMessageHandler:self name:@"fixture"];
    self.web=[[WKWebView alloc] initWithFrame:NSMakeRect(0,0,CSSWidth,CSSHeight) configuration:config];
    self.web.navigationDelegate=self; self.web.wantsLayer=YES;
    self.web.underPageBackgroundColor=NSColor.clearColor;
    [self configureDiagnosticSPI];
    self.window=[[PassivePanel alloc] initWithContentRect:self.web.bounds
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title=@"Sevoflurane — synthetic frame producer diagnostic";
    self.window.level=NSNormalWindowLevel; self.window.floatingPanel=NO;
    self.window.hidesOnDeactivate=NO; self.window.releasedWhenClosed=NO;
    self.window.delegate=self; self.window.contentView=self.web;
    self.window.backgroundColor=NSColor.clearColor;self.window.opaque=NO;
    [self.window center];[self.window orderFront:nil]; // Never activate or make key.
    NSURL *html=[NSBundle.mainBundle URLForResource:@"fixture" withExtension:@"html"];
    NSError *readError=nil;
    NSString *source=html ? [NSString stringWithContentsOfURL:html encoding:NSUTF8StringEncoding error:&readError] : nil;
    if (!source) { [self.errors addObject:@"missing-synthetic-html"];[self finish];return; }
    [self.web loadHTMLString:source baseURL:nil];
    [self beginPhase:@"visible"];
    self.timer=[NSTimer timerWithTimeInterval:1.0/60 repeats:YES block:^(NSTimer *t) { (void)t;[self tick]; }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if (self.finishing) return;
        [self beginPhase:@"self_occluded"];
        self.cover=[[PassivePanel alloc] initWithContentRect:self.window.frame
            styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel
            backing:NSBackingStoreBuffered defer:NO];
        self.cover.level=NSNormalWindowLevel;self.cover.floatingPanel=NO;
        self.cover.hidesOnDeactivate=NO;self.cover.opaque=YES;
        self.cover.backgroundColor=[NSColor colorWithWhite:.15 alpha:1];
        [self.cover orderWindow:NSWindowAbove relativeTo:self.window.windowNumber];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,9*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if (self.finishing) return;
        [self beginPhase:@"app_hidden"];[NSApp hide:nil]; // Only this diagnostic app.
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(14.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self finish];});
}
- (void)beginPhase:(NSString *)name {
    CFTimeInterval now=CACurrentMediaTime();Phase *previous=self.phases.lastObject;if (previous) previous->end=now;
    Phase *phase=[Phase new];phase.name=name;phase->start=now;[self.phases addObject:phase];
}
- (void)configureDiagnosticSPI {
    BOOL backgroundSetter=[self.web respondsToSelector:@selector(_setDrawsBackground:)];
    BOOL backgroundGetter=[self.web respondsToSelector:@selector(_drawsBackground)];
    BOOL occlusionSetter=[self.web respondsToSelector:@selector(_setWindowOcclusionDetectionEnabled:)];
    BOOL occlusionGetter=[self.web respondsToSelector:@selector(_windowOcclusionDetectionEnabled)];
    id backgroundBefore=NSNull.null,backgroundAfter=NSNull.null,occlusionBefore=NSNull.null,occlusionAfter=NSNull.null;
    BOOL backgroundApplied=NO,occlusionApplied=NO;
    @try {
        if (backgroundGetter) backgroundBefore=@([self.web _drawsBackground]);
        if (backgroundSetter) { [self.web _setDrawsBackground:NO];backgroundApplied=YES; }
        if (backgroundGetter) backgroundAfter=@([self.web _drawsBackground]);
    } @catch (NSException *exception) { (void)exception;[self.errors addObject:@"draws-background-spi-exception"]; }
    @try {
        if (occlusionGetter) occlusionBefore=@([self.web _windowOcclusionDetectionEnabled]);
        if (occlusionSetter) { [self.web _setWindowOcclusionDetectionEnabled:NO];occlusionApplied=YES; }
        if (occlusionGetter) occlusionAfter=@([self.web _windowOcclusionDetectionEnabled]);
    } @catch (NSException *exception) { (void)exception;[self.errors addObject:@"occlusion-detection-spi-exception"]; }
    if (!backgroundSetter || !occlusionSetter) [self.errors addObject:@"diagnostic-spi-setter-unavailable"];
    if (([backgroundAfter isKindOfClass:NSNumber.class] && [backgroundAfter boolValue]) ||
        ([occlusionAfter isKindOfClass:NSNumber.class] && [occlusionAfter boolValue]))
        [self.errors addObject:@"diagnostic-spi-value-not-disabled"];
    self.diagnosticSPI=@{@"draws_background":@{@"setter_available":@(backgroundSetter),@"getter_available":@(backgroundGetter),
            @"requested":@NO,@"applied":@(backgroundApplied),@"before":backgroundBefore,@"after":backgroundAfter},
        @"window_occlusion_detection":@{@"setter_available":@(occlusionSetter),@"getter_available":@(occlusionGetter),
            @"requested":@NO,@"applied":@(occlusionApplied),@"before":occlusionBefore,@"after":occlusionAfter}};
}
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    (void)controller;
    if (self.finishing || !message.frameInfo.mainFrame || ![message.body isKindOfClass:NSDictionary.class]) return;
    NSDictionary *d=message.body;
    if ([d[@"kind"] isEqual:@"error"]) { [self.errors addObject:@"synthetic-video-setup-failed"];return; }
    if (![d[@"kind"] isEqual:@"ready"] || self.ready) return;
    self.readyStatus=@{@"canvas":@([d[@"canvas"] boolValue]),@"webgl":@([d[@"webgl"] boolValue]),@"video":@([d[@"video"] boolValue])};
    if (![d[@"canvas"] boolValue] || ![d[@"webgl"] boolValue] || ![d[@"video"] boolValue]) {
        [self.errors addObject:@"synthetic-required-content-unavailable"];return;
    }
    if (![self prepareRenderer]) { [self finish];return; }
    self.ready=YES;self.readyTime=CACurrentMediaTime();
}
- (BOOL)prepareRenderer {
    self.device=MTLCreateSystemDefaultDevice(); self.queue=[self.device newCommandQueue];
    if (!self.device || !self.queue) { [self.errors addObject:@"metal-unavailable"];return NO; }
    CGFloat scale=self.window.backingScaleFactor;
    size_t width=(size_t)llround(CSSWidth*scale),height=(size_t)llround(CSSHeight*scale);
    size_t stride=(width*4+63)&~(size_t)63;
    self.geometry=(FCGeometry){width,height,stride,CSSWidth,CSSHeight};
    if (!fc_geometry_valid(self.geometry)) { [self.errors addObject:@"invalid-surface-geometry"];return NO; }
    NSMutableArray *slots=[NSMutableArray new];
    for (int i=0;i<3;i++) {
        SurfaceSlot *slot=[SurfaceSlot new];
        slot.surface=IOSurfaceCreate((__bridge CFDictionaryRef)@{
            (__bridge NSString *)kIOSurfaceWidth:@(width),(__bridge NSString *)kIOSurfaceHeight:@(height),
            (__bridge NSString *)kIOSurfaceBytesPerRow:@(stride),(__bridge NSString *)kIOSurfaceBytesPerElement:@4,
            (__bridge NSString *)kIOSurfacePixelFormat:@(0x42475241)});
        if (!slot.surface) { [self.errors addObject:@"iosurface-create-failed"];return NO; }
        MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
        desc.storageMode=MTLStorageModeShared;desc.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
        desc.hazardTrackingMode=MTLHazardTrackingModeTracked;
        slot.texture=[self.device newTextureWithDescriptor:desc iosurface:slot.surface plane:0];
        slot.completionByte=[self.device newBufferWithLength:256 options:MTLResourceStorageModeShared];
        slot.copySize=width*height*4;slot.copy=malloc(slot.copySize);
        if (!slot.texture || !slot.completionByte || !slot.copy) { [self.errors addObject:@"surface-texture-or-copy-allocation-failed"];return NO; }
        [slots addObject:slot];
    }
    self.slots=slots;
    CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    self.renderer=[CARenderer rendererWithMTLTexture:self.slots.firstObject.texture
        options:@{kCARendererMetalCommandQueue:self.queue,kCARendererColorSpace:(__bridge id)color}];
    CGColorSpaceRelease(color);
    if (!self.renderer) { [self.errors addObject:@"carenderer-create-failed"];return NO; }
    // CARenderer renders in target coordinates, not AppKit backing-point units.
    // Only our standalone carrier is transformed; WK's bounds, anchor, position,
    // contentsScale and geometryFlipped remain managed by WK/AppKit.
    CALayer *source=self.web.layer;
    if (!source) { [self.errors addObject:@"fixture-source-layer-unavailable"];return NO; }
    if (!CGRectEqualToRect(self.web.bounds,CGRectMake(0,0,CSSWidth,CSSHeight))) {
        [self.errors addObject:@"fixture-logical-bounds-changed"];return NO;
    }
    CGFloat sx=(CGFloat)width/self.web.bounds.size.width,sy=(CGFloat)height/self.web.bounds.size.height;
    [CATransaction begin];[CATransaction setDisableActions:YES];
    self.pixelRoot=[CALayer layer];self.pixelRoot.bounds=CGRectMake(0,0,width,height);
    self.pixelRoot.anchorPoint=CGPointZero;self.pixelRoot.position=CGPointZero;
    self.pixelRoot.opaque=NO;self.pixelRoot.backgroundColor=NULL;
    self.logicalCarrier=[CALayer layer];self.logicalCarrier.bounds=self.web.bounds;
    self.logicalCarrier.anchorPoint=CGPointZero;
    self.logicalCarrier.position=CGPointMake(-source.frame.origin.x*sx,-source.frame.origin.y*sy);
    self.logicalCarrier.opaque=NO;self.logicalCarrier.backgroundColor=NULL;
    self.logicalCarrier.transform=CATransform3DMakeScale(sx,sy,1);
    // This WK instance belongs exclusively to this synthetic fixture. No user
    // window/layer is discovered or detached. AppKit may reject/reparent this
    // layer; diagnostics explicitly record that instead of continually moving it.
    [self.logicalCarrier addSublayer:source];[self.pixelRoot addSublayer:self.logicalCarrier];
    self.renderer.layer=self.pixelRoot;self.renderer.bounds=self.pixelRoot.bounds;
    [CATransaction commit];[CATransaction flush];
    return YES;
}
- (void)tick {
    if (self.finishing) return;
    CFTimeInterval now=CACurrentMediaTime();
    if (!self.ready) {
        if (now-self.launched>3) { [self.errors addObject:@"synthetic-page-not-ready-within-three-seconds"];[self finish]; }
        return;
    }
    if (now-self.readyTime<.35) return; // Explicit startup warm-up, not an accepted frame.
    if (self.inFlight) { self.skippedBusy++;return; }
    self.inFlight=YES;
    Phase *phase=self.phases.lastObject;SurfaceSlot *slot=self.slots[self.nextSlot++%self.slots.count];
    if (!phase.inventory) {
        phase.inventory=@{@"layers":layerInventory(self.pixelRoot),@"views":viewInventory(self.web)};
        now=CACurrentMediaTime(); // One metadata inventory per phase is outside frame timing.
    }
    BOOL sourceNested=self.web.layer.superlayer==self.logicalCarrier;
    BOOL diagnose=phase.examples.count<3;
    if (self.window.occlusionState&NSWindowOcclusionStateVisible) phase->visibleSamples++;
    else phase->occludedSamples++;
    if (NSApp.hidden) phase->hiddenSamples++;
    if (NSApp.active) phase->activeSamples++;
    FCGeometry geometry=self.geometry; geometry.row_bytes=IOSurfaceGetBytesPerRow(slot.surface);
    CFTimeInterval began=now;
    @try {
        [self.renderer setDestination:slot.texture];
        id<MTLCommandBuffer> clear=[self.queue commandBuffer];
        MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture=slot.texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;
        pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);
        id<MTLRenderCommandEncoder> clearEncoder=[clear renderCommandEncoderWithDescriptor:pass];
        if (!clear || !clearEncoder) {
            self.inFlight=NO;[self.errors addObject:@"clear-command-unavailable"];[self finish];return;
        }
        [clearEncoder endEncoding];[clear commit];
        [self.renderer beginFrameAtTime:now timeStamp:NULL];
        [self.renderer addUpdateRect:self.pixelRoot.bounds];
        [self.renderer render];[self.renderer endFrame];
    } @catch (NSException *exception) {
        (void)exception;self.inFlight=NO;[self.errors addObject:@"carenderer-exception"];[self finish];return;
    }
    CFTimeInterval submitted=CACurrentMediaTime();
    id<MTLCommandBuffer> completed=[self.queue commandBuffer];
    if (!completed) { self.inFlight=NO;[self.errors addObject:@"completion-marker-unavailable"];[self finish];return; }
    // Explicitly read the tracked destination texture on the same queue, rather
    // than relying on completion of an empty command buffer as a GPU fence.
    id<MTLBlitCommandEncoder> dependency=[completed blitCommandEncoder];
    if (!dependency) { self.inFlight=NO;[self.errors addObject:@"completion-dependency-unavailable"];[self finish];return; }
    [dependency copyFromTexture:slot.texture sourceSlice:0 sourceLevel:0
        sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(1,1,1)
        toBuffer:slot.completionByte destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256];
    [dependency endEncoding];
    // Retain slot until its completion AND the entire CPU read/copy have finished.
    [completed addCompletedHandler:^(id<MTLCommandBuffer> command) {
        CFTimeInterval gpuDone=CACurrentMediaTime(),locked=gpuDone,copied=gpuDone;
        BOOL gpuOK=command.status==MTLCommandBufferStatusCompleted;
        BOOL lockOK=NO,copyOK=NO;int orientation=-1;FCResult result={0};FCDiagnostics diagnostic={0};uint32_t seed=0;
        if (gpuOK) {
            kern_return_t status=IOSurfaceLock(slot.surface,kIOSurfaceLockReadOnly,&seed);
            locked=CACurrentMediaTime();copied=locked;lockOK=status==KERN_SUCCESS;
            if (lockOK) {
                const uint8_t *base=IOSurfaceGetBaseAddress(slot.surface);
                orientation=fc_orientation(base,geometry);
                copyOK=fc_copy_rows(slot.copy,slot.copySize,base,geometry,orientation==1);
                copied=CACurrentMediaTime();
                kern_return_t unlock=IOSurfaceUnlock(slot.surface,kIOSurfaceLockReadOnly,NULL);
                if (unlock!=KERN_SUCCESS) lockOK=NO;
                if (copyOK) {
                    FCGeometry packed=geometry;packed.row_bytes=geometry.width*4;result=fc_check(slot.copy,packed);
                    if (diagnose) diagnostic=fc_diagnostics(slot.copy,packed);
                }
            }
        }
        CFTimeInterval done=CACurrentMediaTime();
        NSArray *timing=@[@(milliseconds(began,submitted)),@(milliseconds(submitted,gpuDone)),
            @(milliseconds(gpuDone,locked)),@(milliseconds(locked,copied)),@(milliseconds(began,done))];
        dispatch_async(dispatch_get_main_queue(),^{
            phase->frames++;[phase.timings addObject:timing];
            if (!gpuOK) phase->gpuErrors++;
            if (!sourceNested) phase->sourceReparentedFrames++;
            if (gpuOK && !lockOK) phase->lockFailures++;
            if (!copyOK || !fc_content_pass(result)) phase->contentFailures++;
            if (orientation<0) phase->orientationFailures++;
            else if (phase->firstOrientation<0) phase->firstOrientation=orientation;
            else if (phase->firstOrientation!=orientation) phase->orientationChanges++;
            if (!result.generation_valid) phase->generationFailures++;
            if (!result.generation_equal) phase->tearing++;
            if (result.generation_valid && result.generation_equal) {
                uint16_t step=(uint16_t)(result.generation-phase->lastGeneration);
                if (phase->lastGeneration && !step) phase->duplicateFrames++;
                else if (phase->lastGeneration) { phase->transitions++;if (step>32768) phase->backwards++; }
                phase->lastGeneration=result.generation;
            }
            for (int i=0;i<FC_REGION_COUNT;i++) {
                if (phase->frames>1 && phase->previousRegions[i]!=result.regions[i]) phase->regionChanges[i]++;
                phase->previousRegions[i]=result.regions[i];
            }
            if (phase.examples.count<3) [phase.examples addObject:@{
                @"generation":@(result.generation),@"corners_bgra":@[bgra(result.corner_bgra[0]),bgra(result.corner_bgra[1]),bgra(result.corner_bgra[2]),bgra(result.corner_bgra[3])],
                @"generation_valid":@(result.generation_valid),@"generation_equal":@(result.generation_equal),
                @"source_layer_under_carrier":@(sourceNested),@"coordinates_normalized":@(orientation>=0),
                @"alpha_nonzero_count":@(diagnostic.nonzero_alpha),@"alpha_min":@(diagnostic.min_alpha),@"alpha_max":@(diagnostic.max_alpha),
                @"alpha_bbox_px":diagnostic.nonzero_alpha ? @[@(diagnostic.min_x),@(diagnostic.min_y),@(diagnostic.max_x),@(diagnostic.max_y)] : (id)NSNull.null,
                @"logical_coordinate_corners_bgra":@[bgra(diagnostic.logical_coordinate_corners[0]),bgra(diagnostic.logical_coordinate_corners[1]),bgra(diagnostic.logical_coordinate_corners[2]),bgra(diagnostic.logical_coordinate_corners[3])],
                @"content_pass":@(fc_content_pass(result)),@"transparent_edges":@(result.transparent_edges),
                @"canvas":@(result.canvas),@"webgl":@(result.webgl),@"video":@(result.video),@"surface_seed":@(seed)}];
            self.inFlight=NO;if (self.finishing) [self writeReportAndExit];
        });
    }];
    [completed commit];
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))handler {
    (void)webView;
    // No Steam/user pages or network navigation, even if diagnostic HTML changes.
    handler([action.request.URL.absoluteString isEqual:@"about:blank"] ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}
- (void)finish {
    if (self.finishing) return;
    self.finishing=YES;[self.timer invalidate];Phase *last=self.phases.lastObject;if (last) last->end=CACurrentMediaTime();
    if (!self.inFlight) { [self writeReportAndExit];return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if (self.written) return;
        [self.errors addObject:@"gpu-completion-timeout-no-cpu-read-or-manual-surface-release"];
        [self writeReportAndExit]; // Process teardown only; slot remains retained until exit.
    });
}
- (void)writeReportAndExit {
    if (self.written) return;self.written=YES;
    NSMutableArray *reports=[NSMutableArray new];BOOL pass=self.errors.count==0 && self.phases.count==3;
    for (Phase *phase in self.phases) { NSDictionary *r=phase.report;[reports addObject:r];if (![r[@"passed"] boolValue]) pass=NO; }
    FCGeometry g=self.geometry;
    NSDictionary *report=@{@"schema":@1,@"source":@"synthetic-wk-only",@"backend":@"public-CARenderer-Metal-IOSurface",
        @"passed":@(pass),@"steam_connected":@NO,@"runtime_s":@(CACurrentMediaTime()-self.launched),
        @"errors":self.errors,@"ready":self.readyStatus ?: (id)NSNull.null,@"phases":reports,
        @"diagnostic_spi":self.diagnosticSPI ?: (id)NSNull.null,
        @"geometry":@{@"width":@(g.width),@"height":@(g.height),@"requested_row_bytes":@(g.row_bytes),
            @"iosurface_width":self.slots.count ? @(IOSurfaceGetWidth(self.slots.firstObject.surface)) : (id)NSNull.null,
            @"iosurface_height":self.slots.count ? @(IOSurfaceGetHeight(self.slots.firstObject.surface)) : (id)NSNull.null,
            @"actual_row_bytes":self.slots.count ? @(IOSurfaceGetBytesPerRow(self.slots.firstObject.surface)) : (id)NSNull.null,
            @"css_width":@(CSSWidth),@"css_height":@(CSSHeight),@"backing_scale":@(self.window.backingScaleFactor)},
        @"render_mapping":self.pixelRoot ? @{@"renderer_bounds_width":@(self.renderer.bounds.size.width),@"renderer_bounds_height":@(self.renderer.bounds.size.height),
            @"carrier_scale_x":@(self.logicalCarrier.transform.m11),@"carrier_scale_y":@(self.logicalCarrier.transform.m22),
            @"source_bounds_width":@(self.web.layer.bounds.size.width),@"source_bounds_height":@(self.web.layer.bounds.size.height),
            @"source_contents_scale":@(self.web.layer.contentsScale),@"source_geometry_flipped":@(self.web.layer.geometryFlipped),
            @"source_layer_under_carrier":@(self.web.layer.superlayer==self.logicalCarrier),
            @"pixel_root_opaque":@(self.pixelRoot.opaque),@"carrier_opaque":@(self.logicalCarrier.opaque)} : (id)NSNull.null,
        @"build_commit":[NSBundle.mainBundle objectForInfoDictionaryKey:@"SevoBuildCommit"] ?: @"unknown",
        @"macos":NSProcessInfo.processInfo.operatingSystemVersionString,
        @"busy_ticks_skipped":@(self.skippedBusy),@"gpu_pending_at_exit":@(self.inFlight),
        @"acceptance":@"Each phase needs >=8 distinct generations, all content/alpha checks, every motion region changed >=2 times, zero tearing/backwards/lock/GPU/orientation errors. Timing is measured, not a frame-rate guarantee."};
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL];
    NSString *path=[self.outputDirectory stringByAppendingPathComponent:@"report.json"];
    BOOL wrote=[json writeToFile:path atomically:YES];
    NSData *location=[NSJSONSerialization dataWithJSONObject:@{@"report_path":path,@"passed":@(pass),@"written":@(wrote)} options:0 error:NULL];
    fwrite(location.bytes,1,location.length,stdout);fputc('\n',stdout);fflush(stdout);
    // All normal frames completed and CPU reads ended. On GPU timeout, no surface is manually released.
    _Exit(pass && wrote ? 0 : 2);
}
@end

int main(int argc,const char **argv) {
    (void)argc;(void)argv;
    static Fixture *owner; // NSApplication.delegate does not own its delegate.
    @autoreleasepool { NSApplication *app=NSApplication.sharedApplication;owner=[Fixture new];app.delegate=owner;[app run]; }
    return 2;
}
