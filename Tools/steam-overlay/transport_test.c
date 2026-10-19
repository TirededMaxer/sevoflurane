#include "../../Sevoflurane/Web/NativeOverlayTransport.h"
#include <assert.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
static SevoNativeFrame *shared;
static uint32_t back=2,front=0;
static int finished;
static void *write_frames(void *unused) {
    (void)unused;uint64_t pixels[2048];
    for(uint64_t n=1;n<=20000;n++){
        for(size_t i=0;i<2048;i++)pixels[i]=n;
        SevoNativeFramePublish(shared,&back,pixels,1000);
    }
    __atomic_store_n(&finished,1,__ATOMIC_RELEASE);return NULL;
}
int main(void) {
    size_t size=SevoNativeFrameSize(64,64);assert(size==64+64*64*12);
    assert(!SevoNativeFrameSize(0,64)&&!SevoNativeFrameSize(8192,8192));
    shared=calloc(1,size);assert(shared);memcpy(shared->magic,"SEVOLV01",8);
    shared->width=shared->height=64;shared->bytes=64*64*4;shared->cef_id=4;shared->middle=1;
    assert(SevoNativeFrameValid(shared,4,64,64));assert(!SevoNativeFrameValid(shared,5,64,64));
    assert(!SevoNativeFrameRead(shared,&front,1000));
    pthread_t producer;assert(!pthread_create(&producer,NULL,write_frames,NULL));
    uint64_t previous=0;size_t samples=0;
    while(!__atomic_load_n(&finished,__ATOMIC_ACQUIRE)){
        const uint64_t *pixels=SevoNativeFrameRead(shared,&front,1000);if(!pixels)continue;
        uint64_t n=pixels[0];assert(n>=previous);previous=n;
        for(size_t i=0;i<2048;i++)assert(pixels[i]==n);
        samples++;
    }
    assert(!pthread_join(producer,NULL));
    const uint64_t *last=SevoNativeFrameRead(shared,&front,1000);assert(last&&last[0]==20000);
    assert(!SevoNativeFrameRead(shared,&front,2501));
    __atomic_store_n(&shared->active,0,__ATOMIC_RELEASE);assert(!SevoNativeFrameRead(shared,&front,1000));
    printf("PASS: 20000 concurrent native frames, %zu stable reads, final frame and stale/inactive recovery\n",samples);
    free(shared);return 0;
}
