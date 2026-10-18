/* Exact-build CChromePainter observer with an opt-in, expiring single-frame proof. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include "cpp_observer.h"
#ifdef SEVO_OBSERVER_TEST
#include <pthread.h>
#include <time.h>
static pthread_mutex_t cpp_mutex=PTHREAD_MUTEX_INITIALIZER;
static _Thread_local unsigned long cpp_test_last_error;
static int cpp_test_readable(const void *,size_t);
static int cpp_test_executable(void *);
static void cpp_lock(void) { pthread_mutex_lock(&cpp_mutex); }
static void cpp_unlock(void) { pthread_mutex_unlock(&cpp_mutex); }
static unsigned long cpp_error(void) { return cpp_test_last_error; }
static void cpp_set_error(unsigned long value) { cpp_test_last_error=value; }
static int cpp_readable(const void *p,size_t n) { return cpp_test_readable(p,n); }
static uint64_t cpp_tick(void) { struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (uint64_t)t.tv_sec*1000+(uint64_t)t.tv_nsec/1000000; }
#else
#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif
#include <windows.h>
#include <bcrypt.h>
static SRWLOCK cpp_mutex=SRWLOCK_INIT;
static void cpp_lock(void) { AcquireSRWLockExclusive(&cpp_mutex); }
static void cpp_unlock(void) { ReleaseSRWLockExclusive(&cpp_mutex); }
static unsigned long cpp_error(void) { return GetLastError(); }
static void cpp_set_error(unsigned long value) { SetLastError(value); }
static int cpp_readable(const void *p,size_t n) {
    MEMORY_BASIC_INFORMATION m;uintptr_t at=(uintptr_t)p;
    if(!p||!VirtualQuery(p,&m,sizeof(m))||m.State!=MEM_COMMIT||
       (m.Protect&(PAGE_GUARD|PAGE_NOACCESS)))return 0;
    /* Fail closed on execute-only pages and on ranges crossing a region. */
    if(!(m.Protect&(PAGE_READONLY|PAGE_READWRITE|PAGE_WRITECOPY|
                   PAGE_EXECUTE_READ|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY)))return 0;
    uintptr_t start=(uintptr_t)m.BaseAddress;
    return at>=start&&at-start<=m.RegionSize&&n<=m.RegionSize-(at-start);
}
static uint64_t cpp_tick(void) { return GetTickCount64(); }
#endif
#ifndef SEVO_OBSERVER_TEST
static int cpp_executable(void *);
#endif
static cpp_stats *cpp_data;
static cpp_cpu_fn cpp_cpu_original;
static cpp_gpu_fn cpp_gpu_original;
/* Opt-in single-frame proof. All bytes are loaded before installing callbacks. */
typedef struct { char magic[8];uint32_t width,height,target,bytes; } cpp_frame_header;
typedef struct { char magic[8];uint64_t target,width,height,applied,dimensions_rejected,restored; } cpp_frame_stats;
_Static_assert(sizeof(cpp_frame_header)==24,"Frame packet ABI changed");
_Static_assert(sizeof(cpp_frame_stats)==56,"Frame proof stats ABI changed");
static cpp_frame_header cpp_frame;
static cpp_frame_stats *cpp_frame_counts;
static const void *cpp_frame_pixels;
static uint64_t cpp_frame_started,cpp_frame_restored;
static int cpp_frame_valid(cpp_frame_header h) {
    return !memcmp(h.magic,"SEVOFRM1",8)&&h.width>=64&&h.height>=64&&h.width<=8192&&h.height<=8192&&
        h.target && (uint64_t)h.width*h.height*4==h.bytes && h.bytes<=128u*1024u*1024u;
}
static int cpp_frame_use(uint64_t identity,int type,int width,int height) {
    if(!cpp_frame_pixels||!cpp_frame_counts||!(identity>>32)||type!=0||(uint32_t)identity!=cpp_frame.target)return 0;
    if(width!=(int)cpp_frame.width||height!=(int)cpp_frame.height){
        __atomic_add_fetch(&cpp_frame_counts->dimensions_rejected,1,__ATOMIC_RELAXED);return 0;
    }
    uint64_t now=cpp_tick(),expected=0;
    __atomic_compare_exchange_n(&cpp_frame_started,&expected,now,0,__ATOMIC_RELAXED,__ATOMIC_RELAXED);
    if(now-__atomic_load_n(&cpp_frame_started,__ATOMIC_RELAXED)>=15000){
        expected=0;
        if(__atomic_compare_exchange_n(&cpp_frame_restored,&expected,1,0,__ATOMIC_RELAXED,__ATOMIC_RELAXED)){
            __atomic_add_fetch(&cpp_frame_counts->restored,1,__ATOMIC_RELAXED);return 2;
        }
        return 0;
    }
    __atomic_add_fetch(&cpp_frame_counts->applied,1,__ATOMIC_RELAXED);return 1;
}
static void CPP_ABI cpp_on_cpu(void *,void *,int,const void *,const void *,int,int,const void *,float);
static void CPP_ABI cpp_on_gpu(void *,void *,int,const void *,const void *);
static void cpp_count(enum cpp_counter c) { __atomic_add_fetch(&cpp_data->counters[c],1,__ATOMIC_RELAXED); }
static void cpp_begin(void) { cpp_lock();__atomic_add_fetch(&cpp_data->sequence,1,__ATOMIC_SEQ_CST); }
static void cpp_end(void) { __atomic_add_fetch(&cpp_data->sequence,1,__ATOMIC_SEQ_CST);cpp_unlock(); }
static int cpp_native_id(void *painter,uint32_t *id) {
    uintptr_t p=(uintptr_t)painter,owner=0;
    if(!p||p>UINTPTR_MAX-0x10-sizeof(owner)||!cpp_readable((const void *)(p+0x10),sizeof(owner)))return 0;
    memcpy(&owner,(const void *)(p+0x10),sizeof(owner));
    if(!owner||owner>UINTPTR_MAX-0x328-sizeof(*id)||!cpp_readable((const void *)(owner+0x328),sizeof(*id)))return 0;
    memcpy(id,(const void *)(owner+0x328),sizeof(*id));return 1;
}
/* Original helper Browser.GetBrowserID uses this same CefBrowser virtual +0x50.
 * Browser refs remain borrowed; GetIdentifier neither adds nor releases a ref. */
static int cpp_cef_id(void *browser_ref,uint32_t *id) {
    uintptr_t browser=0,vtable=0,function=0;
    if(!cpp_readable(browser_ref,sizeof(browser)))return 0;
    memcpy(&browser,browser_ref,sizeof(browser));
    if(!cpp_readable((void *)browser,sizeof(vtable)))return 0;
    memcpy(&vtable,(void *)browser,sizeof(vtable));
    if(vtable>UINTPTR_MAX-0x50-sizeof(function)||!cpp_readable((void *)(vtable+0x50),sizeof(function)))return 0;
    memcpy(&function,(void *)(vtable+0x50),sizeof(function));
#ifdef SEVO_OBSERVER_TEST
    if(!cpp_test_executable((void *)function))return 0;
#else
    if(!cpp_executable((void *)function))return 0;
#endif
    typedef int (CPP_ABI *get_identifier_fn)(void *);
    int value=((get_identifier_fn)function)((void *)browser);
    if(value<=0)return 0;
    *id=(uint32_t)value;return 1;
}
static void cpp_note(void *painter,int type,int gpu,int width,int height) {
    uint32_t id=0;int valid=cpp_native_id(painter,&id);
    if(!valid)cpp_count(CPP_NATIVE_ID_UNREADABLE);
    cpp_begin();cpp_painter *row=NULL;
    for(uint64_t i=0;i<cpp_data->painter_count;i++){
        cpp_painter *candidate=&cpp_data->painters[i];
        if(candidate->painter==(uintptr_t)painter&&candidate->identity_valid==(uint64_t)valid&&
           candidate->native_browser_id==(uint64_t)id){row=candidate;break;}
    }
    if(!row){
        if(cpp_data->painter_count==CPP_PAINTER_LIMIT)cpp_count(CPP_RECORDS_DROPPED);
        else{row=&cpp_data->painters[cpp_data->painter_count++];row->painter=(uintptr_t)painter;
            row->identity_valid=(uint64_t)valid;row->native_browser_id=id;row->first_tick=cpp_tick();}
    }
    if(row){
        if(gpu)row->gpu_entries++;else{row->cpu_entries++;row->last_width=width;row->last_height=height;}
        if(type==0)row->view_entries++;else if(type==1)row->popup_entries++;else row->other_entries++;
        row->last_type=type;row->last_tick=cpp_tick();
    }
    cpp_end();
}
static void CPP_ABI cpp_on_cpu(void *self,void *browser_ref,int type,const void *dirty_vector,const void *pixels,
                               int width,int height,const void *scroll,float scale) {
    unsigned long error=cpp_error();cpp_count(CPP_CPU_ENTRIES);
    cpp_cpu_fn original=__atomic_load_n(&cpp_cpu_original,__ATOMIC_ACQUIRE);
    if(!original){cpp_count(CPP_MISSING_ORIGINAL);cpp_set_error(error);return;}
    cpp_note(self,type,0,width,height);
    uint32_t cef_id=0;uint64_t identity=0;
    if(cpp_frame_pixels&&cpp_cef_id(browser_ref,&cef_id))identity=((uint64_t)1<<32)|cef_id;
    int frame_choice=cpp_frame_use(identity,type,width,height);
    if(frame_choice){
        /* REA 11a640 reads a borrowed MSVC vector's begin/end, then its full-view rect.
         * The original owns the paint map, message publication and browser-ref release. */
        int full[4]={0,0,width,height};const void *vector[3]={full,full+4,full+4};
        cpp_set_error(error);
        original(self,browser_ref,type,vector,frame_choice==1?cpp_frame_pixels:pixels,width,height,scroll,scale);return;
    }
    cpp_set_error(error);
    /* No work after the original: its final LastError and reference lifecycle survive. */
    original(self,browser_ref,type,dirty_vector,pixels,width,height,scroll,scale);
}
static void CPP_ABI cpp_on_gpu(void *self,void *browser_ref,int type,const void *dirty_vector,const void *opaque) {
    unsigned long error=cpp_error();cpp_count(CPP_GPU_ENTRIES);
    cpp_gpu_fn original=__atomic_load_n(&cpp_gpu_original,__ATOMIC_ACQUIRE);
    if(!original){cpp_count(CPP_MISSING_ORIGINAL);cpp_set_error(error);return;}
    cpp_note(self,type,1,0,0);cpp_set_error(error);
    original(self,browser_ref,type,dirty_vector,opaque);
}
/* Caller temporarily makes the containing page writable; only these two slots change. */
static int cpp_install(void **cpu_slot,void **gpu_slot,void *expected_cpu,void *expected_gpu) {
    cpp_begin();cpp_data->slot_count=2;
    cpp_slot *cpu=&cpp_data->slots[0],*gpu=&cpp_data->slots[1];
    cpu->slot_rva=CPP_CPU_SLOT_RVA;cpu->expected_rva=CPP_CPU_RVA;
    gpu->slot_rva=CPP_GPU_SLOT_RVA;gpu->expected_rva=CPP_GPU_RVA;
    int valid=cpp_readable(cpu_slot,sizeof(void *))&&cpp_readable(gpu_slot,sizeof(void *))&&
        !((uintptr_t)cpu_slot%sizeof(void *))&&!((uintptr_t)gpu_slot%sizeof(void *));
    void *a=valid?__atomic_load_n(cpu_slot,__ATOMIC_SEQ_CST):NULL;
    void *b=valid?__atomic_load_n(gpu_slot,__ATOMIC_SEQ_CST):NULL;
    cpu->observed=(uintptr_t)a;gpu->observed=(uintptr_t)b;
    if(valid&&a==(void *)cpp_on_cpu&&b==(void *)cpp_on_gpu&&
       __atomic_load_n(&cpp_cpu_original,__ATOMIC_ACQUIRE)==(cpp_cpu_fn)expected_cpu&&
       __atomic_load_n(&cpp_gpu_original,__ATOMIC_ACQUIRE)==(cpp_gpu_fn)expected_gpu){
        cpp_count(CPP_SLOT_ALREADY);cpp_count(CPP_SLOT_ALREADY);cpp_end();return 1;
    }
    if(!valid||!expected_cpu||!expected_gpu||a!=expected_cpu||b!=expected_gpu){
        cpu->rejected++;gpu->rejected++;cpp_count(CPP_SLOT_REJECTED);cpp_end();return 0;
    }
    /* Publish before either CAS can make a callback visible to another thread. */
    __atomic_store_n(&cpp_cpu_original,(cpp_cpu_fn)expected_cpu,__ATOMIC_RELEASE);
    __atomic_store_n(&cpp_gpu_original,(cpp_gpu_fn)expected_gpu,__ATOMIC_RELEASE);
    cpu->original=(uintptr_t)expected_cpu;gpu->original=(uintptr_t)expected_gpu;
    if(!__atomic_compare_exchange_n(cpu_slot,&a,(void *)cpp_on_cpu,0,__ATOMIC_SEQ_CST,__ATOMIC_SEQ_CST)){
        cpu->observed=(uintptr_t)a;cpu->rejected++;cpp_count(CPP_SLOT_REJECTED);cpp_end();return 0;
    }
    if(!__atomic_compare_exchange_n(gpu_slot,&b,(void *)cpp_on_gpu,0,__ATOMIC_SEQ_CST,__ATOMIC_SEQ_CST)){
        gpu->observed=(uintptr_t)b;gpu->rejected++;cpp_count(CPP_SLOT_REJECTED);
        a=(void *)cpp_on_cpu;
        if(!__atomic_compare_exchange_n(cpu_slot,&a,expected_cpu,0,__ATOMIC_SEQ_CST,__ATOMIC_SEQ_CST)){
            cpu->observed=(uintptr_t)a;cpp_count(CPP_ROLLBACK_FAILED);cpp_end();return -1;
        }
        cpp_end();return 0;
    }
    cpu->installed=1;gpu->installed=1;cpp_count(CPP_SLOT_INSTALLED);cpp_count(CPP_SLOT_INSTALLED);cpp_end();return 1;
}
#ifndef SEVO_OBSERVER_TEST
static HMODULE cpp_module;
static int cpp_host_sha(HMODULE host) {
    wchar_t path[32768];DWORD length=GetModuleFileNameW(host,path,32768);
    if(!length||length>=32768)return 0;
    const wchar_t *leaf=wcsrchr(path,L'\\');leaf=leaf?leaf+1:path;
    if(_wcsicmp(leaf,L"steamwebhelper.exe"))return 0;
    HANDLE file=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
    if(file==INVALID_HANDLE_VALUE)return 0;
    BCRYPT_ALG_HANDLE algorithm=NULL;BCRYPT_HASH_HANDLE hash=NULL;uint8_t bytes[65536],digest[32];char hex[65];DWORD n=0;int ok=0;
    if(BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,NULL,0)<0||BCryptCreateHash(algorithm,&hash,NULL,0,NULL,0,0)<0)goto done;
    for(;;){if(!ReadFile(file,bytes,sizeof(bytes),&n,NULL))goto done;if(!n)break;if(BCryptHashData(hash,bytes,n,0)<0)goto done;}
    if(BCryptFinishHash(hash,digest,sizeof(digest),0)<0)goto done;
    for(size_t i=0;i<32;i++)snprintf(hex+i*2,3,"%02x",digest[i]);
    ok=!strcmp(hex,CPP_HELPER_SHA);
done:
    if(hash)BCryptDestroyHash(hash);
    if(algorithm)BCryptCloseAlgorithmProvider(algorithm,0);
    CloseHandle(file);return ok;
}
static int cpp_create_stats(void) {
    wchar_t config[32768],directory[2048],output[2304];
    DWORD length=GetModuleFileNameW(cpp_module,config,32768);if(!length||length>=32768)return 0;
    wchar_t *slash=wcsrchr(config,L'\\');if(!slash)return 0;wcscpy(slash+1,L"cpp-observer.cfg");
    FILE *f=_wfopen(config,L"rb");if(!f)return 0;
    char line[4096]={0};size_t n=fread(line,1,sizeof(line)-1,f);fclose(f);
    while(n&&(line[n-1]=='\n'||line[n-1]=='\r'))line[--n]=0;
    if(!n||!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,line,-1,directory,2048))return 0;
    FILETIME created,exited,kernel,user;
    if(!GetProcessTimes(GetCurrentProcess(),&created,&exited,&kernel,&user))return 0;
    uint64_t start=((uint64_t)created.dwHighDateTime<<32)|created.dwLowDateTime;
    swprintf(output,2304,L"%ls\\cpp-observer-%lu-%llu.stats",directory,GetCurrentProcessId(),(unsigned long long)start);
    HANDLE file=CreateFileW(output,GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);
    if(file==INVALID_HANDLE_VALUE)return 0;
    HANDLE map=CreateFileMappingW(file,NULL,PAGE_READWRITE,0,sizeof(cpp_stats),NULL);CloseHandle(file);if(!map)return 0;
    cpp_data=MapViewOfFile(map,FILE_MAP_ALL_ACCESS,0,0,0);CloseHandle(map);if(!cpp_data)return 0;
    memset(cpp_data,0,sizeof(*cpp_data));memcpy(cpp_data->magic,CPP_MAGIC,8);
    cpp_data->schema=CPP_SCHEMA;cpp_data->bytes=sizeof(*cpp_data);cpp_data->pid=GetCurrentProcessId();cpp_data->process_start=start;return 1;
}
static int cpp_load_frame(void) {
    wchar_t path[32768],stats[32768];DWORD length=GetModuleFileNameW(cpp_module,path,32768);
    if(!length||length>=32768)return 0;
    wchar_t *slash=wcsrchr(path,L'\\');if(!slash)return 0;
    wcscpy(slash+1,L"frame.bgra");FILE *file=_wfopen(path,L"rb");
    if(!file)return GetFileAttributesW(path)==INVALID_FILE_ATTRIBUTES; /* Default observer mode. */
    cpp_frame_header h;int ok=fread(&h,1,sizeof(h),file)==sizeof(h)&&cpp_frame_valid(h);
    void *pixels=ok?malloc(h.bytes):NULL;
    ok=ok&&pixels&&fread(pixels,1,h.bytes,file)==h.bytes&&fgetc(file)==EOF;fclose(file);
    if(!ok){free(pixels);return 0;}
    wcscpy(stats,path);slash=wcsrchr(stats,L'\\');
    swprintf(slash+1,64,L"frame-%lu.stats",GetCurrentProcessId());
    HANDLE output=CreateFileW(stats,GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,
                              NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);
    if(output==INVALID_HANDLE_VALUE){free(pixels);return 0;}
    HANDLE map=CreateFileMappingW(output,NULL,PAGE_READWRITE,0,sizeof(cpp_frame_stats),NULL);CloseHandle(output);
    if(!map){free(pixels);return 0;}
    cpp_frame_counts=MapViewOfFile(map,FILE_MAP_ALL_ACCESS,0,0,0);CloseHandle(map);
    if(!cpp_frame_counts){free(pixels);return 0;}
    memset(cpp_frame_counts,0,sizeof(*cpp_frame_counts));memcpy(cpp_frame_counts->magic,"SEVOFP01",8);
    cpp_frame_counts->target=h.target;cpp_frame_counts->width=h.width;cpp_frame_counts->height=h.height;
    cpp_frame=h;cpp_frame_pixels=pixels;return 1;
}
static int cpp_executable(void *address) {
    MEMORY_BASIC_INFORMATION m;
    return VirtualQuery(address,&m,sizeof(m))&&m.State==MEM_COMMIT&&!(m.Protect&(PAGE_GUARD|PAGE_NOACCESS))&&
        (m.Protect&(PAGE_EXECUTE|PAGE_EXECUTE_READ|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY));
}
static DWORD WINAPI cpp_attach(LPVOID ignored) {
    (void)ignored;if(!cpp_create_stats())return 1;
    uint8_t *image=(uint8_t *)GetModuleHandleW(NULL);
    if(!cpp_host_sha((HMODULE)image)){cpp_data->status=3;return 3;}
    IMAGE_DOS_HEADER dos;
    if(!cpp_readable(image,sizeof(dos))){cpp_data->status=2;return 2;}
    memcpy(&dos,image,sizeof(dos));
    if(dos.e_magic!=IMAGE_DOS_SIGNATURE||dos.e_lfanew<0||dos.e_lfanew>0x100000){cpp_data->status=2;return 2;}
    IMAGE_NT_HEADERS64 nt;
    if(!cpp_readable(image+dos.e_lfanew,sizeof(nt))){cpp_data->status=2;return 2;}
    memcpy(&nt,image+dos.e_lfanew,sizeof(nt));
    if(nt.Signature!=IMAGE_NT_SIGNATURE||nt.FileHeader.Machine!=IMAGE_FILE_MACHINE_AMD64||
       nt.OptionalHeader.Magic!=IMAGE_NT_OPTIONAL_HDR64_MAGIC||nt.OptionalHeader.SizeOfImage!=CPP_IMAGE_BYTES){cpp_data->status=2;return 2;}
    cpp_data->helper_base=(uintptr_t)image;cpp_data->image_bytes=nt.OptionalHeader.SizeOfImage;
    if(!cpp_load_frame()){cpp_data->status=10;return 10;}
    void **cpu=(void **)(image+CPP_CPU_SLOT_RVA),**gpu=(void **)(image+CPP_GPU_SLOT_RVA);
    void *expected_cpu=image+CPP_CPU_RVA,*expected_gpu=image+CPP_GPU_RVA;
    if(!cpp_readable(cpu,2*sizeof(void *))||!cpp_executable(expected_cpu)||!cpp_executable(expected_gpu)){
        cpp_data->status=4;return 4;
    }
    /* Keep code resident for the full helper lifetime, including a partial-CAS failure. */
    HMODULE pinned=NULL;
    if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,
                          (LPCWSTR)(uintptr_t)cpp_on_cpu,&pinned)){cpp_data->status=8;return 8;}
    DWORD protection=0,unused=0;
    if(!VirtualProtect(cpu,2*sizeof(void *),PAGE_READWRITE,&protection)){cpp_data->status=5;return 5;}
    int installed=cpp_install(cpu,gpu,expected_cpu,expected_gpu);
    int restored=VirtualProtect(cpu,2*sizeof(void *),protection,&unused)!=0;
    if(!restored){cpp_data->status=7;return 7;}
    if(installed!=1){cpp_data->status=installed<0?9:6;return (DWORD)cpp_data->status;}
    __atomic_store_n(&cpp_data->ready,1,__ATOMIC_RELEASE);return 0;
}
BOOL WINAPI DllMain(HINSTANCE module,DWORD reason,LPVOID reserved) {
    (void)reserved;
    if(reason==DLL_PROCESS_ATTACH){cpp_module=module;DisableThreadLibraryCalls(module);
        HANDLE thread=CreateThread(NULL,0,cpp_attach,NULL,0,NULL);if(thread)CloseHandle(thread);}
    return TRUE;
}
#endif
