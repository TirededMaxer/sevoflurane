#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <mach/mach_time.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include "OverlayBridge.h"
extern BOOL SevoOverlayComposite(id<MTLCommandBuffer>, id<MTLTexture>);

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) { fprintf(stderr, "usage: sevo-overlay-check <temporary-surface-file>\n"); return 2; }
        int fd = open(argv[1], O_CREAT | O_EXCL | O_RDWR, 0600);
        if (fd < 0 || ftruncate(fd, SEVO_OVERLAY_FILE_SIZE)) return 2;
        void *map = mmap(NULL, SEVO_OVERLAY_FILE_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        close(fd);
        if (map == MAP_FAILED) return 2;
        SevoOverlayHeader *h = map;
        h->magic = SEVO_OVERLAY_MAGIC; h->version = SEVO_OVERLAY_VERSION;
        h->dimensions = (2ull << 32) | 2;
        uint8_t *pixels = (uint8_t *)map + SEVO_OVERLAY_PIXELS_OFFSET + SEVO_OVERLAY_PIXEL_CAPACITY;
        for (int i = 0; i < 4; ++i) { pixels[i*4+0] = 0; pixels[i*4+1] = 0; pixels[i*4+2] = 128; pixels[i*4+3] = 128; }
        h->generation = 1; h->active = 1; h->producerTime = mach_absolute_time();
        setenv("SEVO_OVERLAY_BRIDGE", argv[1], 1);
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { fprintf(stderr, "SKIP: runner exposes no Metal device; run this cloud-built check on the target Mac\n"); unlink(argv[1]); return 77; }
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];
        desc.storageMode = MTLStorageModeShared; desc.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> target = [device newTextureWithDescriptor:desc];
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> command = [queue commandBuffer];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore; pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,1,1);
        [[command renderCommandEncoderWithDescriptor:pass] endEncoding];
        if (!SevoOverlayComposite(command, target)) return 3;
        [command commit]; [command waitUntilCompleted];
        if (command.status == MTLCommandBufferStatusError) { fprintf(stderr, "%s\n", command.error.description.UTF8String); return 4; }
        uint8_t output[64]; [target getBytes:output bytesPerRow:16 fromRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0];
        BOOL blended = output[0] >= 125 && output[0] <= 129 && output[2] >= 126 && output[2] <= 130 && output[3] == 255;
        h->producerTime = 1;
        BOOL staleRejected = !SevoOverlayComposite([queue commandBuffer], target);
        printf("%s: actual Metal pixel readback BGRA=%u,%u,%u,%u; stale producer rejected=%d; composed=%llu\n", blended && staleRejected ? "PASS" : "FAIL", output[0],output[1],output[2],output[3],staleRejected,(unsigned long long)h->composedFrames);
        munmap(map, SEVO_OVERLAY_FILE_SIZE); unlink(argv[1]);
        return blended && staleRejected ? 0 : 5;
    }
}
