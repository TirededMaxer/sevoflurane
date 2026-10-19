#define SEVO_OBSERVER_TEST 1
#include <assert.h>
#include "paint.c"
static void *table[11],*browser[1],*reference[1];
static int enabled,restore_view;
static uint64_t calls;
static int original_pixels,replacement_pixels,original_dirty;
static int CPP_ABI identifier(void *self) { assert(self==browser);return 4; }
static int cpp_test_readable(const void *p,size_t n) {
    const void *regions[]={table,browser,reference};size_t sizes[]={sizeof(table),sizeof(browser),sizeof(reference)};
    for(int i=0;i<3;i++)if((uintptr_t)p>=(uintptr_t)regions[i]&&
       (uintptr_t)p-(uintptr_t)regions[i]<=sizes[i]&&n<=sizes[i]-((uintptr_t)p-(uintptr_t)regions[i]))return 1;
    return 0;
}
static int cpp_test_executable(void *p) { return p==(void *)identifier; }
static const void *cpp_test_frame(uint32_t id,int width,int height,int *restore) {
    assert(id==4&&width==1512&&height==982);*restore=restore_view;
    return enabled?&replacement_pixels:NULL;
}
static void CPP_ABI original(void *self,void *ref,int type,const void *dirty,const void *pixels,
                            int width,int height,const void *scroll,float scale) {
    assert(self==(void *)0x1111&&ref==reference&&type==0&&width==1512&&height==982);
    assert(scroll==(void *)0x2222&&scale==1.625f&&cpp_error()==23);
    assert(pixels==(enabled?&replacement_pixels:&original_pixels));
    if(enabled||restore_view){const int *const *v=dirty;
        assert(v[1]-v[0]==4&&v[0][0]==0&&v[0][1]==0&&v[0][2]==width&&v[0][3]==height);
    }else assert(dirty==&original_dirty);
    __atomic_add_fetch(&calls,1,__ATOMIC_RELAXED);cpp_set_error(73);
}
static void call(void) {
    cpp_set_error(23);cpp_on_cpu((void *)0x1111,reference,0,&original_dirty,&original_pixels,1512,982,(void *)0x2222,1.625f);
    assert(cpp_error()==73);
}
static void *worker(void *unused) { (void)unused;for(int i=0;i<1000;i++)call();return NULL; }
int main(void) {
    table[10]=(void *)identifier;browser[0]=table;reference[0]=browser;cpp_cpu_original=original;
    uint32_t id=0;assert(cpp_cef_id(reference,&id)&&id==4);assert(!cpp_cef_id((void *)1,&id));
    pthread_t threads[4];for(int i=0;i<4;i++)assert(!pthread_create(&threads[i],NULL,worker,NULL));
    for(int i=0;i<4;i++)assert(!pthread_join(threads[i],NULL));assert(calls==4000);
    enabled=1;call();enabled=0;restore_view=1;call();restore_view=0;call();assert(calls==4003);
    puts("PASS: original 9-argument Microsoft x64 paint ABI, CEF identity, float, exact forwarding, concurrent calls, full-frame replacement and restoration");
    return 0;
}
