#include <math.h>
#include <string.h>
#import "WindowSurface.h"
#import "InputPolicy.h"
#import <Metal/Metal.h>
#include <assert.h>
@interface FlippedGameView : NSView @end
@implementation FlippedGameView
- (BOOL)isFlipped { return YES; }
@end
static NSMutableData *makePixels(size_t width, size_t height) {
    NSMutableData *bytes = [NSMutableData dataWithLength:width * height * 4];
    uint8_t *p = bytes.mutableBytes;
    for (size_t y = 0; y < height; ++y) for (size_t x = 0; x < width; ++x) {
        size_t i = (y * width + x) * 4;
        p[i] = p[i+1] = p[i+2] = x & 1 ? 255 : 0; p[i+3] = 255;
        if (y < 4) { p[i] = p[i+1] = 0; p[i+2] = 255; }
        if (y >= height-4) { p[i] = 255; p[i+1] = p[i+2] = 0; }
    }
    return bytes;
}
static void checkGPUContents(CALayer *source, NSData *bytes) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { puts("UNAVAILABLE: IOSurface GPU readback; native pixel-buffer checks still run"); return; }
    id<MTLCommandQueue> queue = [device newCommandQueue];
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
        width:3024 height:1964 mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    assert(texture && queue);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    CALayer *root = [CALayer layer];
    root.frame = CGRectMake(0,0,3024,1964);
    root.contents = source.contents;
    root.minificationFilter = root.magnificationFilter = kCAFilterNearest;
    [CATransaction commit];
    CARenderer *renderer = [CARenderer rendererWithMTLTexture:texture options:@{kCARendererMetalCommandQueue:queue}];
    renderer.layer = root; renderer.bounds = root.bounds;
    [renderer beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL];
    [renderer addUpdateRect:root.bounds]; [renderer render]; [renderer endFrame];
    id<MTLCommandBuffer> completion = [queue commandBuffer];
    [completion commit]; [completion waitUntilCompleted];
    assert(completion.status == MTLCommandBufferStatusCompleted);
    uint8_t pixels[80];
    [texture getBytes:pixels bytesPerRow:80 fromRegion:MTLRegionMake2D(10,100,20,1) mipmapLevel:0];
    for (size_t x = 0; x < 20; ++x) assert(pixels[x*4] == ((x+10) & 1 ? 255 : 0));
    const NSUInteger points[4][2] = {{10,0},{10,1963},{10,100},{11,100}};
    uint8_t actual[4][4];
    for (int i = 0; i < 4; ++i)
        [texture getBytes:actual[i] bytesPerRow:4 fromRegion:MTLRegionMake2D(points[i][0],points[i][1],1,1) mipmapLevel:0];
    // Compare orientation, channel order and opaque alpha against the former
    // CGImage path using the same asymmetric pixels, not only gray stripes.
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)bytes);
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGImageRef reference = CGImageCreate(3024,1964,8,32,3024*4,color,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst,provider,NULL,false,kCGRenderingIntentDefault);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    root.contents = (__bridge id)reference;
    [CATransaction commit];
    [renderer beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL];
    [renderer addUpdateRect:root.bounds]; [renderer render]; [renderer endFrame];
    completion = [queue commandBuffer]; [completion commit]; [completion waitUntilCompleted];
    assert(completion.status == MTLCommandBufferStatusCompleted);
    for (int i = 0; i < 4; ++i) {
        uint8_t expected[4];
        [texture getBytes:expected bytesPerRow:4 fromRegion:MTLRegionMake2D(points[i][0],points[i][1],1,1) mipmapLevel:0];
        for (int c = 0; c < 4; ++c) assert(abs((int)actual[i][c]-(int)expected[c]) <= 1);
    }
    CGImageRelease(reference); CGColorSpaceRelease(color); CGDataProviderRelease(provider);
    puts("PASS: IOSurface CALayer GPU readback preserves physical pixels, orientation, channel order and alpha");
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
        NSMutableData *image = makePixels(3024,1964), *low = makePixels(1512,982);
        game.contentView.wantsLayer = YES;
        CAMetalLayer *backbuffer = [CAMetalLayer layer];
        backbuffer.frame = game.contentView.bounds;
        backbuffer.drawableSize = CGSizeMake(1512,982);
        [game.contentView.layer addSublayer:backbuffer];
        SevoWindowSurface *surface = [SevoWindowSurface new];
        assert([surface presentPixels:low.bytes width:1512 height:982 inWindow:game scale:2] == SevoSurfaceRejected);
        assert([surface presentPixels:image.bytes width:3024 height:1964 inWindow:game scale:2] == SevoSurfacePresented);
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
        IOSurfaceRef uploaded = (__bridge IOSurfaceRef)surface.layer.contents;
        assert(CFGetTypeID(uploaded) == IOSurfaceGetTypeID());
        assert(IOSurfaceGetWidth(uploaded) == 3024 && IOSurfaceGetHeight(uploaded) == 1964);
        assert(NSApp.windows.count == count && NSApp.keyWindow == key && game.firstResponder == responder);
        assert(IOSurfaceLock(uploaded,kIOSurfaceLockReadOnly,NULL) == KERN_SUCCESS);
        const uint8_t *pixels = IOSurfaceGetBaseAddress(uploaded);
        size_t stride = IOSurfaceGetBytesPerRow(uploaded);
        for (size_t x = 10; x < 30; ++x) assert(pixels[100*stride+x*4] == (x & 1 ? 255 : 0));
        IOSurfaceUnlock(uploaded,kIOSurfaceLockReadOnly,NULL);
        checkGPUContents(surface.layer,image);
        // Busy buffers cannot stall the event thread or discard the image.
        IOSurfaceRef held[3];
        for (int i = 0; i < 3; ++i) {
            held[i] = (__bridge IOSurfaceRef)surface.layer.contents;
            CFRetain(held[i]); IOSurfaceIncrementUseCount(held[i]);
            SevoSurfaceResult result = [surface presentPixels:image.bytes width:3024 height:1964 inWindow:game scale:2];
            assert(result == (i < 2 ? SevoSurfacePresented : SevoSurfaceBusy));
        }
        assert(surface.layer.contents && surface.layer.superlayer);
        for (int i = 0; i < 3; ++i) { IOSurfaceDecrementUseCount(held[i]); CFRelease(held[i]); }
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
        [game close];
        puts("PASS: existing-window reusable IOSurface Retina layer preserves physical-pixel stripes, rejects 1x frames, creates no window, keeps responder; flipped coordinates agree; raw mouse/HID/keyboard gate preserves releases and lifecycle events; opacity fade retains frames and reverses continuously");
    }
    return 0;
}
