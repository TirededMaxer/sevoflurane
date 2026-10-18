#ifndef SEVO_PAINT_FRAME_H
#define SEVO_PAINT_FRAME_H
#include <stddef.h>
#include <stdint.h>
/* File and shared-memory fields are little endian on the supported x64/arm64 hosts. */
#define SEVO_FRAME_MAGIC "SEVOPNT1"
#define SEVO_STATS_MAGIC "SEVOSTA1"
#define SEVO_FRAME_LIMIT (128u * 1024u * 1024u)
typedef struct {
    char magic[8];
    uint32_t header_bytes, width, height, stride;
    uint64_t payload_bytes;
    uint8_t reserved[32];
} sevo_frame_header;
typedef struct { int x, y, width, height; } sevo_rect;
typedef struct {
    char magic[8];
    uint32_t version, pid;
    volatile int64_t created_browsers, render_handlers, titles, overlay_browsers;
    volatile int64_t cpu_paints, gpu_paints, overlay_cpu_paints, overlay_gpu_paints;
    volatile int64_t replacement_paints, restored_paints, rejected_frames;
    volatile int64_t last_width, last_height, last_browser, abi_rejected, iat_hooks;
} sevo_probe_stats;
/* Validate the complete packed BGRA frame before handing it to CEF's original painter. */
const uint8_t *sevo_frame_pixels(const void *bytes, size_t length, int width, int height);
int sevo_overlay_title_prefix(const void *text, size_t length);
#endif
