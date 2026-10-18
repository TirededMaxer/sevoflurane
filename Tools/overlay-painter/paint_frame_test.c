#include "paint_frame.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
    uint8_t storage[64 + 16] = {0};
    sevo_frame_header *h = (sevo_frame_header *)storage;
    memcpy(h->magic, SEVO_FRAME_MAGIC, 8);
    h->header_bytes = 64; h->width = 2; h->height = 2; h->stride = 8; h->payload_bytes = 16;
    assert(sevo_frame_pixels(storage, sizeof(storage), 2, 2) == storage + 64);
    assert(!sevo_frame_pixels(storage, sizeof(storage)-1, 2, 2));
    assert(!sevo_frame_pixels(storage, sizeof(storage), 4, 1));
    h->stride = 4; assert(!sevo_frame_pixels(storage, sizeof(storage), 2, 2)); h->stride = 8;
    h->payload_bytes = UINT64_MAX; assert(!sevo_frame_pixels(storage, sizeof(storage), 2, 2)); h->payload_bytes = 16;
    h->width = UINT32_MAX; assert(!sevo_frame_pixels(storage, sizeof(storage), 2, 2)); h->width = 2;
    h->header_bytes = 0; assert(!sevo_frame_pixels(storage, sizeof(storage), 2, 2)); h->header_bytes = 64;
    assert(!sevo_frame_pixels(NULL, 0, 2, 2));
    if (argc == 2) {
        FILE *f = fopen(argv[1], "rb"); assert(f); assert(!fseek(f, 0, SEEK_END));
        long size = ftell(f); assert(size > 64); rewind(f);
        uint8_t *b = malloc((size_t)size); assert(b); assert(fread(b, 1, (size_t)size, f) == (size_t)size); fclose(f);
        const uint8_t *pixels = sevo_frame_pixels(b, (size_t)size, 640, 400); assert(pixels);
        /* WebKit's deterministic opaque #123456 background, in premultiplied BGRA. */
        assert(pixels[0] == 0x56 && pixels[1] == 0x34 && pixels[2] == 0x12 && pixels[3] == 0xff);
        free(b);
    }
    puts("paint frame validation passed");
}
