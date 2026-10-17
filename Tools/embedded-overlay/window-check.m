#include <math.h>
#import "WindowSurface.h"
#import "InputPolicy.h"
#import <Metal/Metal.h>
#include <assert.h>
@interface FlippedGameView : NSView @end
@implementation FlippedGameView
- (BOOL)isFlipped { return YES; }
@end
static CGImageRef makeImage(size_t width, size_t height) {
    NSMutableData *bytes = [NSMutableData dataWithLength:width * height * 4];
    uint8_t *p = bytes.mutableBytes;
    // Single physical-pixel stripes reveal accidental 2x-to-1x downsampling.
    for (size_t y = 0; y < height; ++y) for (size_t x = 0; x < width; ++x) {
        size_t i = (y * width + x) * 4;
        p[i] = p[i+1] = p[i+2] = x & 1 ? 255 : 0; p[i+3] = 255;
    }
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)bytes);
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = CGImageCreate(width, height, 8, 32, width * 4, color,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst, provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(color); CGDataProviderRelease(provider);
    return image;
}
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSWindow *game = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1512,982)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        game.releasedWhenClosed = NO;
        NSUInteger count = NSApp.windows.count;
        NSResponder *responder = game.firstResponder;
        NSWindow *key = NSApp.keyWindow;
        CGImageRef image = makeImage(3024,1964), low = makeImage(1512,982);
        game.contentView.wantsLayer = YES;
        CAMetalLayer *backbuffer = [CAMetalLayer layer];
        backbuffer.frame = game.contentView.bounds;
        backbuffer.drawableSize = CGSizeMake(1512,982);
        [game.contentView.layer addSublayer:backbuffer];
        SevoWindowSurface *surface = [SevoWindowSurface new];
        assert(![surface presentImage:low inWindow:game scale:2]);
        assert([surface presentImage:image inWindow:game scale:2]);
        // Check actual opacity and retained image, including a rapid
        // reversal midway through a fade instead of restarting from 0/1.
        assert([surface updateVisibility:YES atTime:10]);
        assert(surface.layer.opacity == 0);
        [surface updateVisibility:YES atTime:10.125];
        assert(fabs(surface.layer.opacity - 0.5) < 1e-5);
        [surface updateVisibility:NO atTime:10.125];
        [surface updateVisibility:NO atTime:10.1875];
        assert(fabs(surface.layer.opacity - 0.25) < 1e-5);
        assert(surface.layer.contents && surface.layer.superlayer);
        [surface updateVisibility:YES atTime:10.1875];
        [surface updateVisibility:YES atTime:10.375];
        assert(surface.layer.opacity == 1);
        assert(surface.layer.superlayer == game.contentView.layer);
        assert(surface.layer.contentsScale == 2);
        assert(backbuffer.drawableSize.width == 1512 && backbuffer.drawableSize.height == 982);
        assert(surface.layer.zPosition > backbuffer.zPosition);
        assert(CGImageGetWidth((__bridge CGImageRef)surface.layer.contents) == 3024);
        assert(NSApp.windows.count == count && NSApp.keyWindow == key && game.firstResponder == responder);
        NSMutableData *output = [NSMutableData dataWithLength:3024 * 1964 * 4];
        CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(output.mutableBytes,3024,1964,8,3024*4,color,
            kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
        CGContextScaleCTM(ctx,2,2);
        [surface.layer renderInContext:ctx];
        const uint8_t *pixels = output.bytes;
        for (size_t x = 10; x < 30; ++x) assert(pixels[(100*3024+x)*4] == (x & 1 ? 255 : 0));
        CGContextRelease(ctx); CGColorSpaceRelease(color);
        // A flipped Wine view and an ordinary AppKit view must agree about
        // the same screen point. Include a non-zero bounds origin.
        for (int flipped = 0; flipped < 2; ++flipped) {
            NSView *view = flipped ? [FlippedGameView new] : [NSView new];
            game.contentView = view;
            view.bounds = NSMakeRect(30,40,1512,982);
            NSPoint top = [view convertPoint:NSMakePoint(30, flipped ? 40 : 1022) toView:nil];
            NSPoint bottom = [view convertPoint:NSMakePoint(1542, flipped ? 1022 : 40) toView:nil];
            NSPoint a = SevoOverlayNormalizedPoint(view,top), b = SevoOverlayNormalizedPoint(view,bottom);
            assert(fabs(a.x)<1e-6 && fabs(a.y)<1e-6 && fabs(b.x-1)<1e-6 && fabs(b.y-1)<1e-6);
        }
        [surface updateVisibility:NO atTime:11];
        [surface updateVisibility:NO atTime:11.125];
        assert(surface.layer.opacity > 0 && surface.layer.contents);
        [surface updateVisibility:NO atTime:11.25];
        assert(!surface.layer.superlayer && !surface.layer.contents);
        [surface detach]; assert(!surface.layer.superlayer && !surface.layer.contents);
        for (int type = 0; type < 37; ++type) {
            SevoCX263EventPrefix event = {.type=type};
            assert(!SevoOverlayBlocksWineEvent(&event,false));
            bool blocked = type==6 || type==7 || type==8 || (type>=13 && type<=16);
            assert(SevoOverlayBlocksWineEvent(&event,true)==blocked);
        }
        SevoCX263EventPrefix button = {.type=12};
        button.payload.mouseButton.pressed = true; assert(SevoOverlayBlocksWineEvent(&button,true));
        button.payload.mouseButton.pressed = false; assert(!SevoOverlayBlocksWineEvent(&button,true));
        CGImageRelease(image); CGImageRelease(low);
        [game close];
        puts("PASS: existing-window Retina layer preserves physical-pixel stripes, rejects 1x frames, creates no window, keeps responder; flipped coordinates agree; raw mouse/HID/keyboard gate preserves releases and lifecycle events; opacity fade retains frames and reverses continuously");
    }
    return 0;
}
