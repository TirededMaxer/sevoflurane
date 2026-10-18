/* Cloud only: same callback bodies, with Microsoft x64 ABI on a Rosetta x64 fixture. */
#define SEVO_OBSERVER_TEST 1
#include <assert.h>
#include <stdlib.h>
#include "observer.c"
typedef union { uint64_t aligned; uint8_t bytes[0x120]; } fake_object;
static obs_stats storage;
static fake_object client, client2, render, display, browser1, browser2;
static uint8_t window_info[0x68], settings[0x110];
static const void *expected_url, *expected_extra, *expected_context;
static int create_result=1, sync_null;
static uint64_t calls_cpu, calls_gpu, calls_title;
static uint64_t calls_render, calls_display, calls_async, calls_sync;
static const obs_rect rectangles[2]={{1,2,3,4},{5,6,7,8}};
static const int offsets[2]={-17,83};
static void init_object(fake_object *o,size_t size) { memset(o,0,sizeof(*o));memcpy(o->bytes,&size,sizeof(size)); }
static void put(fake_object *o,size_t at,void *fn) { memcpy(o->bytes+at,&fn,sizeof(fn)); }
static int OBS_ABI get_id(void *p) { obs_set_error(88);return p==&browser1?41:42; }
static void *OBS_ABI original_render(void *p) { assert(p==&client||p==&client2);assert(obs_error()==19);calls_render++;obs_set_error(61);return &render; }
static void *OBS_ABI original_display(void *p) { assert(p==&client||p==&client2);assert(obs_error()==29);calls_display++;return &display; }
static void OBS_ABI original_paint(void *self,void *browser,int type,size_t n,const obs_rect *r,const void *pixels,int width,int height,const void *scroll,float scale) {
    assert(self==&render);assert(browser==&browser1||browser==&browser2);assert(type==0||type==1);
    assert(obs_error()==23);
    assert(n==2&&r==rectangles);assert(pixels==(const void *)(uintptr_t)0x12345678);
    assert(width==3024&&height==1964);assert(scroll==offsets);
    uint32_t float_bits;memcpy(&float_bits,&scale,sizeof(float_bits));assert(float_bits==UINT32_C(0x3fd00000));
    __atomic_add_fetch(&calls_cpu,1,__ATOMIC_RELAXED);obs_set_error(73);
}
static void OBS_ABI original_gpu(void *self,void *browser,int type,size_t n,const obs_rect *r,const void *opaque) {
    assert(self==&render&&browser==&browser2&&type==1&&n==2&&r==rectangles);
    assert(obs_error()==24);
    assert(opaque==(const void *)(uintptr_t)0x76543210);calls_gpu++;obs_set_error(74);
}
static void OBS_ABI original_title(void *self,void *browser,const obs_string *title) {
    assert(self==&display&&browser==&browser1&&title);assert(obs_error()==25);calls_title++;obs_set_error(75);
}
static void check_create(const void *info,void *c,const void *url,const void *s,void *extra,void *context) {
    assert(info==window_info&&(c==&client||c==&client2)&&url==expected_url&&s==settings);
    assert(extra==expected_extra&&context==expected_context);assert(obs_error()==19);
    assert(*(const uint32_t *)((const uint8_t *)info+0x48)==1);
    assert(*(const uint32_t *)((const uint8_t *)info+0x4c)==3);
    assert(*(const uint32_t *)((const uint8_t *)info+0x50)==7);
    obs_getter_fn render_fn=*(obs_getter_fn *)((uint8_t *)c+OBS_CLIENT_RENDER);
    assert(render_fn(c)==&render);
}
static int OBS_ABI original_create(const void *info,void *c,const void *url,const void *s,void *extra,void *context) {
    calls_async++;check_create(info,c,url,s,extra,context);obs_set_error(71);return create_result;
}
static void *OBS_ABI original_sync(const void *info,void *c,const void *url,const void *s,void *extra,void *context) {
    calls_sync++;check_create(info,c,url,s,extra,context);obs_set_error(72);return sync_null?NULL:&browser1;
}
static void reset(void) {
    memset(&storage,0,sizeof(storage));stats=&storage;memcpy(stats->magic,OBS_MAGIC,8);
    stats->schema=OBS_SCHEMA;stats->bytes=sizeof(*stats);stats->pid=99;
    init_object(&client,0xb8);init_object(&client2,0xb8);init_object(&render,0x70);init_object(&display,0x38);
    init_object(&browser1,0xe8);init_object(&browser2,0xe8);
    put(&client,OBS_CLIENT_RENDER,(void *)original_render);put(&client,OBS_CLIENT_DISPLAY,(void *)original_display);
    put(&client2,OBS_CLIENT_RENDER,(void *)original_render);put(&client2,OBS_CLIENT_DISPLAY,(void *)original_display);
    put(&render,OBS_RENDER_PAINT,(void *)original_paint);put(&render,OBS_RENDER_ACCELERATED,(void *)original_gpu);
    put(&display,OBS_DISPLAY_TITLE,(void *)original_title);put(&browser1,OBS_BROWSER_ID,(void *)get_id);put(&browser2,OBS_BROWSER_ID,(void *)get_id);
    memset(window_info,0,sizeof(window_info));uint32_t v=1;memcpy(window_info+0x48,&v,4);v=3;memcpy(window_info+0x4c,&v,4);v=7;memcpy(window_info+0x50,&v,4);
    memset(settings,0,sizeof(settings));size_t size=0x110;memcpy(settings,&size,sizeof(size));
    expected_url=(const void *)(uintptr_t)0x11111111;expected_extra=(void *)(uintptr_t)0x22222222;expected_context=(void *)(uintptr_t)0x33333333;
    create_original=original_create;create_sync_original=original_sync;calls_cpu=calls_gpu=calls_title=0;
    calls_render=calls_display=calls_async=calls_sync=0;create_result=1;sync_null=0;
}
static void call_async(int expected) {
    obs_set_error(19);assert(create_browser(window_info,&client,expected_url,settings,(void *)expected_extra,(void *)expected_context)==expected);assert(obs_error()==71);
}
static void paint(void *b) {
    obs_paint_fn fn=*(obs_paint_fn *)(render.bytes+OBS_RENDER_PAINT);
    obs_set_error(23);
    fn(&render,b,0,2,rectangles,(const void *)(uintptr_t)0x12345678,3024,1964,offsets,1.625f);assert(obs_error()==73);
}
static void *paint_thread(void *p) { for(int i=0;i<1000;i++)paint(p);return NULL; }
int main(int argc,char **argv) {
    reset();call_async(1);create_result=0;call_async(0);create_result=-7;call_async(-7);
    assert(stats->counters[C_CREATE_CALLS]==3&&stats->counters[C_ASYNC_ACCEPTED]==2&&stats->counters[C_ASYNC_REJECTED]==1);
    assert(stats->creates[0].windowless==1&&stats->creates[0].shared_texture==3&&stats->creates[0].external_begin_frame==7);
    assert(stats->creates[2].result==(uint64_t)(int64_t)-7&&stats->creates[2].result_known==1);
    assert(stats->counters[C_RENDER_GETTERS]==3&&stats->counters[C_UNIQUE_HANDLERS]==1);
    obs_getter_fn gf=*(obs_getter_fn *)(client.bytes+OBS_CLIENT_RENDER);obs_set_error(19);assert(gf(&client)==&render&&obs_error()==61);
    assert(stats->counters[C_UNIQUE_HANDLERS]==1&&stats->counters[C_SLOT_ALREADY]>0);
    assert(stats->slots[0].module>0&&stats->slots[0].rva<4096&&stats->module_count>0);
    obs_set_error(19);assert(create_browser_sync(window_info,&client2,expected_url,settings,(void *)expected_extra,(void *)expected_context)==&browser1);assert(obs_error()==72);
    sync_null=1;obs_set_error(19);assert(!create_browser_sync(window_info,&client2,expected_url,settings,(void *)expected_extra,(void *)expected_context));
    assert(stats->counters[C_SYNC_NONNULL]==1&&stats->counters[C_SYNC_NULL]==1&&stats->creates[3].cef_id==41);
    assert(calls_async==3&&calls_sync==2&&calls_render==6);
    obs_getter_fn df=*(obs_getter_fn *)(client.bytes+OBS_CLIENT_DISPLAY);obs_set_error(29);assert(df(&client)==&display&&calls_display==1&&obs_error()==29);
    obs_title_fn tf=*(obs_title_fn *)(display.bytes+OBS_DISPLAY_TITLE);
    const char text[]="SP Overlay: 1692/262146/0";obs_string title={text,sizeof(text)-1,NULL};obs_set_error(25);tf(&display,&browser1,&title);assert(obs_error()==75);
    const char other[]="private non-overlay title";title.text=other;title.length=sizeof(other)-1;obs_set_error(25);tf(&display,&browser1,&title);assert(obs_error()==75);
    assert(calls_title==2);assert(stats->browsers[0].cef_id==41&&stats->browsers[0].game_pid==1692&&stats->browsers[0].steam_browser_id==262146);
    assert(stats->browsers[0].overlay_match==1); /* CEF local ID is not the Steam ID. */
    uint64_t identity[3];const uint16_t wide[]={'S','P',' ','O','v','e','r','l','a','y',':',' ','1','/','2','/','3'};
    title=(obs_string){wide,sizeof(wide)/2,NULL};assert(overlay_identity(&title,identity)&&identity[2]==3);
    const char too_big[]="SP Overlay: 4294967296/2/3";title=(obs_string){too_big,sizeof(too_big)-1,NULL};assert(!overlay_identity(&title,identity));
    title=(obs_string){text,12,NULL};assert(!overlay_identity(&title,identity));
    paint(&browser1);paint(&browser2);
    obs_gpu_fn gpu=*(obs_gpu_fn *)(render.bytes+OBS_RENDER_ACCELERATED);
    obs_set_error(24);
    gpu(&render,&browser2,1,2,rectangles,(const void *)(uintptr_t)0x76543210);assert(obs_error()==74&&calls_gpu==1);
    assert(stats->browser_count==2&&stats->browsers[1].gpu_entries==1&&stats->browsers[1].last_width==3024);
    pthread_t threads[4];for(int i=0;i<4;i++)assert(!pthread_create(&threads[i],NULL,paint_thread,i%2?&browser1:&browser2));
    for(int i=0;i<4;i++)assert(!pthread_join(threads[i],NULL));
    assert(stats->counters[C_CPU_ENTRIES]==4002&&calls_cpu==4002&&!(stats->sequence&1));
    fake_object null_handler;init_object(&null_handler,0x70);patch_slot(&null_handler,OBS_RENDER_PAINT,(void *)on_paint);
    fake_object too_short;init_object(&too_short,0x28);patch_slot(&too_short,OBS_RENDER_PAINT,(void *)on_paint);
    assert(stats->counters[C_SLOT_NULL]==1&&stats->counters[C_SLOT_REJECTED]==1);
    on_paint(&null_handler,&browser1,0,0,NULL,NULL,0,0,NULL,0);on_gpu(&null_handler,&browser1,0,0,NULL,NULL);
    assert(stats->counters[C_MISSING_ORIGINAL]==2&&stats->counters[C_CPU_ENTRIES]==4003&&stats->counters[C_GPU_ENTRIES]==2);
    assert(calls_cpu==4002&&calls_gpu==1&&calls_title==2); /* Exactly once for every mapped original. */
    assert(stats->counters[C_UNIQUE_HANDLERS]==2); /* One render + one display, shared across clients. */
    if(argc==2){FILE *out=fopen(argv[1],"wb");assert(out&&fwrite(stats,1,sizeof(*stats),out)==sizeof(*stats));assert(!fclose(out));}
    puts("PASS: Microsoft x64 six-argument create/results; ten-argument paint/float; opaque GPU forwarding; identity, slots and concurrent counters");return 0;
}
