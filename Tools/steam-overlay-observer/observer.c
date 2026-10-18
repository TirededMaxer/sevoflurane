/* Exact-build, opt-in CEF metadata observer. No frame or input replacement. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include "observer.h"
#include "platform.h"
static obs_stats *stats;
static obs_create_fn create_original;
static obs_create_sync_fn create_sync_original;
static void OBS_ABI on_paint(void *,void *,int,size_t,const obs_rect *,const void *,int,int,const void *,float);
static void OBS_ABI on_gpu(void *,void *,int,size_t,const obs_rect *,const void *);
static void OBS_ABI on_title(void *,void *,const obs_string *);
static void *OBS_ABI get_render(void *);
static void *OBS_ABI get_display(void *);
static uint64_t count(enum obs_counter c) { return __atomic_add_fetch(&stats->counters[c],1,__ATOMIC_RELAXED); }
static void begin(void) { obs_lock();__atomic_add_fetch(&stats->sequence,1,__ATOMIC_SEQ_CST); }
static void end(void) { __atomic_add_fetch(&stats->sequence,1,__ATOMIC_SEQ_CST);obs_unlock(); }
static uint64_t module_for(void *fn,uint64_t *rva) {
    uintptr_t base=0;uint64_t size=0;char name[64]={0};*rva=0;
    if(!fn||!obs_module_info(fn,&base,&size,name))return 0;
    *rva=(uintptr_t)fn-base;
    for(uint64_t i=0;i<stats->module_count;i++){if(stats->modules[i].base==base)return i+1;}
    if(stats->module_count==OBS_MODULE_LIMIT){count(C_RECORDS_DROPPED);return 0;}
    uint64_t i=stats->module_count++;stats->modules[i].base=base;stats->modules[i].size=size;
    memcpy(stats->modules[i].name,name,sizeof(name));return i+1;
}
static obs_slot *slot_for(void *object,size_t offset,int add) {
    for(uint64_t i=0;i<stats->slot_count;i++){
        if(stats->slots[i].object==(uintptr_t)object&&stats->slots[i].offset==offset)return &stats->slots[i];
    }
    if(!add)return NULL;
    if(stats->slot_count==OBS_SLOT_LIMIT){count(C_RECORDS_DROPPED);return NULL;}
    obs_slot *s=&stats->slots[stats->slot_count++];s->object=(uintptr_t)object;s->offset=offset;return s;
}
static void *original_slot(void *object,size_t offset) {
    obs_lock();obs_slot *s=slot_for(object,offset,0);
    void *fn=s&&s->installed?(void *)(uintptr_t)s->original:NULL;obs_unlock();return fn;
}
static void patch_slot(void *object,size_t offset,void *replacement) {
    int valid=obs_readable(object,sizeof(size_t));size_t bytes=valid?*(size_t *)object:0;
    valid=valid&&bytes>=offset+sizeof(void *)&&bytes<=4096&&obs_readable(object,offset+sizeof(void *));
    void **address=valid?(void **)((uint8_t *)object+offset):NULL;
    begin();obs_slot *s=slot_for(object,offset,1);
    if(!s){count(C_SLOT_REJECTED);end();return;}
    if(!valid||!obs_writable(address)){s->rejected++;count(C_SLOT_REJECTED);count(C_ABI_REJECTED);end();return;}
    void *current=__atomic_load_n(address,__ATOMIC_SEQ_CST);
    if(current==replacement){
        if(s->installed&&s->original){s->already++;count(C_SLOT_ALREADY);}
        else{s->rejected++;count(C_SLOT_REJECTED);}
    }else if(!current){s->nulls++;count(C_SLOT_NULL);}
    else{
        s->original=(uintptr_t)current;s->module=module_for(current,&s->rva);
        if(__atomic_compare_exchange_n(address,&current,replacement,0,__ATOMIC_SEQ_CST,__ATOMIC_SEQ_CST)){
            s->installed++;count(C_SLOT_INSTALLED);
        }else{s->rejected++;count(C_SLOT_REJECTED);}
    }
    end();
}
static int identifier(void *browser) {
    if(!obs_readable(browser,0xe8)||*(size_t *)browser!=0xe8){count(C_BAD_BROWSER_ID);return 0;}
    obs_identifier_fn fn=*(obs_identifier_fn *)((uint8_t *)browser+OBS_BROWSER_ID);
    if(!fn){count(C_BAD_BROWSER_ID);return 0;}return fn(browser);
}
/* Stats are weak numeric identities only. No browser/handler reference is retained. */
static obs_browser *browser_for(void *browser,int id) {
    for(uint64_t i=0;i<stats->browser_count;i++){
        if(stats->browsers[i].browser==(uintptr_t)browser&&stats->browsers[i].cef_id==(uint64_t)(int64_t)id)return &stats->browsers[i];
    }
    if(stats->browser_count==OBS_BROWSER_LIMIT){count(C_RECORDS_DROPPED);return NULL;}
    obs_browser *b=&stats->browsers[stats->browser_count++];b->browser=(uintptr_t)browser;b->cef_id=(uint64_t)(int64_t)id;
    b->first_tick=obs_tick();return b;
}
static void note_handler(void *client,void *handler,int kind) {
    if(!handler)return;
    size_t bytes=obs_readable(handler,sizeof(size_t))?*(size_t *)handler:0;
    begin();int unique=1;
    for(uint64_t i=0;i<stats->handler_count;i++){
        obs_handler *h=&stats->handlers[i];
        if(h->handler==(uintptr_t)handler&&h->kind==(uint64_t)kind){unique=0;}
        if(h->client==(uintptr_t)client&&h->handler==(uintptr_t)handler&&h->kind==(uint64_t)kind){h->calls++;end();return;}
    }
    if(stats->handler_count==OBS_HANDLER_LIMIT){count(C_RECORDS_DROPPED);end();return;}
    obs_handler *h=&stats->handlers[stats->handler_count++];
    h->client=(uintptr_t)client;h->handler=(uintptr_t)handler;h->kind=(uint64_t)kind;h->base_size=bytes;h->calls=1;
    if(unique){count(C_UNIQUE_HANDLERS);}
    end();
}
static unsigned unit_at(const obs_string *s,size_t i,int wide) {
    return wide?((const uint16_t *)s->text)[i]:((const uint8_t *)s->text)[i];
}
static int overlay_identity(const obs_string *s,uint64_t values[3]) {
    static const char prefix[]="SP Overlay:";
    if(!obs_readable(s,sizeof(*s))||!s->text||s->length<sizeof(prefix)-1||s->length>96)return 0;
    if(!obs_readable(s->text,2))return 0;
    int wide=((const uint8_t *)s->text)[1]==0;
    if(!obs_readable(s->text,s->length*(wide?2:1)))return 0;
    size_t p=0;
    for(;p<sizeof(prefix)-1;p++){if(unit_at(s,p,wide)!=(unsigned char)prefix[p])return 0;}
    if(p<s->length&&unit_at(s,p,wide)==' '){p++;}
    for(int field=0;field<3;field++){
        uint64_t value=0;size_t start=p;
        while(p<s->length){unsigned c=unit_at(s,p,wide);if(c<'0'||c>'9')break;
            value=value*10+(c-'0');
            if(value>UINT32_MAX)return 0;
            p++;
        }
        if(p==start)return 0;
        values[field]=value;
        if(field<2){if(p==s->length||unit_at(s,p++,wide)!='/')return 0;}
    }
    return p==s->length;
}
static void OBS_ABI on_title(void *self,void *browser,const obs_string *title) {
    unsigned long error=obs_error();count(C_TITLE_ENTRIES);
    obs_title_fn original=(obs_title_fn)original_slot(self,OBS_DISPLAY_TITLE);
    if(!original){count(C_MISSING_ORIGINAL);obs_set_error(error);return;}
    int id=identifier(browser);uint64_t values[3];int match=overlay_identity(title,values);
    begin();obs_browser *b=browser_for(browser,id);
    if(b){b->display_handler=(uintptr_t)self;b->title_entries++;b->last_tick=obs_tick();if(match){b->overlay_match=1;b->game_pid=values[0];b->steam_browser_id=values[1];b->steam_browser_type=values[2];}}
    end();obs_set_error(error);original(self,browser,title);
}
static void note_paint(void *self,void *browser,int type,int gpu,int width,int height) {
    int id=identifier(browser);begin();obs_browser *b=browser_for(browser,id);
    if(b){b->render_handler=(uintptr_t)self;if(gpu)b->gpu_entries++;else{b->cpu_entries++;b->last_width=width;b->last_height=height;}
        if(type==0)b->view_entries++;else if(type==1)b->popup_entries++;else b->other_entries++;
        b->last_type=type;b->last_tick=obs_tick();}end();
}
static void OBS_ABI on_paint(void *self,void *browser,int type,size_t n,const obs_rect *rects,const void *pixels,int width,int height,const void *scroll,float scale) {
    unsigned long error=obs_error();count(C_CPU_ENTRIES);
    obs_paint_fn original=(obs_paint_fn)original_slot(self,OBS_RENDER_PAINT);
    if(!original){count(C_MISSING_ORIGINAL);obs_set_error(error);return;}
    note_paint(self,browser,type,0,width,height);obs_set_error(error);
    original(self,browser,type,n,rects,pixels,width,height,scroll,scale);
}
static void OBS_ABI on_gpu(void *self,void *browser,int type,size_t n,const obs_rect *rects,const void *opaque_info) {
    unsigned long error=obs_error();count(C_GPU_ENTRIES);
    obs_gpu_fn original=(obs_gpu_fn)original_slot(self,OBS_RENDER_ACCELERATED);
    if(!original){count(C_MISSING_ORIGINAL);obs_set_error(error);return;}
    note_paint(self,browser,type,1,0,0);obs_set_error(error);
    original(self,browser,type,n,rects,opaque_info);
}
static void *OBS_ABI get_render(void *self) {
    unsigned long before=obs_error();count(C_RENDER_GETTERS);
    obs_getter_fn original=(obs_getter_fn)original_slot(self,OBS_CLIENT_RENDER);
    if(!original){count(C_MISSING_ORIGINAL);obs_set_error(before);return NULL;}
    obs_set_error(before);void *handler=original(self);unsigned long after=obs_error();
    note_handler(self,handler,1);if(handler){patch_slot(handler,OBS_RENDER_PAINT,(void *)on_paint);patch_slot(handler,OBS_RENDER_ACCELERATED,(void *)on_gpu);}
    obs_set_error(after);return handler;
}
static void *OBS_ABI get_display(void *self) {
    unsigned long before=obs_error();count(C_DISPLAY_GETTERS);
    obs_getter_fn original=(obs_getter_fn)original_slot(self,OBS_CLIENT_DISPLAY);
    if(!original){count(C_MISSING_ORIGINAL);obs_set_error(before);return NULL;}
    obs_set_error(before);void *handler=original(self);unsigned long after=obs_error();
    note_handler(self,handler,2);
    if(handler){patch_slot(handler,OBS_DISPLAY_TITLE,(void *)on_title);}
    obs_set_error(after);return handler;
}
static uint64_t start_create(int sync,const void *window_info,void *client,const void *settings) {
    uint64_t call_sequence=count(C_CREATE_CALLS),index=UINT64_MAX;
    begin();if(stats->create_count<OBS_CREATE_LIMIT){
        index=stats->create_count++;obs_create *c=&stats->creates[index];
        c->sequence=call_sequence;c->sync=(uint64_t)sync;c->client=(uintptr_t)client;c->window_info=(uintptr_t)window_info;
        if(obs_readable(settings,sizeof(size_t)))c->settings_size=*(const size_t *)settings;
        if(obs_readable(window_info,0x64)){
            uint32_t v;memcpy(&v,(const uint8_t *)window_info+0x48,4);c->windowless=v;
            memcpy(&v,(const uint8_t *)window_info+0x4c,4);c->shared_texture=v;
            memcpy(&v,(const uint8_t *)window_info+0x50,4);c->external_begin_frame=v;
        }
    }else{count(C_RECORDS_DROPPED);}
    end();
    patch_slot(client,OBS_CLIENT_DISPLAY,(void *)get_display);patch_slot(client,OBS_CLIENT_RENDER,(void *)get_render);return index;
}
static void finish_create(uint64_t index,int sync,uint64_t result,void *browser) {
    count(sync?(browser?C_SYNC_NONNULL:C_SYNC_NULL):(result?C_ASYNC_ACCEPTED:C_ASYNC_REJECTED));
    int id=sync&&browser?identifier(browser):0;begin();
    if(index!=UINT64_MAX){obs_create *c=&stats->creates[index];c->result_known=1;c->result=result;c->returned_browser=(uintptr_t)browser;c->cef_id=(uint64_t)(int64_t)id;}
    if(sync&&browser){browser_for(browser,id);}
    end();
}
static int OBS_ABI create_browser(const void *info,void *client,const void *url,const void *settings,void *extra,void *context) {
    unsigned long before=obs_error();uint64_t index=start_create(0,info,client,settings);obs_set_error(before);
    int result=create_original(info,client,url,settings,extra,context);unsigned long after=obs_error();
    finish_create(index,0,(uint64_t)(int64_t)result,NULL);obs_set_error(after);return result;
}
static void *OBS_ABI create_browser_sync(const void *info,void *client,const void *url,const void *settings,void *extra,void *context) {
    unsigned long before=obs_error();uint64_t index=start_create(1,info,client,settings);obs_set_error(before);
    void *result=create_sync_original(info,client,url,settings,extra,context);unsigned long after=obs_error();
    finish_create(index,1,(uintptr_t)result,result);obs_set_error(after);return result;
}
#ifndef SEVO_OBSERVER_TEST
#include <bcrypt.h>
static HMODULE this_module;
static int loaded_cef_sha(HMODULE cef) {
    wchar_t path[32768];DWORD length=GetModuleFileNameW(cef,path,32768);if(!length||length>=32768)return 0;
    HANDLE file=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
    if(file==INVALID_HANDLE_VALUE)return 0;
    BCRYPT_ALG_HANDLE algorithm=NULL;BCRYPT_HASH_HANDLE hash=NULL;uint8_t bytes[65536],digest[32];char hex[65];DWORD n=0;int ok=0;
    if(BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,NULL,0)<0||BCryptCreateHash(algorithm,&hash,NULL,0,NULL,0,0)<0)goto done;
    for(;;){if(!ReadFile(file,bytes,sizeof(bytes),&n,NULL))goto done;if(!n)break;if(BCryptHashData(hash,bytes,n,0)<0)goto done;}
    if(BCryptFinishHash(hash,digest,sizeof(digest),0)<0)goto done;
    for(size_t i=0;i<32;i++){snprintf(hex+i*2,3,"%02x",digest[i]);}
    ok=!strcmp(hex,OBS_CEF_SHA);
done:
    if(hash){BCryptDestroyHash(hash);}
    if(algorithm){BCryptCloseAlgorithmProvider(algorithm,0);}
    CloseHandle(file);return ok;
}
static int create_stats(void) {
    wchar_t config[32768],directory[2048],output[2304];
    DWORD length=GetModuleFileNameW(this_module,config,32768);if(!length||length>=32768)return 0;
    wchar_t *slash=wcsrchr(config,L'\\');
    if(!slash)return 0;
    wcscpy(slash+1,L"observer.cfg");
    FILE *f=_wfopen(config,L"rb");
    if(!f)return 0;
    char line[4096]={0};size_t n=fread(line,1,sizeof(line)-1,f);fclose(f);
    while(n&&(line[n-1]=='\n'||line[n-1]=='\r'))line[--n]=0;
    if(!n||!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,line,-1,directory,2048))return 0;
    FILETIME created,exited,kernel,user;
    if(!GetProcessTimes(GetCurrentProcess(),&created,&exited,&kernel,&user))return 0;
    uint64_t process_start=((uint64_t)created.dwHighDateTime<<32)|created.dwLowDateTime;
    swprintf(output,2304,L"%ls\\observer-%lu-%llu.stats",directory,GetCurrentProcessId(),(unsigned long long)process_start);
    HANDLE file=CreateFileW(output,GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);
    if(file==INVALID_HANDLE_VALUE)return 0;
    HANDLE map=CreateFileMappingW(file,NULL,PAGE_READWRITE,0,sizeof(obs_stats),NULL);CloseHandle(file);if(!map)return 0;
    stats=MapViewOfFile(map,FILE_MAP_ALL_ACCESS,0,0,0);CloseHandle(map);if(!stats)return 0;
    memset(stats,0,sizeof(*stats));memcpy(stats->magic,OBS_MAGIC,8);stats->schema=OBS_SCHEMA;stats->bytes=sizeof(*stats);stats->pid=GetCurrentProcessId();stats->process_start=process_start;return 1;
}
static DWORD WINAPI attach_imports(LPVOID ignored) {
    (void)ignored;if(!create_stats())return 1;
    HMODULE cef=GetModuleHandleW(L"libcef.dll");if(!cef){stats->status=2;return 2;}
    typedef const char *(OBS_ABI *hash_fn)(int);
    hash_fn hash=(hash_fn)GetProcAddress(cef,"cef_api_hash");
    if(!loaded_cef_sha(cef)){stats->status=3;return 3;}
    if(!hash){stats->status=4;return 4;}
    const char *a=hash(0),*b=hash(1),*c=hash(2);
    if(!a||!b||!c||strcmp(a,OBS_HASH_PLATFORM)||strcmp(b,OBS_HASH_UNIVERSAL)||strcmp(c,OBS_HASH_COMMIT)){stats->status=4;return 4;}
    create_original=(obs_create_fn)GetProcAddress(cef,"cef_browser_host_create_browser");
    create_sync_original=(obs_create_sync_fn)GetProcAddress(cef,"cef_browser_host_create_browser_sync");
    if(!create_original||!create_sync_original){stats->status=5;return 5;}
    uint8_t *image=(uint8_t *)GetModuleHandleW(NULL);IMAGE_DOS_HEADER *dos=(IMAGE_DOS_HEADER *)image;
    if(dos->e_magic!=IMAGE_DOS_SIGNATURE){stats->status=6;return 6;}
    IMAGE_NT_HEADERS64 *nt=(IMAGE_NT_HEADERS64 *)(image+dos->e_lfanew);
    if(nt->Signature!=IMAGE_NT_SIGNATURE||nt->OptionalHeader.Magic!=IMAGE_NT_OPTIONAL_HDR64_MAGIC){stats->status=6;return 6;}
    DWORD rva=nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
    if(!rva){stats->status=7;return 7;}
    for(IMAGE_IMPORT_DESCRIPTOR *d=(IMAGE_IMPORT_DESCRIPTOR *)(image+rva);d->Name;d++){
        if(_stricmp((char *)image+d->Name,"libcef.dll")||!d->OriginalFirstThunk)continue;
        IMAGE_THUNK_DATA64 *names=(IMAGE_THUNK_DATA64 *)(image+d->OriginalFirstThunk),*addresses=(IMAGE_THUNK_DATA64 *)(image+d->FirstThunk);
        for(;names->u1.AddressOfData;names++,addresses++){
            if(IMAGE_SNAP_BY_ORDINAL64(names->u1.Ordinal))continue;
            char *name=(char *)((IMAGE_IMPORT_BY_NAME *)(image+names->u1.AddressOfData))->Name;
            void *replacement=NULL,*expected=NULL;
            if(!strcmp(name,"cef_browser_host_create_browser")){replacement=(void *)create_browser;expected=(void *)create_original;}
            else if(!strcmp(name,"cef_browser_host_create_browser_sync")){replacement=(void *)create_browser_sync;expected=(void *)create_sync_original;}
            if(!replacement)continue;
            if((void *)(uintptr_t)addresses->u1.Function==replacement){count(C_IAT_ALREADY);continue;}
            if((void *)(uintptr_t)addresses->u1.Function!=expected){count(C_ABI_REJECTED);continue;}
            DWORD protection,old;
            if(!VirtualProtect(&addresses->u1.Function,sizeof(void *),PAGE_READWRITE,&protection)){count(C_ABI_REJECTED);continue;}
            void *found=InterlockedCompareExchangePointer((PVOID volatile *)&addresses->u1.Function,replacement,expected);
            if(found==expected)count(C_IAT_INSTALLED);else count(C_ABI_REJECTED);
            if(!VirtualProtect(&addresses->u1.Function,sizeof(void *),protection,&old))count(C_ABI_REJECTED);
        }
    }
    if(!__atomic_load_n(&stats->counters[C_IAT_INSTALLED],__ATOMIC_RELAXED)&&!__atomic_load_n(&stats->counters[C_IAT_ALREADY],__ATOMIC_RELAXED)){count(C_IAT_MISSING);stats->status=7;return 7;}
    __atomic_store_n(&stats->ready,1,__ATOMIC_RELEASE);return 0;
}
BOOL WINAPI DllMain(HINSTANCE module,DWORD reason,LPVOID reserved) {
    (void)reserved;if(reason==DLL_PROCESS_ATTACH){this_module=module;DisableThreadLibraryCalls(module);
        HANDLE thread=CreateThread(NULL,0,attach_imports,NULL,0,NULL);if(thread)CloseHandle(thread);}
    return TRUE;
}
#endif
