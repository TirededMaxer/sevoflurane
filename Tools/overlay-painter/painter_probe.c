/* Exact Steam CEF 126 Windows-x64 diagnostic adapter. No renderer/hotkey replacement. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include "paint_frame.h"
#define CLIENT_DISPLAY 0x48
#define CLIENT_RENDER 0xa8
#define DISPLAY_TITLE 0x30
#define RENDER_PAINT 0x60
#define RENDER_ACCELERATED 0x68
#define BROWSER_ID 0x78
#define API_PLATFORM "97314fe45c14007fca596262a64cad69467df21f"
#define API_UNIVERSAL "908f7378d71977393cee4bc349055b7365c3673c"
typedef struct { void *object, *original; size_t offset; } slot;
typedef struct { int id, overlay, restore; } browser_state;
typedef struct { const void *text; size_t length; void *destructor; } cef_string_view;
typedef void *(__cdecl *get_handler_fn)(void *);
typedef int (__cdecl *identifier_fn)(void *);
/* Valve extends upstream OnPaint with scroll offset and page scale. Keep both intact. */
typedef void (__cdecl *paint_fn)(void *, void *, int, size_t, const sevo_rect *, const void *, int, int, const void *, float);
typedef void (__cdecl *title_fn)(void *, void *, const cef_string_view *);
static HMODULE this_module, original_module;
static INIT_ONCE init_once = INIT_ONCE_STATIC_INIT;
static SRWLOCK lock = SRWLOCK_INIT;
static slot slots[512]; static size_t slot_count;
static browser_state browsers[64]; static size_t browser_count;
static sevo_probe_stats *stats;
static wchar_t directory[2048];
static int enabled;
static ULONGLONG next_request_check;
static void *original_slot(void *object, size_t offset) {
    void *value = NULL;
    AcquireSRWLockShared(&lock);
    for (size_t i=0;i<slot_count;i++) if (slots[i].object==object && slots[i].offset==offset) { value=slots[i].original; break; }
    ReleaseSRWLockShared(&lock); return value;
}
static void patch_slot(void *object, size_t offset, void *replacement) {
    if (!object || *(size_t *)object < offset + sizeof(void *) || *(size_t *)object > 4096) { if(stats) InterlockedIncrement64(&stats->abi_rejected); return; }
    void **address = (void **)((uint8_t *)object + offset);
    AcquireSRWLockExclusive(&lock);
    if (*address != replacement && *address) {
        size_t i; for(i=0;i<slot_count;i++) if(slots[i].object==object && slots[i].offset==offset) break;
        if(i<512) {
            if(i==slot_count) slot_count++;
            slots[i]=(slot){object,*address,offset};
            InterlockedExchangePointer((PVOID volatile *)address,replacement);
        } else if(stats) InterlockedIncrement64(&stats->abi_rejected);
    }
    ReleaseSRWLockExclusive(&lock);
}
static int browser_id(void *browser) {
    if (!browser || *(size_t *)browser != 0xe8) return 0;
    identifier_fn fn=*(identifier_fn *)((uint8_t *)browser+BROWSER_ID);
    return fn ? fn(browser) : 0;
}
static int is_overlay(int id, int *restore, int clear_restore) {
    int overlay=0; if(restore)*restore=0;
    AcquireSRWLockExclusive(&lock);
    for(size_t i=0;i<browser_count;i++) if(browsers[i].id==id) {
        overlay=browsers[i].overlay; if(restore)*restore=browsers[i].restore;
        if(clear_restore) browsers[i].restore=0;
        break;
    }
    ReleaseSRWLockExclusive(&lock); return overlay;
}
static void set_restore(int id) {
    AcquireSRWLockExclusive(&lock);
    for(size_t i=0;i<browser_count;i++)if(browsers[i].id==id)browsers[i].restore=1;
    ReleaseSRWLockExclusive(&lock);
}
static int overlay_title(const cef_string_view *s) {
    return s && sevo_overlay_title_prefix(s->text, s->length);
}
static void __cdecl on_title(void *self, void *browser, const cef_string_view *title) {
    int id=browser_id(browser), match=overlay_title(title);
    InterlockedIncrement64(&stats->titles);
    if(id) {
        AcquireSRWLockExclusive(&lock);
        size_t i;for(i=0;i<browser_count;i++)if(browsers[i].id==id)break;
        if(i<64){if(i==browser_count){browser_count++;browsers[i]=(browser_state){id,0,0};}
            if(match&&!browsers[i].overlay)InterlockedIncrement64(&stats->overlay_browsers);
            browsers[i].overlay=match;}
        ReleaseSRWLockExclusive(&lock);
    }
    title_fn original=(title_fn)original_slot(self,DISPLAY_TITLE); if(original)original(self,browser,title);
}
static void * __cdecl get_display(void *self) {
    get_handler_fn original=(get_handler_fn)original_slot(self,CLIENT_DISPLAY);
    void *handler=original?original(self):NULL; if(handler)patch_slot(handler,DISPLAY_TITLE,on_title); return handler;
}
/* Tail thunk in proxy_thunks.S preserves every original accelerated-paint argument. */
extern void sevo_accelerated_thunk(void);
void *sevo_before_accelerated(void *self, void *browser) {
    InterlockedIncrement64(&stats->gpu_paints);
    if(is_overlay(browser_id(browser),NULL,0))InterlockedIncrement64(&stats->overlay_gpu_paints);
    return original_slot(self,RENDER_ACCELERATED);
}
static void __cdecl on_paint(void *self,void *browser,int type,size_t count,const sevo_rect *rects,const void *buffer,int width,int height,const void *scroll_offset,float page_scale) {
    paint_fn original=(paint_fn)original_slot(self,RENDER_PAINT); if(!original)return;
    InterlockedIncrement64(&stats->cpu_paints);
    int id=browser_id(browser),restore=0;
    if(type!=0 || !is_overlay(id,&restore,1)){original(self,browser,type,count,rects,buffer,width,height,scroll_offset,page_scale);return;}
    InterlockedIncrement64(&stats->overlay_cpu_paints);
    InterlockedExchange64(&stats->last_width,width);InterlockedExchange64(&stats->last_height,height);InterlockedExchange64(&stats->last_browser,id);
    HANDLE file=INVALID_HANDLE_VALUE,map=NULL; const void *bytes=NULL;const uint8_t *pixels=NULL;LARGE_INTEGER size;
    ULONGLONG now=GetTickCount64();
    if(now>=next_request_check){
        next_request_check=now+250;
        wchar_t request[2304];swprintf(request,2304,L"%ls\\frame-%lu-%d.request",directory,GetCurrentProcessId(),id);
        file=CreateFileW(request,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
        if(file!=INVALID_HANDLE_VALUE){
            if(GetFileSizeEx(file,&size)&&size.QuadPart>=64&&size.QuadPart<=SEVO_FRAME_LIMIT+64){map=CreateFileMappingW(file,NULL,PAGE_READONLY,0,0,NULL);if(map)bytes=MapViewOfFile(map,FILE_MAP_READ,0,0,0);if(bytes)pixels=sevo_frame_pixels(bytes,(size_t)size.QuadPart,width,height);}
            DeleteFileW(request);
            if(!pixels)InterlockedIncrement64(&stats->rejected_frames);
        }
    }
    sevo_rect full={0,0,width,height};
    if(pixels){
        /* Original synchronous CPU painter copies the provided BGRA pixels. */
        original(self,browser,type,1,&full,pixels,width,height,scroll_offset,page_scale);
        set_restore(id);InterlockedIncrement64(&stats->replacement_paints);
    }else{
        original(self,browser,type,restore?1:count,restore?&full:rects,buffer,width,height,scroll_offset,page_scale);
        if(restore)InterlockedIncrement64(&stats->restored_paints);
    }
    if(bytes) { UnmapViewOfFile(bytes); }
    if(map) { CloseHandle(map); }
    if(file!=INVALID_HANDLE_VALUE) { CloseHandle(file); }
}
static void * __cdecl get_render(void *self) {
    get_handler_fn original=(get_handler_fn)original_slot(self,CLIENT_RENDER);
    void *handler=original?original(self):NULL;
    if(handler){InterlockedIncrement64(&stats->render_handlers);patch_slot(handler,RENDER_PAINT,on_paint);patch_slot(handler,RENDER_ACCELERATED,sevo_accelerated_thunk);}
    return handler;
}
static BOOL CALLBACK initialize(PINIT_ONCE once, PVOID parameter, PVOID *context) {
    (void)once;(void)parameter;(void)context;
    original_module=GetModuleHandleW(L"libcef.dll");
    if(!original_module)return TRUE;
    wchar_t config[2304];GetModuleFileNameW(this_module,config,2304);wchar_t *slash=wcsrchr(config,L'\\');if(!slash)return TRUE;wcscpy(slash+1,L"sevo-painter-probe.txt");
    FILE *f=_wfopen(config,L"rb");if(!f)return TRUE;char line[4096]={0};size_t n=fread(line,1,sizeof(line)-1,f);fclose(f);while(n&&(line[n-1]=='\n'||line[n-1]=='\r'))line[--n]=0;
    if(!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,line,-1,directory,2048))return TRUE;
    wchar_t output[2304];swprintf(output,2304,L"%ls\\cef-%lu.stats",directory,GetCurrentProcessId());
    HANDLE file=CreateFileW(output,GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);
    if(file==INVALID_HANDLE_VALUE) { return TRUE; }
    HANDLE map=CreateFileMappingW(file,NULL,PAGE_READWRITE,0,sizeof(sevo_probe_stats),NULL);
    CloseHandle(file);
    if(!map) { return TRUE; }
    stats=MapViewOfFile(map,FILE_MAP_ALL_ACCESS,0,0,0);CloseHandle(map);if(!stats)return TRUE;memset(stats,0,sizeof(*stats));memcpy(stats->magic,SEVO_STATS_MAGIC,8);stats->version=2;stats->pid=GetCurrentProcessId();
    typedef const char *(__cdecl *hash_fn)(int);hash_fn hash=(hash_fn)GetProcAddress(original_module,"cef_api_hash");
    if(!hash || strcmp(hash(0),API_PLATFORM)||strcmp(hash(1),API_UNIVERSAL)){InterlockedIncrement64(&stats->abi_rejected);return TRUE;}
    enabled=1;return TRUE;
}
void *sevo_create_target(uintptr_t sync,void *client) {
    InitOnceExecuteOnce(&init_once,initialize,NULL,NULL);
    if(enabled){InterlockedIncrement64(&stats->created_browsers);patch_slot(client,CLIENT_DISPLAY,get_display);patch_slot(client,CLIENT_RENDER,get_render);}
    return original_module ? GetProcAddress(original_module,sync?"cef_browser_host_create_browser_sync":"cef_browser_host_create_browser") : NULL;
}
extern void sevo_create_browser_thunk(void);
extern void sevo_create_browser_sync_thunk(void);
static DWORD WINAPI attach_imports(LPVOID parameter) {
    (void)parameter;
    InitOnceExecuteOnce(&init_once,initialize,NULL,NULL);
    if(!enabled) return 1;
    uint8_t *image=(uint8_t *)GetModuleHandleW(NULL);
    IMAGE_DOS_HEADER *dos=(IMAGE_DOS_HEADER *)image;
    if(dos->e_magic!=IMAGE_DOS_SIGNATURE) return 2;
    IMAGE_NT_HEADERS64 *nt=(IMAGE_NT_HEADERS64 *)(image+dos->e_lfanew);
    if(nt->Signature!=IMAGE_NT_SIGNATURE || nt->OptionalHeader.Magic!=IMAGE_NT_OPTIONAL_HDR64_MAGIC) return 3;
    DWORD rva=nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
    if(!rva) return 4;
    IMAGE_IMPORT_DESCRIPTOR *d=(IMAGE_IMPORT_DESCRIPTOR *)(image+rva);
    for(;d->Name;d++) {
        if(_stricmp((char *)(image+d->Name),"libcef.dll") || !d->OriginalFirstThunk) continue;
        IMAGE_THUNK_DATA64 *names=(IMAGE_THUNK_DATA64 *)(image+d->OriginalFirstThunk);
        IMAGE_THUNK_DATA64 *addresses=(IMAGE_THUNK_DATA64 *)(image+d->FirstThunk);
        for(;names->u1.AddressOfData;names++,addresses++) {
            if(IMAGE_SNAP_BY_ORDINAL64(names->u1.Ordinal)) continue;
            char *name=(char *)((IMAGE_IMPORT_BY_NAME *)(image+names->u1.AddressOfData))->Name;
            void *replacement=NULL;
            if(!strcmp(name,"cef_browser_host_create_browser")) replacement=sevo_create_browser_thunk;
            if(!strcmp(name,"cef_browser_host_create_browser_sync")) replacement=sevo_create_browser_sync_thunk;
            if(!replacement) continue;
            void *expected=(void *)GetProcAddress(original_module,name);
            if((void *)(uintptr_t)addresses->u1.Function!=expected) { InterlockedIncrement64(&stats->abi_rejected);continue; }
            DWORD protection,ignored;
            if(VirtualProtect(&addresses->u1.Function,sizeof(void *),PAGE_READWRITE,&protection)) {
                InterlockedExchangePointer((PVOID volatile *)&addresses->u1.Function,replacement);
                VirtualProtect(&addresses->u1.Function,sizeof(void *),protection,&ignored);
                InterlockedIncrement64(&stats->iat_hooks);
            } else { InterlockedIncrement64(&stats->abi_rejected); }
        }
    }
    return 0;
}
BOOL WINAPI DllMain(HINSTANCE module,DWORD reason,LPVOID reserved) {
    (void)reserved;
    if(reason==DLL_PROCESS_ATTACH) {
        this_module=module;
        DisableThreadLibraryCalls(module);
        /* No waits under loader lock. The worker runs after DLL attach returns. */
        HANDLE thread=CreateThread(NULL,0,attach_imports,NULL,0,NULL);
        if(thread) CloseHandle(thread);
    }
    return TRUE;
}
