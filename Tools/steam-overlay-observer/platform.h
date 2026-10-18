#ifndef SEVO_OBSERVER_PLATFORM_H
#define SEVO_OBSERVER_PLATFORM_H
#ifdef SEVO_OBSERVER_TEST
#include <pthread.h>
#include <time.h>
static pthread_mutex_t observer_lock = PTHREAD_MUTEX_INITIALIZER;
static _Thread_local unsigned long test_last_error;
static void obs_lock(void) { pthread_mutex_lock(&observer_lock); }
static void obs_unlock(void) { pthread_mutex_unlock(&observer_lock); }
static uint64_t obs_tick(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (uint64_t)t.tv_sec*1000+(uint64_t)t.tv_nsec/1000000; }
static unsigned long obs_error(void) { return test_last_error; }
static void obs_set_error(unsigned long n) { test_last_error=n; }
static int obs_readable(const void *p, size_t n) { (void)n; return p!=NULL; }
static int obs_writable(void *p) { return p!=NULL; }
static int obs_module_info(void *address, uintptr_t *base, uint64_t *size, char name[64]) {
    *base=(uintptr_t)address&~(uintptr_t)4095; *size=4096; strcpy(name,"test-fixture"); return 1;
}
#else
#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif
#include <windows.h>
static SRWLOCK observer_lock = SRWLOCK_INIT;
static void obs_lock(void) { AcquireSRWLockExclusive(&observer_lock); }
static void obs_unlock(void) { ReleaseSRWLockExclusive(&observer_lock); }
static uint64_t obs_tick(void) { return GetTickCount64(); }
static unsigned long obs_error(void) { return GetLastError(); }
static void obs_set_error(unsigned long n) { SetLastError(n); }
static int obs_readable(const void *p, size_t n) {
    MEMORY_BASIC_INFORMATION m;
    if(!p || !VirtualQuery(p,&m,sizeof(m)) || m.State!=MEM_COMMIT ||
       (m.Protect&(PAGE_GUARD|PAGE_NOACCESS))) return 0;
    uintptr_t at=(uintptr_t)p, end=(uintptr_t)m.BaseAddress+m.RegionSize;
    return at<=end && n<=end-at;
}
static int obs_writable(void *p) {
    MEMORY_BASIC_INFORMATION m;
    if(!VirtualQuery(p,&m,sizeof(m)) || m.State!=MEM_COMMIT || (m.Protect&PAGE_GUARD))return 0;
    return (m.Protect&(PAGE_READWRITE|PAGE_WRITECOPY|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY))!=0;
}
static int obs_module_info(void *address, uintptr_t *base, uint64_t *size, char name[64]) {
    HMODULE owner=NULL; wchar_t path[32768];
    if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,(LPCWSTR)address,&owner))return 0;
    DWORD n=GetModuleFileNameW(owner,path,32768); if(!n||n>=32768)return 0;
    const wchar_t *leaf=wcsrchr(path,L'\\'); leaf=leaf?leaf+1:path;
    size_t i=0;
    for(;i<63&&leaf[i];i++){name[i]=(leaf[i]>=32&&leaf[i]<127)?(char)leaf[i]:'?';}
    name[i]=0;
    const IMAGE_DOS_HEADER *dos=(const IMAGE_DOS_HEADER *)owner;
    const IMAGE_NT_HEADERS64 *nt=(const IMAGE_NT_HEADERS64 *)((const uint8_t *)owner+dos->e_lfanew);
    *base=(uintptr_t)owner; *size=nt->OptionalHeader.SizeOfImage;return 1;
}
#endif
#endif
