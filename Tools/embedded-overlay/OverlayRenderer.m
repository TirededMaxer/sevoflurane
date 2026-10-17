#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach/mach_time.h>
#import <crt_externs.h>
#import <os/lock.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <strings.h>
#include "OverlayBridge.h"

static SevoOverlayHeader *bridge;
static void *mapping;
static id<MTLDevice> renderDevice;
static id<MTLTexture> overlayTexture;
static id<MTLRenderPipelineState> pipeline;
static uint64_t textureGeneration;
static MTLPixelFormat pipelineFormat;
static BOOL installed;
static os_unfair_lock renderLock = OS_UNFAIR_LOCK_INIT;
static void (*originalPresent)(id, SEL, id);
static void (*originalTimedPresent)(id, SEL, id, CFTimeInterval);
static void (*originalMinimumPresent)(id, SEL, id, CFTimeInterval);
static void (*originalSendEvent)(id, SEL, NSEvent *);

static uint64_t clockTicks(void) { return mach_absolute_time(); }
static double secondsBetween(uint64_t now, uint64_t then) {
    static mach_timebase_info_data_t timebase;
    if (!timebase.denom) mach_timebase_info(&timebase);
    if (!then || now < then) return 1e9;
    return (double)(now - then) * timebase.numer / timebase.denom / 1e9;
}
static void note(NSString *text) {
    const char *home = getenv("HOME");
    if (!home) return;
    NSString *path = [NSString stringWithFormat:@"%s/Library/Logs/Sevoflurane-overlay.log", home];
    FILE *file = fopen(path.fileSystemRepresentation, "a");
    if (file) {
        fprintf(file, "%s pid=%d %s\n", NSDate.date.description.UTF8String, getpid(), text.UTF8String);
        fclose(file);
    }
}
static BOOL openBridge(void) {
    if (bridge) return YES;
    const char *path = getenv("SEVO_OVERLAY_BRIDGE");
    if (!path || !*path) return NO;
    int fd = open(path, O_RDWR | O_NOFOLLOW);
    if (fd < 0) return NO;
    struct stat info;
    if (fstat(fd, &info) || info.st_uid != getuid() || !S_ISREG(info.st_mode)
        || info.st_size != SEVO_OVERLAY_FILE_SIZE || (info.st_mode & 0077)) { close(fd); return NO; }
    void *address = mmap(NULL, SEVO_OVERLAY_FILE_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (address == MAP_FAILED) return NO;
    SevoOverlayHeader *header = address;
    if (header->magic != SEVO_OVERLAY_MAGIC || header->version != SEVO_OVERLAY_VERSION) {
        munmap(address, SEVO_OVERLAY_FILE_SIZE); return NO;
    }
    mapping = address; bridge = address;
    note(@"shared surface connected");
    return YES;
}
static BOOL activeFrame(void) {
    return bridge && atomic_load_explicit(&bridge->active, memory_order_acquire)
        && secondsBetween(clockTicks(), atomic_load_explicit(&bridge->producerTime, memory_order_acquire)) < 0.75;
}
static BOOL prepareTexture(id<MTLDevice> device) {
    uint64_t generation = atomic_load_explicit(&bridge->generation, memory_order_acquire);
    uint64_t size = atomic_load_explicit(&bridge->dimensions, memory_order_acquire);
    NSUInteger width = size >> 32, height = size & 0xffffffffu;
    if (!generation || width == 0 || height == 0 || width > SEVO_OVERLAY_WIDTH || height > SEVO_OVERLAY_HEIGHT) return NO;
    if (device != renderDevice) { renderDevice = device; overlayTexture = nil; pipeline = nil; textureGeneration = 0; }
    if (!overlayTexture || overlayTexture.width != width || overlayTexture.height != height || generation != textureGeneration) {
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
        desc.storageMode = MTLStorageModeShared; desc.usage = MTLTextureUsageShaderRead;
        overlayTexture = [device newTextureWithDescriptor:desc]; textureGeneration = 0;
    }
    if (!overlayTexture) return NO;
    if (generation != textureGeneration) {
        const void *pixels = (uint8_t *)mapping + SEVO_OVERLAY_PIXELS_OFFSET + (generation & 1u) * SEVO_OVERLAY_PIXEL_CAPACITY;
        [overlayTexture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:pixels bytesPerRow:width * 4];
        if (atomic_load_explicit(&bridge->generation, memory_order_acquire) != generation) return NO;
        textureGeneration = generation;
    }
    return YES;
}
static BOOL preparePipeline(id<MTLDevice> device, MTLPixelFormat format) {
    if (pipeline && pipelineFormat == format) return YES;
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct V { float4 p [[position]]; float2 uv; };\n"
        "vertex V sevo_v(uint i [[vertex_id]]) { float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)}; V v; v.p=float4(p[i],0,1); v.uv=float2((p[i].x+1)*0.5,1-(p[i].y+1)*0.5); return v; }\n"
        "fragment float4 sevo_f(V v [[stage_in]], texture2d<float> image [[texture(0)]]) { constexpr sampler s(filter::linear,address::clamp_to_edge); return image.sample(s,v.uv); }\n";
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    if (!library) { note([@"shader library failed: " stringByAppendingString:error.description]); return NO; }
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.label = @"Sevoflurane embedded macOS UI";
    desc.vertexFunction = [library newFunctionWithName:@"sevo_v"];
    desc.fragmentFunction = [library newFunctionWithName:@"sevo_f"];
    MTLRenderPipelineColorAttachmentDescriptor *color = desc.colorAttachments[0];
    color.pixelFormat = format; color.blendingEnabled = YES;
    color.sourceRGBBlendFactor = MTLBlendFactorOne; color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    color.sourceAlphaBlendFactor = MTLBlendFactorOne; color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!pipeline) { note([@"render pipeline failed: " stringByAppendingString:error.description]); return NO; }
    pipelineFormat = format; return YES;
}

/* Exported for the cloud-built pixel readback check; the game invokes exactly
 * this path from its existing command buffer, immediately before presentation. */
__attribute__((visibility("default"))) BOOL SevoOverlayComposite(id<MTLCommandBuffer> command, id<MTLTexture> target) {
    if (!target || !os_unfair_lock_trylock(&renderLock)) return NO;
    if (!openBridge()) { os_unfair_lock_unlock(&renderLock); return NO; }
    atomic_store_explicit(&bridge->consumerTime, clockTicks(), memory_order_release);
    atomic_store_explicit(&bridge->drawableSize, ((uint64_t)target.width << 32) | target.height, memory_order_release);
    if (!activeFrame()) { os_unfair_lock_unlock(&renderLock); return NO; }
    BOOL encoded = NO;
    @try {
        if (prepareTexture(command.device) && preparePipeline(command.device, target.pixelFormat)) {
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = target;
            pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
            if (encoder) {
                encoder.label = @"Sevoflurane UI composite";
                [encoder setRenderPipelineState:pipeline];
                [encoder setFragmentTexture:overlayTexture atIndex:0];
                [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [encoder endEncoding];
                uint64_t count = atomic_fetch_add_explicit(&bridge->composedFrames, 1, memory_order_relaxed);
                if (count == 0) note(@"first frame composited into game's Metal command buffer");
                encoded = YES;
            }
        }
    } @catch (NSException *exception) { note([@"composite refused: " stringByAppendingString:exception.reason ?: @"unknown"]); }
    os_unfair_lock_unlock(&renderLock);
    return encoded;
}
static void present(id self, SEL selector, id<MTLDrawable> drawable) {
    if ([drawable respondsToSelector:@selector(texture)]) SevoOverlayComposite(self, [(id<CAMetalDrawable>)drawable texture]);
    originalPresent(self, selector, drawable);
}
static void presentAt(id self, SEL selector, id<MTLDrawable> drawable, CFTimeInterval time) {
    if ([drawable respondsToSelector:@selector(texture)]) SevoOverlayComposite(self, [(id<CAMetalDrawable>)drawable texture]);
    originalTimedPresent(self, selector, drawable, time);
}
static void presentAfter(id self, SEL selector, id<MTLDrawable> drawable, CFTimeInterval time) {
    if ([drawable respondsToSelector:@selector(texture)]) SevoOverlayComposite(self, [(id<CAMetalDrawable>)drawable texture]);
    originalMinimumPresent(self, selector, drawable, time);
}
static IMP replace(Class cls, SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NULL;
    IMP original = method_getImplementation(method);
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
    return original;
}
static BOOL sendInput(NSEvent *event) {
    if (!activeFrame()) return NO;
    SevoOverlayEvent packet = {0};
    switch (event.type) {
        case NSEventTypeLeftMouseDown: packet.kind = 1; break;
        case NSEventTypeLeftMouseUp: packet.kind = 2; break;
        case NSEventTypeMouseMoved: case NSEventTypeLeftMouseDragged: packet.kind = 3; break;
        case NSEventTypeRightMouseDown: packet.kind = 4; break;
        case NSEventTypeRightMouseUp: packet.kind = 5; break;
        case NSEventTypeScrollWheel: packet.kind = 6; packet.deltaX = event.scrollingDeltaX; packet.deltaY = event.scrollingDeltaY; break;
        case NSEventTypeKeyDown: packet.kind = 7; break;
        case NSEventTypeKeyUp: packet.kind = 8; break;
        case NSEventTypeFlagsChanged: packet.kind = 9; break;
        default: return NO;
    }
    NSWindow *window = event.window;
    if (!window) return NO;
    NSRect content = window.contentView.bounds;
    NSPoint point = [window.contentView convertPoint:event.locationInWindow fromView:nil];
    packet.x = point.x / MAX(1, content.size.width);
    packet.y = (content.size.height - point.y) / MAX(1, content.size.height);
    packet.modifiers = event.modifierFlags;
    packet.clickCount = (packet.kind == 1 || packet.kind == 2 || packet.kind == 4 || packet.kind == 5) ? (uint32_t)event.clickCount : 0;
    if (packet.kind >= 7) {
        packet.keyCode = event.keyCode;
        NSData *text = packet.kind == 9 ? nil : [event.characters dataUsingEncoding:NSUTF8StringEncoding];
        packet.textLength = (uint32_t)MIN(text.length, sizeof(packet.text));
        if (packet.textLength) memcpy(packet.text, text.bytes, packet.textLength);
    }
    uint64_t write = atomic_load_explicit(&bridge->eventWrite, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&bridge->eventRead, memory_order_acquire);
    if (write - read >= SEVO_OVERLAY_EVENT_COUNT) return NO;
    SevoOverlayEvent *events = (SevoOverlayEvent *)((uint8_t *)mapping + SEVO_OVERLAY_HEADER_SIZE);
    events[write % SEVO_OVERLAY_EVENT_COUNT] = packet;
    atomic_store_explicit(&bridge->eventWrite, write + 1, memory_order_release);
    atomic_fetch_add_explicit(&bridge->inputEvents, 1, memory_order_relaxed);
    return YES;
}
static void sendEvent(id self, SEL selector, NSEvent *event) {
    if (!sendInput(event)) originalSendEvent(self, selector, event);
}
static BOOL targetProcess(void) {
    char **args = *_NSGetArgv();
    const char *name = args && args[0] ? args[0] : "";
    for (const char *at = name; *at; ++at) if (*at == '/' || *at == '\\') name = at + 1;
    return !strcasecmp(name, "cs2.exe") || (getenv("SEVO_OVERLAY_TEST") && !strcmp(name, "sevo-overlay-check"));
}
static void installHooks(void) {
    if (installed || !targetProcess()) return;
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> command = [queue commandBuffer];
    if (!command) { note(@"no Metal command buffer available"); return; }
    Class cls = object_getClass(command);
    originalPresent = (void *)replace(cls, @selector(presentDrawable:), (IMP)present);
    originalTimedPresent = (void *)replace(cls, @selector(presentDrawable:atTime:), (IMP)presentAt);
    originalMinimumPresent = (void *)replace(cls, @selector(presentDrawable:afterMinimumDuration:), (IMP)presentAfter);
    originalSendEvent = (void *)replace(NSApplication.class, @selector(sendEvent:), (IMP)sendEvent);
    installed = originalPresent != NULL;
    note([NSString stringWithFormat:@"Metal presentation hook %@ on %s", installed ? @"installed" : @"unavailable", class_getName(cls)]);
}
__attribute__((constructor)) static void bootstrap(void) {
    if (!getenv("SEVO_OVERLAY_BRIDGE")) return;
    @autoreleasepool {
        note(@"overlay library loaded; waiting for target executable identity");
        for (int i = 0; i < 40; ++i) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ installHooks(); });
        }
    }
}

/* Producer API keeps the interprocess atomic layout in C on both architectures.
 * No Swift object or pointer crosses the file mapping. */
__attribute__((visibility("default"))) void *SevoOverlayCreate(const char *path) {
    int fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
    if (fd < 0) return NULL;
    struct stat info;
    if (fstat(fd, &info) || info.st_uid != getuid() || !S_ISREG(info.st_mode) || (info.st_mode & 0077)
        || ftruncate(fd, SEVO_OVERLAY_FILE_SIZE)) { close(fd); return NULL; }
    void *map = mmap(NULL, SEVO_OVERLAY_FILE_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (map == MAP_FAILED) return NULL;
    memset(map, 0, SEVO_OVERLAY_HEADER_SIZE + SEVO_OVERLAY_EVENT_COUNT * SEVO_OVERLAY_EVENT_SIZE);
    SevoOverlayHeader *h = map;
    h->magic = SEVO_OVERLAY_MAGIC; h->version = SEVO_OVERLAY_VERSION;
    return map;
}
__attribute__((visibility("default"))) uint64_t SevoOverlayRead(void *map, uint32_t word) {
    if (!map || word < 2 || word > 11) return 0;
    return atomic_load_explicit((_Atomic uint64_t *)map + word, memory_order_acquire);
}
__attribute__((visibility("default"))) void SevoOverlayDeactivate(void *map) {
    if (map) atomic_store_explicit(&((SevoOverlayHeader *)map)->active, 0, memory_order_release);
}
__attribute__((visibility("default"))) void SevoOverlayPublish(void *map, const void *pixels, uint32_t width, uint32_t height) {
    if (!map || !pixels || !width || !height || width > SEVO_OVERLAY_WIDTH || height > SEVO_OVERLAY_HEIGHT) return;
    SevoOverlayHeader *h = map;
    uint64_t generation = atomic_load_explicit(&h->generation, memory_order_relaxed) + 1;
    memcpy((uint8_t *)map + SEVO_OVERLAY_PIXELS_OFFSET + (generation & 1) * SEVO_OVERLAY_PIXEL_CAPACITY, pixels, width * height * 4);
    atomic_store_explicit(&h->dimensions, ((uint64_t)width << 32) | height, memory_order_release);
    atomic_store_explicit(&h->generation, generation, memory_order_release);
    atomic_store_explicit(&h->producerTime, clockTicks(), memory_order_release);
    atomic_store_explicit(&h->active, 1, memory_order_release);
}
__attribute__((visibility("default"))) int SevoOverlayPop(void *map, void *packet) {
    if (!map || !packet) return 0;
    SevoOverlayHeader *h = map;
    uint64_t read = atomic_load_explicit(&h->eventRead, memory_order_relaxed);
    if (read == atomic_load_explicit(&h->eventWrite, memory_order_acquire)) return 0;
    memcpy(packet, (uint8_t *)map + SEVO_OVERLAY_HEADER_SIZE + (read % SEVO_OVERLAY_EVENT_COUNT) * SEVO_OVERLAY_EVENT_SIZE, SEVO_OVERLAY_EVENT_SIZE);
    atomic_store_explicit(&h->eventRead, read + 1, memory_order_release);
    return 1;
}
