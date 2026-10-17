#include "../../Tools/embedded-overlay/OverlayBridge.h"
#include <mach/mach_time.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
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
    atomic_store_explicit(&h->producerTime, SevoOverlayNow(), memory_order_release);
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
