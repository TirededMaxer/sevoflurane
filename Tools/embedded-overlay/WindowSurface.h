#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>

/// Top-left normalized coordinates, independent of the host view's Y axis.
NSPoint SevoOverlayNormalizedPoint(NSView *view, NSPoint pointInWindow);
// gameoverlay.styles includes steam.styles, whose Frame.TransitionEffectTime
// is 0.25 seconds. Only opacity changes; Steam still owns the page and layout.
FOUNDATION_EXPORT const CFTimeInterval SevoOverlayTransitionDuration;

typedef NS_ENUM(NSInteger, SevoSurfaceResult) {
    SevoSurfaceRejected,
    SevoSurfaceBusy,
    SevoSurfacePresented,
};

/// Experimental presentation inside an existing game window, independently
/// of its lower-resolution Metal backbuffer. It creates no NSWindow and
/// changes no responder or application activation state.
@interface SevoWindowSurface : NSObject
@property(nonatomic, readonly) CALayer *layer;
// Packed premultiplied BGRA. Reuse GPU-shareable buffers instead of asking
// Core Animation to color-convert a fresh CGImage on Wine's main thread.
- (SevoSurfaceResult)presentPixels:(const void *)pixels width:(size_t)width height:(size_t)height
                       inWindow:(NSWindow *)window scale:(CGFloat)scale;
// Retain the last native-resolution frame until fade-out completes.
- (BOOL)updateVisibility:(BOOL)visible atTime:(CFTimeInterval)time;
- (void)detach;
@end
