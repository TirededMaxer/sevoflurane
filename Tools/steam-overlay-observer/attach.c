/* Windows x64 only: attach the opt-in metadata observer to an exact helper path. */
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0601
#include <windows.h>
#include <tlhelp32.h>
#include <stdint.h>
#include <stdio.h>
#include <wchar.h>
_Static_assert(sizeof(void *) == 8, "The helper attacher requires Windows x64");
typedef BOOL (WINAPI *wow64_process2_fn)(HANDLE, USHORT *, USHORT *);
typedef struct { const char *state; DWORD error, wait, exit_code; int loaded, retained, started; } result;
static int absolute_path(const wchar_t *p) {
    return p && ((p[0] && p[1] == L':' && (p[2] == L'\\' || p[2] == L'/')) || (p[0] == L'\\' && p[1] == L'\\'));
}
static int same_path(const wchar_t *a, const wchar_t *b) {
    return CompareStringOrdinal(a, -1, b, -1, TRUE) == CSTR_EQUAL;
}
static int full_path(const wchar_t *input, wchar_t *output) {
    if (!absolute_path(input)) return 0;
    DWORD n = GetFullPathNameW(input, 32768, output, NULL);
    return n && n < 32768;
}
static int helper_path(HANDLE process, const wchar_t *target, DWORD *error) {
    wchar_t path[32768]; DWORD n = 32768;
    if (!QueryFullProcessImageNameW(process, 0, path, &n)) { *error = GetLastError(); return -1; }
    return same_path(path, target);
}
static int amd64_process(HANDLE process, DWORD *error) {
    HMODULE kernel = GetModuleHandleW(L"kernel32.dll");
    wow64_process2_fn query = (wow64_process2_fn)GetProcAddress(kernel, "IsWow64Process2");
    if (query) {
        USHORT machine = 0, native = 0;
        if (!query(process, &machine, &native)) { *error = GetLastError(); return 0; }
        if (machine == IMAGE_FILE_MACHINE_AMD64 || (!machine && native == IMAGE_FILE_MACHINE_AMD64)) return 1;
    } else {
        BOOL wow64 = FALSE; SYSTEM_INFO info;
        if (!IsWow64Process(process, &wow64)) { *error = GetLastError(); return 0; }
        GetNativeSystemInfo(&info);
        if (!wow64 && info.wProcessorArchitecture == PROCESSOR_ARCHITECTURE_AMD64) return 1;
    }
    *error = ERROR_BAD_EXE_FORMAT; return 0;
}
/* Snapshot once: module name is used for the loader owner; full path for load verification. */
static uintptr_t remote_module(DWORD pid, const wchar_t *name, int full, DWORD *size, DWORD *error) {
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
    if (snapshot == INVALID_HANDLE_VALUE) { *error = GetLastError(); return 0; }
    MODULEENTRY32W module = {0}; module.dwSize = sizeof(module);
    uintptr_t base = 0; BOOL ok = Module32FirstW(snapshot, &module);
    while (ok) {
        if (same_path(full ? module.szExePath : module.szModule, name)) {
            base = (uintptr_t)module.modBaseAddr; *size = module.modBaseSize; break;
        }
        ok = Module32NextW(snapshot, &module);
    }
    if (!base) { DWORD e = GetLastError(); *error = e && e != ERROR_NO_MORE_FILES ? e : ERROR_MOD_NOT_FOUND; }
    CloseHandle(snapshot); return base;
}
static int allowed_observer_leaf(const wchar_t *leaf) {
    return same_path(leaf, L"sevo-overlay-observer.dll") ||
           same_path(leaf, L"sevo-overlay-cpp-observer.dll");
}
static result attach(DWORD pid, const wchar_t *target, const wchar_t *dll, const wchar_t *leaf) {
    result r = {"open_failed", 0, WAIT_FAILED, 0, 0, 0, 0};
    HANDLE process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_CREATE_THREAD | PROCESS_VM_OPERATION |
                                 PROCESS_VM_WRITE | PROCESS_VM_READ, FALSE, pid);
    if (!process) { r.error = GetLastError(); return r; }
    HANDLE thread = NULL; void *remote = NULL; int safe_to_free = 1;
    int match = helper_path(process, target, &r.error);
    if (match != 1) { r.state = match < 0 ? "query_failed" : "path_changed"; if (!r.error) r.error = ERROR_INVALID_NAME; goto done; }
    if (!amd64_process(process, &r.error)) { r.state = "architecture_rejected"; goto done; }
    DWORD prior_size = 0, prior_error = 0;
    if (remote_module(pid, dll, 1, &prior_size, &prior_error)) {
        r.state = "already_loaded"; r.loaded = 1; r.error = 0; goto done;
    }
    if (prior_error != ERROR_MOD_NOT_FOUND) { r.state = "module_query_failed"; r.error = prior_error; goto done; }
    if (remote_module(pid, leaf, 0, &prior_size, &prior_error)) {
        r.state = "other_session_loaded"; r.error = ERROR_ALREADY_EXISTS; goto done;
    }
    if (prior_error != ERROR_MOD_NOT_FOUND) { r.state = "module_query_failed"; r.error = prior_error; goto done; }
    FARPROC loader = GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "LoadLibraryW");
    HMODULE owner = NULL; wchar_t owner_path[MAX_PATH];
    if (!loader || !GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                                       (LPCWSTR)(uintptr_t)loader, &owner)) { r.state = "loader_owner_failed"; r.error = GetLastError(); goto done; }
    DWORD n = GetModuleFileNameW(owner, owner_path, MAX_PATH);
    if (!n || n >= MAX_PATH) { r.state = "loader_owner_failed"; r.error = n ? ERROR_INSUFFICIENT_BUFFER : GetLastError(); goto done; }
    const wchar_t *owner_name = wcsrchr(owner_path, L'\\'); owner_name = owner_name ? owner_name + 1 : owner_path;
    DWORD remote_size = 0; uintptr_t base = remote_module(pid, owner_name, 0, &remote_size, &r.error);
    uintptr_t offset = (uintptr_t)loader - (uintptr_t)owner;
    if (!base || (uintptr_t)loader < (uintptr_t)owner || offset >= remote_size || base > UINTPTR_MAX - offset) {
        r.state = "remote_loader_unresolved"; if (!r.error) r.error = ERROR_INVALID_ADDRESS; goto done;
    }
    SIZE_T bytes = (wcslen(dll) + 1) * sizeof(wchar_t), written = 0;
    remote = VirtualAllocEx(process, NULL, bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!remote) { r.state = "allocate_failed"; r.error = GetLastError(); goto done; }
    BOOL wrote = WriteProcessMemory(process, remote, dll, bytes, &written);
    if (!wrote || written != bytes) {
        r.state = "write_failed"; r.error = wrote ? ERROR_PARTIAL_COPY : GetLastError(); goto done;
    }
    thread = CreateRemoteThread(process, NULL, 0, (LPTHREAD_START_ROUTINE)(base + offset), remote, 0, NULL);
    if (!thread) { r.state = "thread_create_failed"; r.error = GetLastError(); goto done; }
    r.started = 1;
    safe_to_free = 0; r.wait = WaitForSingleObject(thread, 5000);
    if (r.wait != WAIT_OBJECT_0) {
        r.state = r.wait == WAIT_TIMEOUT ? "loader_timeout" : "wait_failed";
        r.error = r.wait == WAIT_TIMEOUT ? WAIT_TIMEOUT : GetLastError(); r.retained = 1; goto done;
    }
    safe_to_free = 1;
    if (!GetExitCodeThread(thread, &r.exit_code)) { r.state = "exit_code_failed"; r.error = GetLastError(); goto done; }
    /* A DWORD exit code truncates the 64-bit HMODULE; verify the module instead. */
    if (!remote_module(pid, dll, 1, &remote_size, &r.error)) { r.state = "load_not_verified"; goto done; }
    r.state = "loaded"; r.loaded = 1; r.error = 0;
 done:
    if (remote && safe_to_free && !VirtualFreeEx(process, remote, 0, MEM_RELEASE)) {
        r.retained = 1; if (!r.error) r.error = GetLastError();
    }
    if (thread) CloseHandle(thread);
    CloseHandle(process); return r;
}
int wmain(int argc, wchar_t **argv) {
    FILE *out = stdout;
    if (argc == 4) {
        out = _wfopen(argv[3], L"wb");
        if (!out) { printf("{\"stage\":\"output_open\",\"error\":%lu,\"results\":[]}\n", GetLastError()); return 2; }
    }
    wchar_t target[32768], dll[32768]; DWORD error = 0, matched = 0, loaded = 0, candidates = 0; int comma = 0;
    if ((argc != 3 && argc != 4) || !full_path(argv[1], target) || !full_path(argv[2], dll) || wcslen(dll) >= MAX_PATH) {
        error = ERROR_INVALID_PARAMETER; goto invalid;
    }
    const wchar_t *name = wcsrchr(target, L'\\');
    if (!name || !same_path(name + 1, L"steamwebhelper.exe")) { error = ERROR_INVALID_NAME; goto invalid; }
    name = wcsrchr(dll, L'\\');
    if (!name || !allowed_observer_leaf(name + 1)) { error = ERROR_INVALID_NAME; goto invalid; }
    const wchar_t *leaf = name + 1;
    DWORD attributes = GetFileAttributesW(dll);
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY)) {
        error = attributes == INVALID_FILE_ATTRIBUTES ? GetLastError() : ERROR_DIRECTORY; goto invalid;
    }
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) { error = GetLastError(); goto invalid; }
    fprintf(out, "{\"version\":1,\"results\":[");
    PROCESSENTRY32W entry = {0}; entry.dwSize = sizeof(entry); BOOL ok = Process32FirstW(snapshot, &entry);
    while (ok) {
        if (same_path(entry.szExeFile, L"steamwebhelper.exe")) {
            DWORD query_error = 0; HANDLE query = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, entry.th32ProcessID);
            int match = query ? helper_path(query, target, &query_error) : -1;
            if (!query) query_error = GetLastError();
            if (query) CloseHandle(query);
            if (match == 1 || match < 0) {
                result r = {"query_failed", query_error, WAIT_FAILED, 0, 0, 0, 0}; candidates++;
                if (match == 1) { matched++; r = attach(entry.th32ProcessID, target, dll, leaf); loaded += r.loaded; }
                fprintf(out, "%s{\"pid\":%lu,\"status\":\"%s\",\"error\":%lu,\"wait_result\":%lu,\"thread_exit_code\":%lu,\"loaded_verified\":%s,\"remote_path_retained\":%s,\"loader_thread_started\":%s}",
                        comma ? "," : "", entry.th32ProcessID, r.state, r.error, r.wait, r.exit_code, r.loaded ? "true" : "false", r.retained ? "true" : "false", r.started ? "true" : "false"); comma = 1;
            }
        }
        ok = Process32NextW(snapshot, &entry);
    }
    error = GetLastError(); if (error == ERROR_NO_MORE_FILES) error = 0;
    CloseHandle(snapshot);
    fprintf(out, "],\"matched\":%lu,\"loaded\":%lu,\"error\":%lu}\n", matched, loaded, error);
    if (out != stdout) { int failed = ferror(out); if (fclose(out)) failed = 1; if (failed) return 2; }
    else if (fflush(out)) return 2;
    return !error && matched && loaded == candidates ? 0 : 1;
 invalid:
    fprintf(out, "{\"stage\":\"arguments_or_enumeration\",\"error\":%lu,\"results\":[]}\n", error);
    if (out != stdout) { fclose(out); }
    return 2;
}
