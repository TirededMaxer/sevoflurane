#ifndef SEVO_NATIVE_OVERLAY_TRANSPORT_H
#define SEVO_NATIVE_OVERLAY_TRANSPORT_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>

/* One writer (WebKit), one reader (Steam's paint callback). The middle
 * exchange transfers plane ownership; neither side writes the other's plane. */
typedef struct {
    char magic[8];
    uint32_t width, height, bytes, cef_id;
    uint32_t middle, active;
    uint64_t written, read, updated_ms, reserved;
} SevoNativeFrame;
_Static_assert(sizeof(SevoNativeFrame)==64,"Native frame header ABI");
static inline size_t SevoNativeFrameSize(uint32_t width,uint32_t height) {
    if(width<64||height<64||width>8192||height>8192||(uint64_t)width*height*4>128u*1024u*1024u)return 0;
    return 64+(size_t)width*height*12;
}
static inline int SevoNativeFrameValid(const SevoNativeFrame *h,uint32_t id,int width,int height) {
    return !memcmp(h->magic,"SEVOLV01",8)&&h->cef_id==id&&h->width==(uint32_t)width&&
        h->height==(uint32_t)height&&SevoNativeFrameSize(h->width,h->height)&&
        h->bytes==(uint64_t)h->width*h->height*4;
}
static inline void SevoNativeFramePublish(SevoNativeFrame *h,uint32_t *back,const void *pixels,uint64_t now) {
    memcpy((uint8_t *)(h+1)+(size_t)*back*h->bytes,pixels,h->bytes);
    *back=__atomic_exchange_n(&h->middle,*back|4,__ATOMIC_ACQ_REL)&3;
    __atomic_add_fetch(&h->written,1,__ATOMIC_RELAXED);
    __atomic_store_n(&h->updated_ms,now,__ATOMIC_RELEASE);
    __atomic_store_n(&h->active,1,__ATOMIC_RELEASE);
}
static inline const void *SevoNativeFrameRead(SevoNativeFrame *h,uint32_t *front,uint64_t now) {
    uint64_t updated=__atomic_load_n(&h->updated_ms,__ATOMIC_ACQUIRE);
    if(!__atomic_load_n(&h->active,__ATOMIC_ACQUIRE)||now<updated||now-updated>1500)return NULL;
    if(__atomic_load_n(&h->middle,__ATOMIC_ACQUIRE)&4)
        *front=__atomic_exchange_n(&h->middle,*front,__ATOMIC_ACQ_REL)&3;
    __atomic_add_fetch(&h->read,1,__ATOMIC_RELAXED);
    return (uint8_t *)(h+1)+(size_t)*front*h->bytes;
}
#ifndef _WIN32
void *SevoNativeFrameCreate(const char *path,uint32_t width,uint32_t height,uint32_t cef_id);
void SevoNativeFrameWrite(void *map,const void *pixels,uint64_t now);
void SevoNativeFrameClose(void *map);
uint64_t SevoNativeFrameReadCount(void *map);
#endif
#endif
