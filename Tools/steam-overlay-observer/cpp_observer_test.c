/* Cloud only. The exact production callback bodies use Microsoft x64 ABI. */
#define SEVO_OBSERVER_TEST 1
#include <assert.h>
#include <stdlib.h>
#include "cpp_observer.c"
typedef union { uint64_t align;uint8_t bytes[0x18]; } fake_painter;
typedef union { uint64_t align;uint8_t bytes[0x330]; } fake_owner;
static cpp_stats storage;
static fake_painter painter,unreadable_owner,overflow;
static fake_owner owner;
static void *slots[2];
static uint64_t cpu_calls,gpu_calls;
static void *cpu_browser=(void *)(uintptr_t)0x11111111;
static void *cef_vtable[11],*cef_browser[1],*cef_ref[1];
static int CPP_ABI cef_identifier(void *self) { assert(self==cef_browser);return 4; }
static int cpp_test_executable(void *address) { return address==(void *)cef_identifier; }
static int cpp_test_readable(const void *p,size_t n) {
    /* Metadata reads affect LastError, so forwarding must restore the caller's value. */
    cpp_set_error(99);
    const void *regions[]={&painter,&unreadable_owner,&overflow,&owner,slots,cef_vtable,cef_browser,cef_ref};
    const size_t lengths[]={sizeof(painter),sizeof(unreadable_owner),sizeof(overflow),sizeof(owner),sizeof(slots),sizeof(cef_vtable),sizeof(cef_browser),sizeof(cef_ref)};
    uintptr_t at=(uintptr_t)p;
    for(size_t i=0;i<sizeof(regions)/sizeof(regions[0]);i++){
        uintptr_t start=(uintptr_t)regions[i];
        if(at>=start&&at-start<=lengths[i]&&n<=lengths[i]-(at-start))return 1;
    }
    return 0;
}
static void CPP_ABI original_cpu(void *self,void *browser,int type,const void *dirty,const void *pixels,
                                  int width,int height,const void *scroll,float scale) {
    assert(self==&painter||self==&unreadable_owner||self==&overflow);
    assert(browser==cpu_browser&&type==0);
    assert(dirty==(const void *)(uintptr_t)0x22222222&&pixels==(const void *)(uintptr_t)0x33333333);
    assert(width==3024&&height==1964&&scroll==(const void *)(uintptr_t)0x44444444);
    uint32_t bits=0;memcpy(&bits,&scale,sizeof(bits));assert(bits==UINT32_C(0x3fd00000));
    assert(cpp_error()==23);__atomic_add_fetch(&cpu_calls,1,__ATOMIC_RELAXED);cpp_set_error(73);
}
static void CPP_ABI original_gpu(void *self,void *browser,int type,const void *dirty,const void *opaque) {
    assert(self==&painter||self==&unreadable_owner);
    assert(browser==(void *)(uintptr_t)0x55555555&&type==1);
    assert(dirty==(const void *)(uintptr_t)0x66666666&&opaque==(const void *)(uintptr_t)0x77777777);
    assert(cpp_error()==24);__atomic_add_fetch(&gpu_calls,1,__ATOMIC_RELAXED);cpp_set_error(74);
}
static void call_cpu(void *self) {
    cpp_cpu_fn fn=(cpp_cpu_fn)__atomic_load_n(&slots[0],__ATOMIC_ACQUIRE);cpp_set_error(23);
    fn(self,cpu_browser,0,(const void *)(uintptr_t)0x22222222,
       (const void *)(uintptr_t)0x33333333,3024,1964,(const void *)(uintptr_t)0x44444444,1.625f);
    assert(cpp_error()==73);
}
static void call_gpu(void *self) {
    cpp_gpu_fn fn=(cpp_gpu_fn)__atomic_load_n(&slots[1],__ATOMIC_ACQUIRE);cpp_set_error(24);
    fn(self,(void *)(uintptr_t)0x55555555,1,(const void *)(uintptr_t)0x66666666,(const void *)(uintptr_t)0x77777777);
    assert(cpp_error()==74);
}
static void *worker(void *unused) {
    (void)unused;for(int i=0;i<1000;i++){call_cpu(&painter);call_gpu(&painter);}return NULL;
}
static int frame_restore_expected;
static void CPP_ABI frame_original(void *self,void *browser,int type,const void *dirty,const void *pixels,
                                   int width,int height,const void *scroll,float scale) {
    assert(self==&painter&&browser==cpu_browser&&type==0);
    assert(pixels==(frame_restore_expected?(void *)(uintptr_t)0x33333333:cpp_frame_pixels)&&width==3024&&height==1964&&scroll==(void *)(uintptr_t)0x44444444&&scale==1.625f);
    const int *const *v=dirty;assert(v[1]-v[0]==4&&v[2]==v[1]);
    assert(v[0][0]==0&&v[0][1]==0&&v[0][2]==width&&v[0][3]==height&&cpp_error()==23);
    cpp_set_error(73);
}
int main(int argc,char **argv) {
    cpp_data=&storage;memcpy(cpp_data->magic,CPP_MAGIC,8);cpp_data->schema=CPP_SCHEMA;
    cpp_data->bytes=sizeof(*cpp_data);cpp_data->pid=99;
    uintptr_t address=(uintptr_t)&owner;uint32_t native_id=262146;
    memcpy(painter.bytes+0x10,&address,sizeof(address));memcpy(overflow.bytes+0x10,&address,sizeof(address));
    memcpy(owner.bytes+0x328,&native_id,sizeof(native_id));
    address=1;memcpy(unreadable_owner.bytes+0x10,&address,sizeof(address));
    uint32_t id=0;assert(cpp_native_id(&painter,&id)&&id==262146);
    assert(!cpp_native_id(NULL,&id)&&!cpp_native_id((void *)(uintptr_t)1,&id));
    assert(!cpp_native_id((void *)(UINTPTR_MAX-1),&id)&&!cpp_native_id(&unreadable_owner,&id));
    slots[0]=(void *)original_cpu;slots[1]=(void *)original_gpu;
    assert(!cpp_install(slots,slots+1,(void *)original_gpu,(void *)original_gpu));
    assert(slots[0]==(void *)original_cpu&&slots[1]==(void *)original_gpu);
    assert(cpp_install(slots,slots+1,(void *)original_cpu,(void *)original_gpu)==1);
    assert(cpp_install(slots,slots+1,(void *)original_cpu,(void *)original_gpu)==1);
    assert(cpp_data->counters[CPP_SLOT_INSTALLED]==2&&cpp_data->counters[CPP_SLOT_ALREADY]==2);
    /* A foreign replacement must never be adopted as an original or overwritten. */
    __atomic_store_n(&slots[1],(void *)original_cpu,__ATOMIC_RELEASE);
    assert(!cpp_install(slots,slots+1,(void *)original_cpu,(void *)original_gpu));
    assert(slots[1]==(void *)original_cpu&&cpp_gpu_original==original_gpu);
    __atomic_store_n(&slots[1],(void *)cpp_on_gpu,__ATOMIC_RELEASE);
    call_cpu(&painter);call_gpu(&painter);
    pthread_t threads[4];
    for(int i=0;i<4;i++)assert(!pthread_create(&threads[i],NULL,worker,NULL));
    for(int i=0;i<4;i++)assert(!pthread_join(threads[i],NULL));
    call_cpu(&unreadable_owner);call_gpu(&unreadable_owner);
    assert(cpu_calls==4002&&gpu_calls==4002&&!(cpp_data->sequence&1));
    assert(cpp_data->painter_count==2&&cpp_data->painters[0].native_browser_id==262146);
    assert(cpp_data->painters[0].cpu_entries==4001&&cpp_data->painters[0].gpu_entries==4001);
    assert(cpp_data->painters[0].view_entries==4001&&cpp_data->painters[0].popup_entries==4001);
    assert(cpp_data->painters[0].last_width==3024&&cpp_data->painters[0].last_height==1964);
    assert(cpp_data->painters[1].identity_valid==0&&cpp_data->counters[CPP_NATIVE_ID_UNREADABLE]==2);
    /* Exhausted metadata storage still calls the original once. */
    cpp_data->painter_count=CPP_PAINTER_LIMIT;call_cpu(&overflow);cpp_data->painter_count=2;
    assert(cpp_data->counters[CPP_RECORDS_DROPPED]==1&&cpu_calls==4003);
    assert(cpp_data->counters[CPP_CPU_ENTRIES]==cpu_calls&&cpp_data->counters[CPP_GPU_ENTRIES]==gpu_calls);
    assert(cpp_data->counters[CPP_MISSING_ORIGINAL]==0);
    cpp_data->ready=1;
    if(argc==2){FILE *out=fopen(argv[1],"wb");assert(out&&fwrite(cpp_data,1,sizeof(*cpp_data),out)==sizeof(*cpp_data));assert(!fclose(out));}
    /* The exact callback substitutes only the selected full view, then forwards once. */
    cef_vtable[10]=(void *)cef_identifier;cef_browser[0]=cef_vtable;cef_ref[0]=cef_browser;
    uint32_t cef_id=0;assert(cpp_cef_id(cef_ref,&cef_id)&&cef_id==4);
    assert(!cpp_cef_id((void *)(uintptr_t)1,&cef_id));cpu_browser=cef_ref;
    cpp_frame_header packet={{'S','E','V','O','F','R','M','1'},3024,1964,4,3024u*1964u*4u};
    assert(cpp_frame_valid(packet));packet.target=0;assert(!cpp_frame_valid(packet));packet.target=4;
    cpp_frame_stats proof={0};cpp_frame=packet;cpp_frame_counts=&proof;cpp_frame_pixels=(void *)(uintptr_t)0x12345678;
    assert(!cpp_frame_use(((uint64_t)1<<32)|5,0,3024,1964));
    assert(!cpp_frame_use(((uint64_t)1<<32)|4,1,3024,1964));
    assert(!cpp_frame_use(4,0,3024,1964));
    assert(!cpp_frame_use(((uint64_t)1<<32)|4,0,1,1964)&&proof.dimensions_rejected==1);
    cpp_cpu_original=frame_original;call_cpu(&painter);assert(proof.applied==1);
    cpp_frame_started=cpp_tick()-15001;
    frame_restore_expected=1;call_cpu(&painter);assert(proof.restored==1&&proof.applied==1);
    assert(!cpp_frame_use(((uint64_t)1<<32)|4,0,3024,1964));
    puts("PASS: same-source Microsoft x64 C++ 9-argument CPU/float and 5-argument GPU opaque forwarding; once, LastError, strict slots, native identity, concurrency, scoped frame substitution and expiry");
    return 0;
}
