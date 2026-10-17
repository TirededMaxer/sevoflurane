#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

/// Top-left normalized coordinates, independent of the host view's Y axis.
NSPoint SevoOverlayNormalizedPoint(NSView *view, NSPoint pointInWindow);

/// Experimental presentation inside an existing game window, independently
/// of its lower-resolution Metal backbuffer. It creates no NSWindow and
/// changes no responder or application activation state.
@interface SevoWindowSurface : NSObject
@property(nonatomic, readonly) CALayer *layer;
- (BOOL)presentImage:(CGImageRef)image inWindow:(NSWindow *)window scale:(CGFloat)scale;
- (void)detach;
@end
