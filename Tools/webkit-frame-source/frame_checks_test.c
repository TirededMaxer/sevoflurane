#include "frame_checks.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void fill(uint8_t *p,FCGeometry g,int x,int y,int w,int h,int r,int green,int b,int a) {
    size_t left=(size_t)(x*g.width/g.css_width),top=(size_t)(y*g.height/g.css_height);
    size_t right=(size_t)((x+w)*g.width/g.css_width),bottom=(size_t)((y+h)*g.height/g.css_height);
    for (size_t row=top;row<bottom;row++) for (size_t col=left;col<right;col++) {
        uint8_t *v=p+row*g.row_bytes+col*4;v[0]=(uint8_t)b;v[1]=(uint8_t)green;v[2]=(uint8_t)r;v[3]=(uint8_t)a;
    }
}
static void generation(uint8_t *p,FCGeometry g,int corner,uint16_t n) {
    int x=(corner&1) ? (int)g.css_width-184 : 56;
    int y=(corner&2) ? (int)g.css_height-28 : 20;
    for (int bit=0;bit<16;bit++) {
        int v=(n&(1u<<bit)) ? 255 : 16;fill(p,g,x+bit*8,y,8,8,v,v,v,255);
    }
}
static uint8_t *make_frame(FCGeometry g) {
    uint8_t *p=calloc(g.height,g.row_bytes);assert(p);
    const int colors[4][3]={{230,50,60},{20,210,80},{30,90,240},{240,190,20}};
    for (int i=0;i<4;i++) {
        int x=(i&1) ? (int)g.css_width-40 : 16,y=(i&2) ? (int)g.css_height-40 : 16;
        fill(p,g,x,y,24,24,colors[i][0],colors[i][1],colors[i][2],255);generation(p,g,i,1234);
    }
    fill(p,g,32,80,128,80,190,30,200,255);
    fill(p,g,(int)g.css_width-160,80,128,80,0,204,204,255);
    fill(p,g,(int)g.css_width/2-64,(int)g.css_height-122,128,80,255,120,20,255);
    return p;
}
static void cases(int scale) {
    FCGeometry padded={768u*(size_t)scale,480u*(size_t)scale,768u*4u*(size_t)scale+64,768,480};
    FCGeometry packed=padded;packed.row_bytes=packed.width*4;
    uint8_t *source=make_frame(padded),*copy=malloc(packed.height*packed.row_bytes);
    assert(copy && fc_geometry_valid(padded));
    assert(fc_orientation(source,padded)==0);
    assert(fc_copy_rows(copy,packed.height*packed.row_bytes,source,padded,false));
    FCResult r=fc_check(copy,packed);assert(fc_content_pass(r) && r.generation==1234);
    uint64_t before=r.regions[2];fill(copy,packed,56,110,16,20,255,255,255,255);
    assert(fc_check(copy,packed).regions[2]!=before);
    generation(source,padded,3,1235);
    r=fc_check(source,padded);assert(r.generation_valid && !r.generation_equal && !fc_content_pass(r));
    generation(source,padded,3,1234);
    fill(source,padded,56,20,8,8,100,100,100,255);
    assert(!fc_check(source,padded).generation_valid);generation(source,padded,0,1234);
    fill(source,padded,(int)padded.css_width/2-64,(int)padded.css_height-122,128,80,0,0,0,255);
    r=fc_check(source,padded);assert(r.canvas && r.webgl && !r.video && !fc_content_pass(r));
    fill(source,padded,0,0,8,8,0,0,0,255);assert(!fc_check(source,padded).transparent_edges);
    free(source);source=make_frame(padded);
    fill(source,padded,32,80,128,80,0,0,0,255);assert(!fc_check(source,padded).canvas);
    free(source);source=make_frame(padded);
    fill(source,padded,(int)padded.css_width-160,80,128,80,0,0,0,255);assert(!fc_check(source,padded).webgl);
    free(source);source=make_frame(padded);
    for (int i=0;i<4;i++) generation(source,padded,i,0);
    assert(!fc_check(source,padded).generation_valid);
    free(source);source=make_frame(padded);
    uint8_t *flipped=malloc(padded.height*padded.row_bytes);assert(flipped);
    for (size_t y=0;y<padded.height;y++) memcpy(flipped+y*padded.row_bytes,source+(padded.height-y-1)*padded.row_bytes,padded.row_bytes);
    assert(fc_orientation(flipped,padded)==1);
    assert(fc_copy_rows(copy,packed.height*packed.row_bytes,flipped,padded,true));
    assert(fc_content_pass(fc_check(copy,packed)));
    assert(!fc_copy_rows(copy,packed.height*packed.row_bytes-1,source,padded,false));
    free(flipped);free(source);free(copy);
}
int main(void) {
    cases(1);cases(2);
    assert(!fc_geometry_valid((FCGeometry){SIZE_MAX,480,SIZE_MAX,768,480}));
    assert(!fc_geometry_valid((FCGeometry){768,480,768*4,NAN,480}));
    assert(!fc_content_pass((FCResult){0}));
    double values[]={4,1,3,2};assert(fc_percentile(values,4,.95)==4 && fc_percentile(values,4,0)==1);
    assert(isnan(fc_percentile(values,0,.5)));
    puts("PASS: actual BGRA checker, scale 1/2, padded rows, orientation normalization, generation tearing, video omission, alpha, motion hashes and bounds");
    return 0;
}
