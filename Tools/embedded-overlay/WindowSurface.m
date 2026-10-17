#include <math.h>
#include <string.h>
#import "WindowSurface.h"
const CFTimeInterval SevoOverlayTransitionDuration = 0.25;
NSPoint SevoOverlayNormalizedPoint(NSView *view, NSPoint pointInWindow) {
    NSPoint local = [view convertPoint:pointInWindow fromView:nil];
    NSRect bounds = view.bounds;
    CGFloat x = (local.x - NSMinX(bounds)) / MAX(1, NSWidth(bounds));
    CGFloat y = (local.y - NSMinY(bounds)) / MAX(1, NSHeight(bounds));
    return NSMakePoint(x, view.isFlipped ? y : 1 - y);
}

@implementation SevoWindowSurface {
    CALayer *_layer;
    IOSurfaceRef _surfaces[3];
    size_t _width, _height;
    BOOL _wantsVisible;
    float _fromOpacity;
    CFTimeInterval _transitionStart;
}
- (instancetype)init {
    if ((self = [super init])) {
        // Do not open an implicit transaction in Wine's custom event loop.
        // It would also become the parent of the image transaction below.
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _layer = [CALayer layer];
        _layer.name = @"Sevoflurane window-surface experiment";
        _layer.zPosition = 1000000;
        _layer.contentsGravity = kCAGravityResize;
        _layer.opacity = 0;
        _layer.minificationFilter = kCAFilterNearest;
        _layer.magnificationFilter = kCAFilterNearest;
        _layer.actions = @{@"contents": NSNull.null, @"bounds": NSNull.null,
                           @"position": NSNull.null, @"hidden": NSNull.null, @"opacity": NSNull.null};
        [CATransaction commit];
    }
    return self;
}
- (CALayer *)layer { return _layer; }
- (void)releaseSurfaces {
    for (NSUInteger i = 0; i < 3; ++i) {
        if (_surfaces[i]) CFRelease(_surfaces[i]);
        _surfaces[i] = NULL;
    }
    _width = _height = 0;
}
- (void)dealloc { [self releaseSurfaces]; }
- (BOOL)prepareSurfacesWithWidth:(size_t)width height:(size_t)height {
    if (_width == width && _height == height) return YES;
    [self releaseSurfaces];
    NSDictionary *properties = @{
        (__bridge NSString *)kIOSurfaceWidth: @(width),
        (__bridge NSString *)kIOSurfaceHeight: @(height),
        (__bridge NSString *)kIOSurfaceBytesPerElement: @4,
        (__bridge NSString *)kIOSurfaceBytesPerRow: @(IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4)),
        (__bridge NSString *)kIOSurfacePixelFormat: @(0x42475241u), // BGRA
    };
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CFPropertyListRef colorInfo = CGColorSpaceCopyPropertyList(color);
    for (NSUInteger i = 0; i < 3; ++i) {
        _surfaces[i] = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
        if (_surfaces[i] && colorInfo) IOSurfaceSetValue(_surfaces[i], kIOSurfaceColorSpace, colorInfo);
    }
    if (colorInfo) CFRelease(colorInfo);
    CGColorSpaceRelease(color);
    if (!_surfaces[0] || !_surfaces[1] || !_surfaces[2]) { [self releaseSurfaces]; return NO; }
    _width = width; _height = height;
    return YES;
}
- (SevoSurfaceResult)presentPixels:(const void *)pixels width:(size_t)width height:(size_t)height
                         inWindow:(NSWindow *)window scale:(CGFloat)scale {
    NSView *content = window.contentView;
    if (!pixels || !content || scale <= 0 || NSIsEmptyRect(content.bounds)
        || !width || !height || width > 4096 || height > 4096) return SevoSurfaceRejected;
    if (width != (size_t)llround(NSWidth(content.bounds) * scale)
        || height != (size_t)llround(NSHeight(content.bounds) * scale)) return SevoSurfaceRejected;
    if (![self prepareSurfacesWithWidth:width height:height]) return SevoSurfaceRejected;
    IOSurfaceRef surface = NULL;
    for (NSUInteger i = 0; i < 3; ++i) {
        if ((__bridge id)_surfaces[i] == _layer.contents || IOSurfaceIsInUse(_surfaces[i])) continue;
        if (IOSurfaceLock(_surfaces[i], kIOSurfaceLockAvoidSync, NULL) == KERN_SUCCESS) {
            surface = _surfaces[i]; break;
        }
    }
    // Never wait for the render server on the game's event thread. Keep the
    // previous frame if every surface is still in use and retry next tick.
    if (!surface) return SevoSurfaceBusy;
    size_t stride = IOSurfaceGetBytesPerRow(surface);
    uint8_t *destination = IOSurfaceGetBaseAddress(surface);
    if (stride == width * 4) memcpy(destination, pixels, stride * height);
    else for (size_t y = 0; y < height; ++y)
        memcpy(destination + y * stride, (const uint8_t *)pixels + y * width * 4, width * 4);
    IOSurfaceUnlock(surface, 0, NULL);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    content.wantsLayer = YES;
    if (_layer.superlayer != content.layer) {
        [_layer removeFromSuperlayer];
        [content.layer addSublayer:_layer];
    }
    _layer.frame = content.bounds;
    _layer.contentsScale = scale;
    _layer.contents = (__bridge id)surface;
    [CATransaction commit];
    return SevoSurfacePresented;
}
- (BOOL)updateVisibility:(BOOL)visible atTime:(CFTimeInterval)time {
    if (_wantsVisible != visible) {
        _fromOpacity = _layer.opacity;
        _transitionStart = time;
        _wantsVisible = visible;
    }
    float target = visible ? 1 : 0;
    float distance = fabsf(target - _fromOpacity);
    double progress = distance > 0 ? fmin(1, fmax(0, (time - _transitionStart)
        / (SevoOverlayTransitionDuration * distance))) : 1;
    float opacity = _fromOpacity + (target - _fromOpacity) * progress;
    // Commit fade steps explicitly, just like new image contents. An
    // implicit parent transaction can hold both updates until Wine yields
    // its event loop. Once settled, leave the layer alone on timer ticks.
    if (_layer.opacity != opacity) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _layer.opacity = opacity;
        [CATransaction commit];
    }
    if (!visible && opacity <= 0) [self detach];
    return _layer.superlayer != nil;
}
- (void)detach {
    if (_layer.superlayer || _layer.contents || _layer.opacity != 0) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [_layer removeFromSuperlayer];
        _layer.contents = nil;
        _layer.opacity = 0;
        [CATransaction commit];
    }
    _wantsVisible = NO;
    _fromOpacity = 0;
}
@end
