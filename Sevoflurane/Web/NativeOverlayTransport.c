#include "NativeOverlayTransport.h"
#include <fcntl.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>
typedef struct { SevoNativeFrame *header;size_t size;uint32_t back; } NativeProducer;
void *SevoNativeFrameCreate(const char *path,uint32_t width,uint32_t height,uint32_t cef_id) {
    size_t size=SevoNativeFrameSize(width,height);if(!size||!cef_id)return NULL;
    int fd=open(path,O_CREAT|O_TRUNC|O_RDWR|O_NOFOLLOW,0600);if(fd<0)return NULL;
    if(ftruncate(fd,(off_t)size)){close(fd);return NULL;}
    SevoNativeFrame *h=mmap(NULL,size,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);close(fd);
    if(h==MAP_FAILED)return NULL;
    NativeProducer *p=calloc(1,sizeof(*p));if(!p){munmap(h,size);return NULL;}
    memset(h,0,64);memcpy(h->magic,"SEVOLV01",8);h->width=width;h->height=height;
    h->bytes=width*height*4;h->cef_id=cef_id;h->middle=1;
    p->header=h;p->size=size;p->back=2;return p;
}
void SevoNativeFrameWrite(void *map,const void *pixels,uint64_t now) {
    NativeProducer *p=map;if(p&&pixels)SevoNativeFramePublish(p->header,&p->back,pixels,now);
}
void SevoNativeFrameClose(void *map) {
    NativeProducer *p=map;if(!p)return;
    __atomic_store_n(&p->header->active,0,__ATOMIC_RELEASE);
    munmap(p->header,p->size);free(p);
}
uint64_t SevoNativeFrameReadCount(void *map) {
    NativeProducer *p=map;
    return p?__atomic_load_n(&p->header->read,__ATOMIC_ACQUIRE):0;
}
