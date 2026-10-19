/* WebKit pixels enter the original Steam CPU paint callback. No game hook,
 * input hook, hotkey, focus or cursor implementation is installed here. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include "paint.h"
#include "../../Sevoflurane/Web/NativeOverlayTransport.h"
#ifdef SEVO_OBSERVER_TEST
#include <pthread.h>
#include <time.h>
static _Thread_local unsigned long cpp_test_last_error;
static int cpp_test_readable(const void *,size_t);
static int cpp_test_executable(void *);
static const void *cpp_test_frame(uint32_t,int,int,int *);
static unsigned long cpp_error(void) { return cpp_test_last_error; }
static void cpp_set_error(unsigned long value) { cpp_test_last_error=value; }
static int cpp_readable(const void *p,size_t n) { return cpp_test_readable(p,n); }
#else
#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif
#include <windows.h>
#include <bcrypt.h>
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
#endif
#ifndef SEVO_OBSERVER_TEST
static int cpp_executable(void *);
#endif
#ifdef SEVO_OBSERVER_TEST
static const void *cpp_stream_read(uint32_t id,int width,int height,int *restore,int *locked) {
    (void)locked;return cpp_test_frame(id,width,height,restore);
}
static void cpp_stream_release(int locked) { (void)locked; }
#else
static wchar_t cpp_stream_directory[2048];
static SRWLOCK cpp_stream_mutex=SRWLOCK_INIT;
typedef struct { uint32_t id,front;int width,height,used;uint64_t checked;SevoNativeFrame *map;wchar_t path[2048]; } cpp_stream;
static cpp_stream cpp_streams[16];
static uint64_t cpp_wall_ms(void) {
    FILETIME ft;GetSystemTimeAsFileTime(&ft);
    return (((uint64_t)ft.dwHighDateTime<<32)|ft.dwLowDateTime)/10000-11644473600000ULL;
}
static const void *cpp_stream_read(uint32_t id,int width,int height,int *restore,int *locked) {
    if(!id||!cpp_stream_directory[0]||!SevoNativeFrameSize((uint32_t)width,(uint32_t)height)||
       !TryAcquireSRWLockExclusive(&cpp_stream_mutex))return NULL;
    *locked=1;cpp_stream *s=NULL;
    for(int i=0;i<16;i++)if(cpp_streams[i].id==id){s=&cpp_streams[i];break;}
    if(!s){
        wchar_t registry[2304];
        swprintf(registry,2304,L"%ls\\stream-%u-%dx%d.path",cpp_stream_directory,id,width,height);
        if(GetFileAttributesW(registry)==INVALID_FILE_ATTRIBUTES)return NULL;
        for(int i=0;i<16;i++)if(!cpp_streams[i].id){s=&cpp_streams[i];s->id=id;break;}
        if(!s)for(int i=0;i<16;i++)if(cpp_streams[i].map&&
            !__atomic_load_n(&cpp_streams[i].map->active,__ATOMIC_ACQUIRE)){
            s=&cpp_streams[i];UnmapViewOfFile(s->map);memset(s,0,sizeof(*s));s->id=id;break;
        }
    }
    if(!s)return NULL;
    uint64_t now=cpp_wall_ms();
    if(s->width!=width||s->height!=height||now-s->checked>1000){
        wchar_t registry[2304],path[2048]={0};char utf8[4096]={0};
        swprintf(registry,2304,L"%ls\\stream-%u-%dx%d.path",cpp_stream_directory,id,width,height);
        FILE *f=_wfopen(registry,L"rb");
        if(f){size_t n=fread(utf8,1,sizeof(utf8)-1,f);fclose(f);
            while(n&&(utf8[n-1]=='\n'||utf8[n-1]=='\r'))utf8[--n]=0;
            if(n)MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,utf8,-1,path,2048);
        }
        s->checked=now;
        if(path[0]&&(s->width!=width||s->height!=height||wcscmp(s->path,path))){
            HANDLE file=CreateFileW(path,GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,
                NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);LARGE_INTEGER size={0};
            if(file!=INVALID_HANDLE_VALUE){
                if(GetFileSizeEx(file,&size)&&(uint64_t)size.QuadPart==SevoNativeFrameSize((uint32_t)width,(uint32_t)height)){
                    HANDLE mapping=CreateFileMappingW(file,NULL,PAGE_READWRITE,0,0,NULL);
                    if(mapping){SevoNativeFrame *h=MapViewOfFile(mapping,FILE_MAP_ALL_ACCESS,0,0,0);CloseHandle(mapping);
                        if(h&&SevoNativeFrameValid(h,id,width,height)){
                            if(s->map)UnmapViewOfFile(s->map);
                            s->map=h;s->front=0;s->width=width;s->height=height;wcscpy(s->path,path);
                        }else if(h)UnmapViewOfFile(h);
                    }
                }CloseHandle(file);
            }
        }
    }
    const void *pixels=s->map&&s->width==width&&s->height==height?SevoNativeFrameRead(s->map,&s->front,now):NULL;
    if(pixels)s->used=1;else if(s->used){*restore=1;s->used=0;}
    return pixels;
}
static void cpp_stream_release(int locked) {
    if(locked)ReleaseSRWLockExclusive(&cpp_stream_mutex);
}
#endif
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

static cpp_cpu_fn cpp_cpu_original;
static void CPP_ABI cpp_on_cpu(void *self,void *browser_ref,int type,const void *dirty,const void *pixels,
                              int width,int height,const void *scroll,float scale) {
    unsigned long error=cpp_error();
    cpp_cpu_fn original=__atomic_load_n(&cpp_cpu_original,__ATOMIC_ACQUIRE);if(!original)return;
    uint32_t id=0;int restore=0,locked=0;
    const void *replacement=type==0&&cpp_cef_id(browser_ref,&id)?cpp_stream_read(id,width,height,&restore,&locked):NULL;
    if(replacement||restore){
        int full[4]={0,0,width,height};const void *vector[3]={full,full+4,full+4};
        cpp_set_error(error);original(self,browser_ref,type,vector,replacement?replacement:pixels,width,height,scroll,scale);
        error=cpp_error();cpp_stream_release(locked);cpp_set_error(error);return;
    }
    cpp_stream_release(locked);cpp_set_error(error);
    original(self,browser_ref,type,dirty,pixels,width,height,scroll,scale);
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
static int cpp_executable(void *address) {
    MEMORY_BASIC_INFORMATION m;
    return VirtualQuery(address,&m,sizeof(m))&&m.State==MEM_COMMIT&&!(m.Protect&(PAGE_GUARD|PAGE_NOACCESS))&&
        (m.Protect&(PAGE_EXECUTE|PAGE_EXECUTE_READ|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY));
}
#endif

#ifndef SEVO_OBSERVER_TEST
static void status_file(int status) {
    wchar_t path[2304];swprintf(path,2304,L"%ls\\ready-%lu.status",cpp_stream_directory,GetCurrentProcessId());
    FILE *f=_wfopen(path,L"wb");if(f){fprintf(f,"%d\n",status);fclose(f);}
}
static DWORD WINAPI cpp_attach(LPVOID ignored) {
    (void)ignored;wchar_t cfg[32768];char line[4096]={0};
    if(!GetModuleFileNameW(cpp_module,cfg,32768))return 1;
    wchar_t *slash=wcsrchr(cfg,L'\\');if(!slash)return 1;wcscpy(slash+1,L"overlay.cfg");
    FILE *f=_wfopen(cfg,L"rb");if(!f)return 1;size_t n=fread(line,1,sizeof(line)-1,f);fclose(f);
    while(n&&(line[n-1]=='\n'||line[n-1]=='\r'))line[--n]=0;
    if(!n||!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,line,-1,cpp_stream_directory,2048))return 1;
    uint8_t *image=(uint8_t *)GetModuleHandleW(NULL);
    if(!cpp_host_sha((HMODULE)image)){status_file(2);return 2;}
    IMAGE_DOS_HEADER *dos=(void *)image;
    if(!cpp_readable(dos,sizeof(*dos))||dos->e_magic!=IMAGE_DOS_SIGNATURE||dos->e_lfanew<0||dos->e_lfanew>0x100000){status_file(3);return 3;}
    IMAGE_NT_HEADERS64 *nt=(void *)(image+dos->e_lfanew);
    if(!cpp_readable(nt,sizeof(*nt))||nt->Signature!=IMAGE_NT_SIGNATURE||
       nt->FileHeader.Machine!=IMAGE_FILE_MACHINE_AMD64||nt->OptionalHeader.SizeOfImage!=CPP_IMAGE_BYTES){status_file(3);return 3;}
    void **slot=(void **)(image+CPP_CPU_SLOT_RVA);void *expected=image+CPP_CPU_RVA;
    if(!cpp_readable(slot,sizeof(void *))||!cpp_executable(expected)||*slot!=expected){status_file(4);return 4;}
    HMODULE pinned=NULL;
    if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,
                          (LPCWSTR)(uintptr_t)cpp_on_cpu,&pinned)){status_file(5);return 5;}
    DWORD protection=0,unused=0;
    if(!VirtualProtect(slot,sizeof(void *),PAGE_READWRITE,&protection)){status_file(6);return 6;}
    __atomic_store_n(&cpp_cpu_original,(cpp_cpu_fn)expected,__ATOMIC_RELEASE);
    int installed=__atomic_compare_exchange_n(slot,&expected,(void *)cpp_on_cpu,0,__ATOMIC_SEQ_CST,__ATOMIC_SEQ_CST);
    int restored=VirtualProtect(slot,sizeof(void *),protection,&unused)!=0;
    status_file(installed&&restored?0:7);return installed&&restored?0:7;
}
BOOL WINAPI DllMain(HINSTANCE module,DWORD reason,LPVOID reserved) {
    (void)reserved;if(reason==DLL_PROCESS_ATTACH){cpp_module=module;DisableThreadLibraryCalls(module);
        HANDLE thread=CreateThread(NULL,0,cpp_attach,NULL,0,NULL);if(thread)CloseHandle(thread);}
    return TRUE;
}
#endif
