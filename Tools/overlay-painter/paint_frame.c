#include "paint_frame.h"
#include <string.h>
_Static_assert(sizeof(sevo_frame_header) == 64, "Frame header ABI");
const uint8_t *sevo_frame_pixels(const void *bytes, size_t length, int width, int height) {
    if (!bytes || length < sizeof(sevo_frame_header) || width < 1 || height < 1) return NULL;
    sevo_frame_header h;
    memcpy(&h, bytes, sizeof(h));
    if (memcmp(h.magic, SEVO_FRAME_MAGIC, 8) || h.header_bytes != sizeof(h)) return NULL;
    if (h.width != (uint32_t)width || h.height != (uint32_t)height || h.width > SEVO_FRAME_LIMIT / 4) return NULL;
    if (h.stride != h.width * 4) return NULL;
    uint64_t expected = (uint64_t)h.stride * h.height;
    if (expected > SEVO_FRAME_LIMIT || h.payload_bytes != expected || length != sizeof(h) + expected) return NULL;
    return (const uint8_t *)bytes + sizeof(h);
}

/* Steam has shipped both its short overlay title and the PID/browser suffix. */
int sevo_overlay_title_prefix(const void *text, size_t length) {
    static const unsigned char prefix[] = "SP Overlay";
    if (!text || length < sizeof(prefix) - 1) return 0;
    const unsigned char *p = text;
    if (p[0] == 'S' && p[1] == 0) {
        for (size_t i = 0; i < sizeof(prefix) - 1; i++)
            if (p[i * 2] != prefix[i] || p[i * 2 + 1] != 0) return 0;
        return length == sizeof(prefix) - 1 || (p[20] == ':' && p[21] == 0);
    }
    return !memcmp(p, prefix, sizeof(prefix) - 1) && (length == sizeof(prefix) - 1 || p[10] == ':');
}
