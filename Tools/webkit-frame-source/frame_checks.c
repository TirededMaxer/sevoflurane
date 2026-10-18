#include "frame_checks.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

bool fc_geometry_valid(FCGeometry g) {
    return g.width >= 640 && g.height >= 400 && g.width <= 8192 &&
        g.height <= 8192 && isfinite(g.css_width) && isfinite(g.css_height) &&
        g.css_width >= 640 && g.css_height >= 400 &&
        g.width <= SIZE_MAX / 4 && g.row_bytes >= g.width * 4 &&
        g.height <= SIZE_MAX / g.row_bytes;
}
bool fc_copy_rows(uint8_t *dst, size_t capacity, const uint8_t *src,
                  FCGeometry g, bool flip_y) {
    if (!dst || !src || !fc_geometry_valid(g) ||
        g.height > SIZE_MAX / (g.width * 4) || capacity < g.width * g.height * 4)
        return false;
    for (size_t y = 0; y < g.height; ++y)
        memcpy(dst + y * g.width * 4,
               src + (flip_y ? g.height - y - 1 : y) * g.row_bytes, g.width * 4);
    return true;
}
static const uint8_t *pixel(const uint8_t *p, FCGeometry g, double x, double y) {
    size_t px = (size_t)floor(x * g.width / g.css_width);
    size_t py = (size_t)floor(y * g.height / g.css_height);
    if (px >= g.width) px = g.width - 1;
    if (py >= g.height) py = g.height - 1;
    return p + py * g.row_bytes + px * 4;
}
static bool rgb(const uint8_t *p, int r, int g, int b) {
    return abs(p[2] - r) <= 22 && abs(p[1] - g) <= 22 &&
        abs(p[0] - b) <= 22 && p[3] >= 240;
}
static bool corners(const uint8_t *p, FCGeometry g, bool flip) {
    const int colors[4][3] = {{230,50,60},{20,210,80},{30,90,240},{240,190,20}};
    for (int i = 0; i < 4; ++i) {
        double x = (i & 1) ? g.css_width - 28 : 28;
        double y = (i & 2) ? g.css_height - 28 : 28;
        if (flip) y = g.css_height - y;
        if (!rgb(pixel(p,g,x,y),colors[i][0],colors[i][1],colors[i][2])) return false;
    }
    return true;
}
int fc_orientation(const uint8_t *p, FCGeometry g) {
    if (!p || !fc_geometry_valid(g)) return -1;
    if (corners(p,g,false)) return 0;
    return corners(p,g,true) ? 1 : -1;
}
static uint64_t region_hash(const uint8_t *p, FCGeometry g,
                             double x, double y, double w, double h) {
    uint64_t hash = UINT64_C(1469598103934665603);
    for (int j = 0; j < 8; ++j) for (int i = 0; i < 16; ++i) {
        const uint8_t *v = pixel(p,g,x+(i+.5)*w/16,y+(j+.5)*h/8);
        for (int c = 0; c < 4; ++c) hash = (hash ^ v[c]) * UINT64_C(1099511628211);
    }
    return hash;
}
FCResult fc_check(const uint8_t *p, FCGeometry g) {
    FCResult r = {0};
    if (!p || !fc_geometry_valid(g)) return r;
    r.corners = corners(p,g,false);
    r.transparent_edges = true;
    for (int i = 0; i < 4; ++i) {
        double x = (i & 1) ? g.css_width - 28 : 28;
        double y = (i & 2) ? g.css_height - 28 : 28;
        memcpy(&r.corner_bgra[i],pixel(p,g,x,y),4);
        x = (i & 1) ? g.css_width - 2 : 2;
        y = (i & 2) ? g.css_height - 2 : 2;
        if (pixel(p,g,x,y)[3] > 5) r.transparent_edges = false;
    }
    r.generation_valid = r.generation_equal = true;
    for (int corner = 0; corner < 4; ++corner) {
        uint16_t n = 0;
        double x = (corner & 1) ? g.css_width - 184 : 56;
        double y = (corner & 2) ? g.css_height - 28 : 20;
        for (int bit = 0; bit < 16; ++bit) {
            const uint8_t *v = pixel(p,g,x+bit*8+4,y+4);
            bool white = v[0]>200 && v[1]>200 && v[2]>200 && v[3]>240;
            bool black = v[0]<60 && v[1]<60 && v[2]<60 && v[3]>240;
            if (!white && !black) r.generation_valid = false;
            if (white) n |= (uint16_t)(1u << bit);
        }
        if (!corner) r.generation = n;
        else if (n != r.generation) r.generation_equal = false;
    }
    if (!r.generation) r.generation_valid = false;
    r.canvas = rgb(pixel(p,g,40,88),190,30,200);
    r.webgl = rgb(pixel(p,g,g.css_width-152,88),0,204,204);
    r.video = rgb(pixel(p,g,g.css_width/2-58,g.css_height-116),255,120,20);
    r.regions[0] = region_hash(p,g,g.css_width/2-70,80,140,80); // CSS motion
    r.regions[1] = region_hash(p,g,32,190,140,96); // scrolling content
    r.regions[2] = region_hash(p,g,32,80,128,80); // Canvas 2D
    r.regions[3] = region_hash(p,g,g.css_width-160,80,128,80); // WebGL
    r.regions[4] = region_hash(p,g,g.css_width/2-64,g.css_height-122,128,80); // video
    return r;
}
bool fc_content_pass(FCResult r) {
    return r.corners && r.transparent_edges && r.generation_valid &&
        r.generation_equal && r.canvas && r.webgl && r.video;
}
static int compare(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
double fc_percentile(const double *v, size_t n, double f) {
    if (!v || !n || !isfinite(f) || f < 0 || f > 1) return NAN;
    double *copy = malloc(n*sizeof(*copy));
    if (!copy) return NAN;
    memcpy(copy,v,n*sizeof(*copy)); qsort(copy,n,sizeof(*copy),compare);
    double result = copy[(size_t)ceil(f*(n-1))]; free(copy); return result;
}
