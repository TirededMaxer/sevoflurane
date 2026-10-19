#import "NativeOverlayRenderer.h"
#import "NativeOverlayTransport.h"
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>

@interface SevoNativeWebRenderer ()
@property(nonatomic,strong) WKWebView *view;
@property(nonatomic,strong) CALayer *root,*carrier;
@property(nonatomic,weak) CALayer *parent;
@property(nonatomic,strong) CARenderer *renderer;
@property(nonatomic,strong) id<MTLCommandQueue> queue;
@property(nonatomic,strong) id<MTLTexture> texture;
@property(nonatomic,strong) id<MTLBuffer> completionByte;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic) IOSurfaceRef surface;
@property(nonatomic) void *producer;
@property(nonatomic) uint8_t *pixels;
@property(nonatomic) uint32_t width,height;
@property(nonatomic) BOOL inFlight,stopped;
@property(nonatomic,readwrite) uint64_t frames;
@end
@implementation SevoNativeWebRenderer
- (instancetype)initWithWebView:(WKWebView *)view width:(uint32_t)width height:(uint32_t)height
                      framePath:(NSString *)path cefID:(uint32_t)cefID {
    if(!(self=[super init]))return nil;
    _view=view;_width=width;_height=height;
    _producer=SevoNativeFrameCreate(path.fileSystemRepresentation,width,height,cefID);
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();_queue=[device newCommandQueue];
    _pixels=malloc((size_t)width*height*4);
    size_t stride=((size_t)width*4+63)&~(size_t)63;
    _surface=IOSurfaceCreate((__bridge CFDictionaryRef)@{
        (__bridge NSString *)kIOSurfaceWidth:@(width),(__bridge NSString *)kIOSurfaceHeight:@(height),
        (__bridge NSString *)kIOSurfaceBytesPerRow:@(stride),(__bridge NSString *)kIOSurfaceBytesPerElement:@4,
        (__bridge NSString *)kIOSurfacePixelFormat:@(0x42475241)});
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
        width:width height:height mipmapped:NO];
    d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
    if(_surface)_texture=[device newTextureWithDescriptor:d iosurface:_surface plane:0];
    _completionByte=[device newBufferWithLength:256 options:MTLResourceStorageModeShared];
    if(!_producer||!_queue||!_pixels||!_texture||!_completionByte||!view.layer)return nil;
    _parent=view.layer.superlayer;
    [CATransaction begin];[CATransaction setDisableActions:YES];
    _root=[CALayer layer];_root.bounds=CGRectMake(0,0,width,height);_root.anchorPoint=CGPointZero;
    _carrier=[CALayer layer];_carrier.bounds=view.bounds;_carrier.anchorPoint=CGPointZero;
    CGFloat sx=width/view.bounds.size.width,sy=height/view.bounds.size.height;
    _carrier.position=CGPointMake(-view.layer.frame.origin.x*sx,-view.layer.frame.origin.y*sy);
    _carrier.transform=CATransform3DMakeScale(sx,sy,1);
    [_carrier addSublayer:view.layer];[_root addSublayer:_carrier];
    _renderer=[CARenderer rendererWithMTLTexture:_texture options:@{kCARendererMetalCommandQueue:_queue}];
    _renderer.layer=_root;_renderer.bounds=_root.bounds;
    [CATransaction commit];[CATransaction flush];
    __weak SevoNativeWebRenderer *weak=self;
    _timer=[NSTimer timerWithTimeInterval:1.0/60 repeats:YES block:^(NSTimer *t){(void)t;[weak render];}];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    return self;
}
- (void)render {
    if(self.stopped||self.inFlight)return;
    self.inFlight=YES;
    id<MTLCommandBuffer> clear=[self.queue commandBuffer];
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=self.texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;
    pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);
    id<MTLRenderCommandEncoder> encoder=[clear renderCommandEncoderWithDescriptor:pass];
    if(!encoder){self.inFlight=NO;[self stop];return;}
    [encoder endEncoding];[clear commit];
    [self.renderer beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL];
    [self.renderer addUpdateRect:self.root.bounds];[self.renderer render];[self.renderer endFrame];
    id<MTLCommandBuffer> done=[self.queue commandBuffer];
    id<MTLBlitCommandEncoder> blit=[done blitCommandEncoder];
    if(!blit){self.inFlight=NO;[self stop];return;}
    [blit copyFromTexture:self.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(1,1,1) toBuffer:self.completionByte destinationOffset:0
        destinationBytesPerRow:256 destinationBytesPerImage:256];[blit endEncoding];
    [done addCompletedHandler:^(id<MTLCommandBuffer> command){
        BOOL copied=NO;
        if(command.status==MTLCommandBufferStatusCompleted&&
           IOSurfaceLock(self.surface,kIOSurfaceLockReadOnly,NULL)==KERN_SUCCESS){
            const uint8_t *base=IOSurfaceGetBaseAddress(self.surface);
            size_t stride=IOSurfaceGetBytesPerRow(self.surface),row=(size_t)self.width*4;
            /* CARenderer row orientation was calibrated by the accepted four-corner frame. */
            for(uint32_t y=0;y<self.height;y++)memcpy(self.pixels+y*row,base+(self.height-1-y)*stride,row);
            copied=IOSurfaceUnlock(self.surface,kIOSurfaceLockReadOnly,NULL)==KERN_SUCCESS;
            if(copied)SevoNativeFrameWrite(self.producer,self.pixels,(uint64_t)(NSDate.date.timeIntervalSince1970*1000));
        }
        dispatch_async(dispatch_get_main_queue(),^{
            self.inFlight=NO;if(copied)self.frames++;
            if(!copied)[self stop];
            if(self.stopped&&self.producer){SevoNativeFrameClose(self.producer);self.producer=NULL;}
        });
    }];[done commit];
}
- (void)stop {
    if(self.stopped)return;self.stopped=YES;[self.timer invalidate];self.timer=nil;
    if(self.view.layer.superlayer==self.carrier){
        [self.view.layer removeFromSuperlayer];[self.parent addSublayer:self.view.layer];
    }
    if(!self.inFlight&&self.producer){SevoNativeFrameClose(self.producer);self.producer=NULL;}
}
- (uint64_t)consumedFrames { return SevoNativeFrameReadCount(self.producer); }
- (void)dealloc {
    [_timer invalidate];if(_producer)SevoNativeFrameClose(_producer);
    if(_surface)CFRelease(_surface);free(_pixels);
}
@end
