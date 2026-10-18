#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>

NS_ASSUME_NONNULL_BEGIN

/// Optional fixture backend. Availability is only a symbol/selector gate,
/// not proof that the macOS implementation renders WK remote/media layers.
@interface RenderServerFrameSource : NSObject
- (instancetype)initWithSourceView:(NSView *)sourceView NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@property(nonatomic,readonly) BOOL available;
@property(nonatomic,copy,readonly) NSDictionary<NSString *,id> *metadata;
@property(nonatomic,copy,readonly,nullable) NSString *lastError;

/// Main-thread, serial use only. source must remain sourceView.layer attached
/// to sourceView.window. No layer is reparented and no source geometry changes.
/// destination must be a caller-created, nonplanar BGRA8 IOSurface, kept alive
/// and exclusively owned by the current slot through this call AND CPU copying.
/// The backend write-locks/clears/unlocks before Snapshot; it never reads pixels.
/// On YES only, the caller may take its matched read-only lock, copy and unlock.
/// YES means the snapshot function returned true, not a proven CPU fence.
/// WebKit's iOS example immediately creates a CG image reference to the surface;
/// its source does not establish direct CPU-read completion on macOS.
- (BOOL)renderLayer:(CALayer *)source toSurface:(IOSurfaceRef)destination
            scaleX:(CGFloat)scaleX scaleY:(CGFloat)scaleY;
@end

NS_ASSUME_NONNULL_END
