#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#include "paint_frame.h"
/* One-shot diagnostic fixture. This is not a continuous screenshot producer. */
@interface FrameDelegate : NSObject <WKNavigationDelegate>
@property WKWebView *view;
@property NSWindow *window;
@property NSString *output;
@property NSUInteger width, height;
@property BOOL finished;
@property int result;
@end
@implementation FrameDelegate
- (void)webView:(WKWebView *)view didFinishNavigation:(WKNavigation *)navigation {
    [view callAsyncJavaScript:@"await document.fonts.ready; await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))); return true;" arguments:@{} inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:^(id value, NSError *error) {
        WKSnapshotConfiguration *config = [WKSnapshotConfiguration new];
        config.rect = view.bounds;
        config.snapshotWidth = @(self.width);
        [view takeSnapshotWithConfiguration:config completionHandler:^(NSImage *image, NSError *snapshotError) {
            if (!image || snapshotError) { self.result = 2; self.finished = YES; return; }
            CGImageRef cg = [image CGImageForProposedRect:NULL context:nil hints:nil];
            size_t count = self.width * self.height * 4;
            NSMutableData *frame = [NSMutableData dataWithLength:sizeof(sevo_frame_header) + count];
            sevo_frame_header *h = frame.mutableBytes;
            memcpy(h->magic, SEVO_FRAME_MAGIC, 8); h->header_bytes = sizeof(*h);
            h->width = (uint32_t)self.width; h->height = (uint32_t)self.height;
            h->stride = (uint32_t)self.width * 4; h->payload_bytes = count;
            CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGContextRef context = CGBitmapContextCreate((uint8_t *)frame.mutableBytes + sizeof(*h), self.width, self.height, 8, h->stride, space, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
            if (!cg || !context) { if (context) CGContextRelease(context); CGColorSpaceRelease(space); self.result = 3; self.finished = YES; return; }
            CGContextDrawImage(context, CGRectMake(0, 0, self.width, self.height), cg);
            CGContextRelease(context); CGColorSpaceRelease(space);
            NSError *writeError = nil;
            self.result = [frame writeToFile:self.output options:NSDataWritingAtomic error:&writeError] ? 0 : 4;
            self.finished = YES;
        }];
    }];
}
- (void)webView:(WKWebView *)view didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error { self.result = 5; self.finished = YES; }
- (void)webView:(WKWebView *)view didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error { self.result = 6; self.finished = YES; }
@end
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 4) { fprintf(stderr, "usage: sevo-painter-frame OUTPUT WIDTH HEIGHT\n"); return 64; }
        long width = strtol(argv[2], NULL, 10), height = strtol(argv[3], NULL, 10);
        if (width < 64 || height < 64 || (uint64_t)width * height * 4 > SEVO_FRAME_LIMIT) return 64;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        FrameDelegate *delegate = [FrameDelegate new]; delegate.width = width; delegate.height = height;
        delegate.output = [NSString stringWithUTF8String:argv[1]]; delegate.result = 7;
        NSRect bounds = NSMakeRect(0, 0, width, height);
        delegate.window = [[NSWindow alloc] initWithContentRect:bounds styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        delegate.window.ignoresMouseEvents = YES; delegate.window.alphaValue = 0;
        delegate.window.collectionBehavior = NSWindowCollectionBehaviorStationary;
        delegate.view = [[WKWebView alloc] initWithFrame:bounds]; delegate.view.navigationDelegate = delegate;
        delegate.window.contentView = delegate.view;
        if ([delegate.view respondsToSelector:NSSelectorFromString(@"_setWindowOcclusionDetectionEnabled:")]) [delegate.view setValue:@NO forKey:@"windowOcclusionDetectionEnabled"];
        [delegate.window orderBack:nil];
        [delegate.view loadHTMLString:@"<!doctype html><html><meta charset='utf-8'><style>html,body{margin:0;background:#123456;color:white;font:32px sans-serif}main{padding:48px}small{font-size:18px}</style><main>Sevoflurane painter probe<br><small>WebKit frame → original Steam painter</small></main></html>" baseURL:nil];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
        while (!delegate.finished && deadline.timeIntervalSinceNow > 0) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        [delegate.window orderOut:nil];
        return delegate.result;
    }
}
