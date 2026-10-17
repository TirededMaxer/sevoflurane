#include <math.h>
#import "WindowSurface.h"
NSPoint SevoOverlayNormalizedPoint(NSView *view, NSPoint pointInWindow) {
    NSPoint local = [view convertPoint:pointInWindow fromView:nil];
    NSRect bounds = view.bounds;
    CGFloat x = (local.x - NSMinX(bounds)) / MAX(1, NSWidth(bounds));
    CGFloat y = (local.y - NSMinY(bounds)) / MAX(1, NSHeight(bounds));
    return NSMakePoint(x, view.isFlipped ? y : 1 - y);
}

@implementation SevoWindowSurface {
    CALayer *_layer;
}
- (instancetype)init {
    if ((self = [super init])) {
        _layer = [CALayer layer];
        _layer.name = @"Sevoflurane window-surface experiment";
        _layer.zPosition = 1000000;
        _layer.contentsGravity = kCAGravityResize;
        _layer.minificationFilter = kCAFilterNearest;
        _layer.magnificationFilter = kCAFilterNearest;
        _layer.actions = @{@"contents": NSNull.null, @"bounds": NSNull.null,
                           @"position": NSNull.null, @"hidden": NSNull.null};
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
- (void)detach {
    [_layer removeFromSuperlayer];
    _layer.contents = nil;
}
@end
