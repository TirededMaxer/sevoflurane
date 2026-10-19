#import <WebKit/WebKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface SevoNativeWebRenderer : NSObject
- (nullable instancetype)initWithWebView:(WKWebView *)view width:(uint32_t)width height:(uint32_t)height
                               framePath:(NSString *)path cefID:(uint32_t)cefID;
- (void)stop;
@property(nonatomic,readonly) uint64_t frames;
@property(nonatomic,readonly) uint64_t consumedFrames;
@end
NS_ASSUME_NONNULL_END
