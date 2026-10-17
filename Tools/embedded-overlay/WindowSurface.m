#include <math.h>
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
    BOOL _wantsVisible;
    float _fromOpacity;
    CFTimeInterval _transitionStart;
}
- (instancetype)init {
    if ((self = [super init])) {
        _layer = [CALayer layer];
        _layer.name = @"Sevoflurane window-surface experiment";
        _layer.zPosition = 1000000;
        _layer.contentsGravity = kCAGravityResize;
        _layer.opacity = 0;
        _layer.minificationFilter = kCAFilterNearest;
        _layer.magnificationFilter = kCAFilterNearest;
        _layer.actions = @{@"contents": NSNull.null, @"bounds": NSNull.null,
                           @"position": NSNull.null, @"hidden": NSNull.null, @"opacity": NSNull.null};
    }
    return self;
}
- (CALayer *)layer { return _layer; }
- (BOOL)presentImage:(CGImageRef)image inWindow:(NSWindow *)window scale:(CGFloat)scale {
    NSView *content = window.contentView;
    if (!image || !content || scale <= 0 || NSIsEmptyRect(content.bounds)) return NO;
    // Refuse a 1x producer on a 2x window. Enlarging an already downsampled
    // image cannot recover sharp UI and must not count as an accepted frame.
    if (CGImageGetWidth(image) != (size_t)llround(NSWidth(content.bounds) * scale)
        || CGImageGetHeight(image) != (size_t)llround(NSHeight(content.bounds) * scale)) return NO;
    content.wantsLayer = YES;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (_layer.superlayer != content.layer) {
        [_layer removeFromSuperlayer];
        [content.layer addSublayer:_layer];
    }
    _layer.frame = content.bounds;
    _layer.contentsScale = scale;
    _layer.contents = (__bridge id)image;
    [CATransaction commit];
    return YES;
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
    _layer.opacity = _fromOpacity + (target - _fromOpacity) * progress;
    if (!visible && _layer.opacity <= 0) [self detach];
    return _layer.superlayer != nil;
}
- (void)detach {
    [_layer removeFromSuperlayer];
    _layer.contents = nil;
    _layer.opacity = 0;
    _wantsVisible = NO;
    _fromOpacity = 0;
}
@end
