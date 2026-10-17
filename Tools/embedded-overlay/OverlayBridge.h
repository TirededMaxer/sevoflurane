#ifndef SEVO_OVERLAY_BRIDGE_H
#define SEVO_OVERLAY_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
#include <stdatomic.h>

#define SEVO_OVERLAY_MAGIC 0x5345564f4f564c31ull
#define SEVO_OVERLAY_VERSION 1
#define SEVO_OVERLAY_WIDTH 2048u
#define SEVO_OVERLAY_HEIGHT 2048u
#define SEVO_OVERLAY_PIXEL_CAPACITY (SEVO_OVERLAY_WIDTH * SEVO_OVERLAY_HEIGHT * 4u)
#define SEVO_OVERLAY_EVENT_COUNT 128u
#define SEVO_OVERLAY_HEADER_SIZE 256u
#define SEVO_OVERLAY_EVENT_SIZE 128u
#define SEVO_OVERLAY_PIXELS_OFFSET (SEVO_OVERLAY_HEADER_SIZE + SEVO_OVERLAY_EVENT_COUNT * SEVO_OVERLAY_EVENT_SIZE)
#define SEVO_OVERLAY_FILE_SIZE (SEVO_OVERLAY_PIXELS_OFFSET + 2ull * SEVO_OVERLAY_PIXEL_CAPACITY)

/* The two processes use aligned lock-free 64-bit words, with a single writer
 * for each word. Pixels are double-buffered and checked again after copying. */
typedef struct {
    uint64_t magic;
    uint64_t version;
    _Atomic uint64_t generation;
    _Atomic uint64_t active;
    _Atomic uint64_t producerTime;
    _Atomic uint64_t dimensions;
    _Atomic uint64_t consumerTime;
    _Atomic uint64_t drawableSize;
    _Atomic uint64_t eventWrite;
    _Atomic uint64_t eventRead;
    _Atomic uint64_t composedFrames;
    _Atomic uint64_t inputEvents;
    uint8_t reserved[160];
} SevoOverlayHeader;

typedef struct {
    uint32_t kind;
    uint32_t keyCode;
    double x;
    double y;
    double deltaX;
    double deltaY;
    uint64_t modifiers;
    uint32_t textLength;
    uint32_t clickCount;
    char text[64];
    uint8_t reserved[8];
} SevoOverlayEvent;

_Static_assert(sizeof(SevoOverlayHeader) == SEVO_OVERLAY_HEADER_SIZE, "header layout");
_Static_assert(sizeof(SevoOverlayEvent) == SEVO_OVERLAY_EVENT_SIZE, "event layout");
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "cross-process atomics must be lock-free");
#endif
