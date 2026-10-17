#include <math.h>
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>
#import <crt_externs.h>
#import <os/lock.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <strings.h>
#include "OverlayBridge.h"
#import "WindowSurface.h"
#include "InputPolicy.h"

static SevoOverlayHeader *bridge;
static void *mapping;
static id<MTLDevice> renderDevice;
static id<MTLTexture> overlayTexture;
static id<MTLRenderPipelineState> pipeline;
static uint64_t textureGeneration;
static MTLPixelFormat pipelineFormat;
static BOOL installed;
static os_unfair_lock renderLock = OS_UNFAIR_LOCK_INIT;
static SevoWindowSurface *windowSurface;
static NSTimer *windowTimer;
static uint64_t windowGeneration;
static BOOL wasWindowActive;
static CGPoint openingCursor, overlayCursor;
static BOOL haveOverlayCursor;
static CGPoint openingChordCursor;
static uint64_t openingChordTime;
static CGPoint currentCursor(void);
static uint64_t cursorResumeEpoch;
static _Atomic uint64_t heldKeys[4];
static BOOL windowBackend(void) { return getenv("SEVO_OVERLAY_BACKEND") && !strcmp(getenv("SEVO_OVERLAY_BACKEND"), "window"); }
static void (*originalPresent)(id, SEL, id);
static void (*originalTimedPresent)(id, SEL, id, CFTimeInterval);
static void (*originalMinimumPresent)(id, SEL, id, CFTimeInterval);
static void (*originalSendEvent)(id, SEL, NSEvent *);
static void (*originalPostEvent)(id, SEL, const SevoCX263EventPrefix *);

static uint64_t clockTicks(void) { return SevoOverlayNow(); }
static double secondsBetween(uint64_t now, uint64_t then) {
    if (!then || now < then) return 1e9;
    return (double)(now - then) / 1e9;
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
    atomic_store_explicit(&bridge->backend, 1, memory_order_release);
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
                // D3DMetal also uses commandBufferWithUnretainedReferences.
                // Keep each frame's resources alive until that GPU work ends.
                id<MTLTexture> frameTexture = overlayTexture;
                id<MTLRenderPipelineState> framePipeline = pipeline;
                [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
                    [frameTexture label]; [framePipeline label];
                    if (completed.status == MTLCommandBufferStatusError) note(@"overlay command buffer failed");
                }];
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
    NSWindow *window = event.window ?: NSApp.keyWindow;
    if (!window) return NO;
    NSPoint point = SevoOverlayNormalizedPoint(window.contentView, event.locationInWindow);
    packet.x = point.x;
    packet.y = point.y;
    if (packet.kind <= 6 && event.CGEvent) {
        overlayCursor = CGEventGetLocation(event.CGEvent);
        haveOverlayCursor = YES;
    }
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
    // Backpressure may drop a UI event, but must never leak it into the game.
    if (write - read >= SEVO_OVERLAY_EVENT_COUNT) return YES;
    SevoOverlayEvent *events = (SevoOverlayEvent *)((uint8_t *)mapping + SEVO_OVERLAY_HEADER_SIZE);
    events[write % SEVO_OVERLAY_EVENT_COUNT] = packet;
    atomic_store_explicit(&bridge->eventWrite, write + 1, memory_order_release);
    atomic_fetch_add_explicit(&bridge->inputEvents, 1, memory_order_relaxed);
    return YES;
}
static void sendEvent(id self, SEL selector, NSEvent *event) {
    // Capture the game-menu position before Steam sees the opening chord:
    // Steam may move to its separately remembered overlay pointer on entry.
    if (!activeFrame() && event.type == NSEventTypeKeyDown && event.keyCode == 48
        && (event.modifierFlags & NSEventModifierFlagShift)) {
        openingChordCursor = currentCursor();
        openingChordTime = clockTicks();
    }
    BOOL captured = sendInput(event);
    // Wine must release keys/modifiers held before the overlay opened.
    // Its event queue below drops new presses, while releases still flow.
    BOOL release = event.type == NSEventTypeKeyUp || event.type == NSEventTypeFlagsChanged
        || event.type == NSEventTypeLeftMouseUp || event.type == NSEventTypeRightMouseUp;
    if (!captured || release) originalSendEvent(self, selector, event);
}
static void postEvent(id self, SEL selector, const SevoCX263EventPrefix *event) {
    if (SevoOverlayBlocksWineEvent(event, activeFrame())) {
        if (bridge) atomic_fetch_add_explicit(&bridge->blockedEvents, 1, memory_order_relaxed);
        return;
    }
    if (event && (event->type == 8 || event->type == 9) && event->payload.key.keyCode < 256) {
        uint16_t key = event->payload.key.keyCode;
        uint64_t mask = 1ull << (key % 64);
        if (event->type == 8) atomic_fetch_or(&heldKeys[key / 64], mask);
        else atomic_fetch_and(&heldKeys[key / 64], ~mask);
    }
    originalPostEvent(self, selector, event);
}
static NSWindow *gameWindow(void) {
    NSWindow *best = nil;
    for (NSWindow *candidate in NSApp.windows) {
        if (![candidate isKindOfClass:NSClassFromString(@"WineWindow")] || !candidate.isVisible
            || NSWidth(candidate.contentView.bounds) < 128 || NSHeight(candidate.contentView.bounds) < 128) continue;
        if (!best || NSWidth(candidate.frame) * NSHeight(candidate.frame) > NSWidth(best.frame) * NSHeight(best.frame)) best = candidate;
    }
    return best;
}
static void storeDouble(_Atomic uint64_t *word, double value) {
    uint64_t bits; memcpy(&bits, &value, sizeof(bits));
    atomic_store_explicit(word, bits, memory_order_release);
}
static void releaseHeldGameKeys(NSWindow *window) {
    SEL post = NSSelectorFromString(@"postKeyEvent:");
    if (![window respondsToSelector:post]) return;
    Class controllerClass = NSClassFromString(@"WineApplicationController");
    SEL shared = NSSelectorFromString(@"sharedController");
    id controller = [controllerClass respondsToSelector:shared] ? ((id (*)(id, SEL))objc_msgSend)(controllerClass, shared) : nil;
    SEL noteKey = NSSelectorFromString(@"noteKey:pressed:");
    for (uint16_t key = 0; key < 256; ++key) {
        if (!(atomic_load(&heldKeys[key / 64]) & (1ull << (key % 64)))) continue;
        NSEvent *up = [NSEvent keyEventWithType:NSEventTypeKeyUp location:NSZeroPoint modifierFlags:0
            timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil
            characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:key];
        // Invoke Wine's existing conversion, which allocates/owns its event.
        ((void (*)(id, SEL, id))objc_msgSend)(window, post, up);
        if ([controller respondsToSelector:noteKey]) ((void (*)(id, SEL, uint16_t, BOOL))objc_msgSend)(controller, noteKey, key, NO);
        atomic_fetch_and(&heldKeys[key / 64], ~(1ull << (key % 64)));
        atomic_fetch_add(&bridge->releasedKeys, 1);
    }
}
static id wineController(void) {
    Class cls = NSClassFromString(@"WineApplicationController");
    SEL shared = NSSelectorFromString(@"sharedController");
    return [cls respondsToSelector:shared] ? ((id (*)(id, SEL))objc_msgSend)(cls, shared) : nil;
}
static BOOL gameRequestsVisibleCursor(id controller) {
    // The 26.3 controller records the game's actual request, unlike the
    // system cursor which the overlay temporarily shows during an FPS match.
    Ivar ivar = class_getInstanceVariable(object_getClass(controller), "clientWantsCursorHidden");
    if (!ivar) return NO;
    const char *type = ivar_getTypeEncoding(ivar);
    ptrdiff_t offset = ivar_getOffset(ivar);
    if (!type || (strcmp(type, @encode(BOOL)) && strcmp(type, "c") && strcmp(type, "B"))
        || offset < 0 || (size_t)offset + sizeof(BOOL) > class_getInstanceSize(object_getClass(controller))) return NO;
    BOOL hidden;
    memcpy(&hidden, (const uint8_t *)(__bridge const void *)controller + offset, sizeof(hidden));
    return !hidden;
}
static CGPoint currentCursor(void) {
    CGEventRef event = CGEventCreate(NULL);
    CGPoint point = event ? CGEventGetLocation(event) : CGPointMake(NAN, NAN);
    if (event) CFRelease(event);
    return point;
}
static void resumeMenuCursor(NSWindow *window) {
    if (!haveOverlayCursor) return;
    CGPoint last = overlayCursor, opening = openingCursor;
    uint64_t epoch = ++cursorResumeEpoch;
    __weak NSWindow *target = window;
    // Steam restores the game cursor after its deactivation callback. Wait
    // one short handoff, then correct only the reported rollback to the
    // opening position. New physical motion and hidden FPS cursors win.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (epoch != cursorResumeEpoch || activeFrame() || !NSApp.isActive || gameWindow() != target) return;
        id controller = wineController();
        SEL set = NSSelectorFromString(@"setCursorPosition:");
        SEL move = NSSelectorFromString(@"handleMouseMove:");
        CGPoint current = currentCursor();
        if (!controller || !gameRequestsVisibleCursor(controller)
            || ![controller respondsToSelector:set] || ![controller respondsToSelector:move]
            || !isfinite(current.x) || !isfinite(last.x) || !isfinite(opening.x)
            || hypot(current.x-opening.x, current.y-opening.y) > 2
            || hypot(current.x-last.x, current.y-last.y) <= 2) return;
        if (!((BOOL (*)(id, SEL, CGPoint))objc_msgSend)(controller, set, last)) return;
        // Use Wine's own absolute-move conversion so Windows' cursor state
        // catches up as well. This event is delivered to Wine directly,
        // never posted globally and contains no button or raw look delta.
        CGEventRef cg = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, last, kCGMouseButtonLeft);
        if (cg) {
            NSEvent *event = [NSEvent eventWithCGEvent:cg];
            if (event) ((void (*)(id, SEL, id))objc_msgSend)(controller, move, event);
            CFRelease(cg);
        }
        atomic_fetch_add(&bridge->cursorResumes, 1);
        note(@"visible game-menu cursor continued from overlay exit position");
    });
}
static void updatePresentationState(void) {
    atomic_store(&bridge->nativeLayerVisible, windowSurface.layer.superlayer != nil);
    storeDouble(&bridge->presentationOpacity, windowSurface.layer.opacity);
}
static void updateWindowSurface(void) {
    if (!installed || !openBridge()) return;
    NSWindow *window = gameWindow();
    if (!window) { [windowSurface detach]; updatePresentationState(); wasWindowActive = NO; ++cursorResumeEpoch; return; }
    NSView *content = window.contentView;
    NSRect screen = [window convertRectToScreen:[content convertRect:content.bounds toView:nil]];
    CGFloat scale = window.backingScaleFactor;
    storeDouble(&bridge->gameX, NSMinX(screen)); storeDouble(&bridge->gameY, NSMinY(screen));
    storeDouble(&bridge->gameWidth, NSWidth(screen)); storeDouble(&bridge->gameHeight, NSHeight(screen));
    storeDouble(&bridge->gameScale, scale);
    atomic_store(&bridge->drawableSize, ((uint64_t)llround(NSWidth(screen)*scale) << 32) | (uint32_t)llround(NSHeight(screen)*scale));
    atomic_store(&bridge->backend, 2);
    atomic_store_explicit(&bridge->consumerTime, clockTicks(), memory_order_release);
    BOOL live = secondsBetween(clockTicks(), atomic_load(&bridge->producerTime)) < 0.75;
    CFTimeInterval time = (double)clockTicks() / 1e9;
    if (!NSApp.isActive || !live) {
        [windowSurface detach]; updatePresentationState(); windowGeneration = 0;
        wasWindowActive = NO; ++cursorResumeEpoch; return;
    }
    if (!activeFrame()) {
        if (wasWindowActive) resumeMenuCursor(window);
        wasWindowActive = NO;
        [windowSurface updateVisibility:NO atTime:time]; updatePresentationState();
        if (!windowSurface.layer.superlayer) windowGeneration = 0;
        return;
    }
    if (!wasWindowActive) {
        releaseHeldGameKeys(window);
        overlayCursor = currentCursor();
        openingCursor = secondsBetween(clockTicks(), openingChordTime) < 2
            ? openingChordCursor : overlayCursor;
        openingChordTime = 0;
        haveOverlayCursor = isfinite(overlayCursor.x);
        ++cursorResumeEpoch;
    }
    wasWindowActive = YES;
    [windowSurface updateVisibility:YES atTime:time]; updatePresentationState();
    uint64_t generation = atomic_load_explicit(&bridge->generation, memory_order_acquire);
    uint64_t dimensions = atomic_load_explicit(&bridge->dimensions, memory_order_acquire);
    size_t width = dimensions >> 32, height = dimensions & 0xffffffffu;
    if (!generation || !width || !height || width > SEVO_OVERLAY_WIDTH || height > SEVO_OVERLAY_HEIGHT) return;
    if (windowGeneration == generation && windowSurface.layer.superlayer == content.layer) return;
    const uint8_t *source = (uint8_t *)mapping + SEVO_OVERLAY_PIXELS_OFFSET + (generation & 1u) * SEVO_OVERLAY_PIXEL_CAPACITY;
    NSData *data = [NSData dataWithBytes:source length:width*height*4];
    if (atomic_load_explicit(&bridge->generation, memory_order_acquire) != generation) return;
    if (!windowSurface) windowSurface = [SevoWindowSurface new];
    SevoSurfaceResult result = [windowSurface presentPixels:data.bytes width:width height:height inWindow:window scale:scale];
    if (result == SevoSurfacePresented) {
        windowGeneration = generation;
        [windowSurface updateVisibility:YES atTime:time]; updatePresentationState();
        if (atomic_fetch_add(&bridge->composedFrames, 1) == 0) note(@"first native-resolution UI layer attached inside the game window");
    } else if (result == SevoSurfaceRejected) {
        [windowSurface detach]; updatePresentationState(); windowGeneration = 0;
    }
}
static BOOL targetProcess(void) {
    char **args = *_NSGetArgv();
    const char *name = args && args[0] ? args[0] : "";
    for (const char *at = name; *at; ++at) if (*at == '/' || *at == '\\') name = at + 1;
    return !strcasecmp(name, "cs2.exe") || (getenv("SEVO_OVERLAY_TEST") && !strcmp(name, "sevo-overlay-check"));
}
static void installHooks(void) {
    if (installed || !targetProcess() || !NSApp) return;
    Class wineQueue = NSClassFromString(@"WineEventQueue");
    if (!wineQueue || !class_getInstanceMethod(wineQueue, @selector(postEvent:))) return;
    if (windowBackend()) {
        originalSendEvent = (void *)replace(object_getClass(NSApp), @selector(sendEvent:), (IMP)sendEvent);
        originalPostEvent = (void *)replace(wineQueue, @selector(postEvent:), (IMP)postEvent);
        installed = originalSendEvent && originalPostEvent;
        windowTimer = [NSTimer timerWithTimeInterval:1.0/60 repeats:YES block:^(NSTimer *timer) { updateWindowSurface(); }];
        [NSRunLoop.mainRunLoop addTimer:windowTimer forMode:NSRunLoopCommonModes];
        note(@"same-window presentation and Wine input gate installed; no additional game UI window");
    } else {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandBuffer> command = [[device newCommandQueue] commandBuffer];
        if (!command) return;
        Class cls = object_getClass(command);
        originalPresent = (void *)replace(cls, @selector(presentDrawable:), (IMP)present);
        originalTimedPresent = (void *)replace(cls, @selector(presentDrawable:atTime:), (IMP)presentAt);
        originalMinimumPresent = (void *)replace(cls, @selector(presentDrawable:afterMinimumDuration:), (IMP)presentAfter);
        originalSendEvent = (void *)replace(object_getClass(NSApp), @selector(sendEvent:), (IMP)sendEvent);
        originalPostEvent = (void *)replace(wineQueue, @selector(postEvent:), (IMP)postEvent);
        installed = originalPresent && originalSendEvent && originalPostEvent;
        note([NSString stringWithFormat:@"Metal presentation hook installed on %s", class_getName(cls)]);
    }
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
