#ifndef SEVO_OVERLAY_OBSERVER_H
#define SEVO_OVERLAY_OBSERVER_H
#include <stdint.h>
#include <stddef.h>
#if defined(SEVO_OBSERVER_TEST)
#if !defined(__x86_64__)
#error The ABI fixture must compile for x86_64; do not skip Microsoft ABI coverage
#endif
#define OBS_ABI __attribute__((ms_abi))
#else
#define OBS_ABI __cdecl
#endif
#define OBS_MAGIC "SEVOOBS1"
#define OBS_SCHEMA 1
#define OBS_CREATE_LIMIT 64
#define OBS_HANDLER_LIMIT 128
#define OBS_SLOT_LIMIT 256
#define OBS_BROWSER_LIMIT 128
#define OBS_MODULE_LIMIT 32
#define OBS_CEF_SHA "c85bf94462b3c79baeac63823db52d15e116eead71ea414e5d3a112c59e434d3"
#define OBS_HASH_PLATFORM "97314fe45c14007fca596262a64cad69467df21f"
#define OBS_HASH_UNIVERSAL "908f7378d71977393cee4bc349055b7365c3673c"
#define OBS_HASH_COMMIT "bbb75964a9f4095daf2926163a63cbf11af56565"
#define OBS_CLIENT_DISPLAY 0x48
#define OBS_CLIENT_RENDER 0xa8
#define OBS_DISPLAY_TITLE 0x30
#define OBS_RENDER_PAINT 0x60
#define OBS_RENDER_ACCELERATED 0x68
#define OBS_BROWSER_ID 0x78
enum obs_counter {
    C_CREATE_CALLS, C_ASYNC_ACCEPTED, C_ASYNC_REJECTED, C_SYNC_NONNULL, C_SYNC_NULL,
    C_RENDER_GETTERS, C_DISPLAY_GETTERS, C_UNIQUE_HANDLERS, C_TITLE_ENTRIES,
    C_CPU_ENTRIES, C_GPU_ENTRIES, C_MISSING_ORIGINAL, C_BAD_BROWSER_ID,
    C_ABI_REJECTED, C_SLOT_INSTALLED, C_SLOT_ALREADY, C_SLOT_NULL, C_SLOT_REJECTED,
    C_IAT_INSTALLED, C_IAT_ALREADY, C_IAT_MISSING, C_RECORDS_DROPPED, OBS_COUNTER_COUNT
};
typedef struct { uint64_t sequence, sync, client, window_info, settings_size,
    windowless, shared_texture, external_begin_frame, result_known, result,
    returned_browser, cef_id; } obs_create;
typedef struct { uint64_t client, handler, kind, base_size, calls; } obs_handler;
typedef struct { uint64_t object, offset, original, module, rva,
    installed, already, nulls, rejected; } obs_slot;
typedef struct { uint64_t browser, cef_id, render_handler, display_handler, title_entries, overlay_match, game_pid,
    steam_browser_id, steam_browser_type, cpu_entries, gpu_entries,
    view_entries, popup_entries, other_entries; int64_t last_width, last_height, last_type;
    uint64_t first_tick, last_tick; } obs_browser;
typedef struct { uint64_t base, size; char name[64]; } obs_module;
typedef struct {
    char magic[8];
    uint64_t schema, bytes, pid, process_start, ready, status, sequence;
    uint64_t counters[OBS_COUNTER_COUNT];
    uint64_t create_count, handler_count, slot_count, browser_count, module_count;
    obs_create creates[OBS_CREATE_LIMIT];
    obs_handler handlers[OBS_HANDLER_LIMIT];
    obs_slot slots[OBS_SLOT_LIMIT];
    obs_browser browsers[OBS_BROWSER_LIMIT];
    obs_module modules[OBS_MODULE_LIMIT];
} obs_stats;
_Static_assert(offsetof(obs_stats,counters)==64,"Stats header ABI changed");
_Static_assert(sizeof(obs_stats)==51992,"Update the controller schema when changing records");
typedef struct { const void *text; size_t length; void *destructor; } obs_string;
typedef struct { int x, y, width, height; } obs_rect;
typedef void *(OBS_ABI *obs_getter_fn)(void *);
typedef int (OBS_ABI *obs_identifier_fn)(void *);
typedef int (OBS_ABI *obs_create_fn)(const void *, void *, const void *, const void *, void *, void *);
typedef void *(OBS_ABI *obs_create_sync_fn)(const void *, void *, const void *, const void *, void *, void *);
/* Steam's on_paint has two additional parameters absent from upstream CEF6478. */
typedef void (OBS_ABI *obs_paint_fn)(void *, void *, int, size_t, const obs_rect *, const void *, int, int, const void *, float);
typedef void (OBS_ABI *obs_gpu_fn)(void *, void *, int, size_t, const obs_rect *, const void *);
typedef void (OBS_ABI *obs_title_fn)(void *, void *, const obs_string *);
#endif
