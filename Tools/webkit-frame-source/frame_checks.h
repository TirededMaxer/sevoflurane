#ifndef FRAME_CHECKS_H
#define FRAME_CHECKS_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum { FC_REGION_COUNT = 5 };
typedef struct {
    size_t width, height, row_bytes;
    double css_width, css_height;
} FCGeometry;
typedef struct {
    bool corners, transparent_edges, generation_valid, generation_equal;
    bool canvas, webgl, video;
    uint16_t generation;
    uint32_t corner_bgra[4];
    uint64_t regions[FC_REGION_COUNT];
} FCResult;

bool fc_geometry_valid(FCGeometry g);
/* A separate copy owns every byte read by validation. Source may be padded. */
bool fc_copy_rows(uint8_t *dst, size_t capacity, const uint8_t *src,
                  FCGeometry source, bool flip_y);
/* 0 = top-down, 1 = bottom-up, -1 = pattern absent/incomplete. */
int fc_orientation(const uint8_t *pixels, FCGeometry g);
FCResult fc_check(const uint8_t *pixels, FCGeometry g);
bool fc_content_pass(FCResult r);
double fc_percentile(const double *values, size_t count, double fraction);
#endif
