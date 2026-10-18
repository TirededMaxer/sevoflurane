#ifndef SEVO_OVERLAY_CPP_OBSERVER_H
#define SEVO_OVERLAY_CPP_OBSERVER_H
#include <stdint.h>
#include <stddef.h>
#ifdef SEVO_OBSERVER_TEST
#if !defined(__x86_64__)
#error The C++ callback fixture requires Microsoft x64 ABI coverage
#endif
#define CPP_ABI __attribute__((ms_abi))
#else
#define CPP_ABI __cdecl
#endif
_Static_assert(sizeof(void *)==8,"The C++ observer requires Windows x64");
#define CPP_MAGIC "SEVOCPP1"
#define CPP_SCHEMA 1
#define CPP_HELPER_SHA "5ee6df1a5a2237dd3efb7d7042b02ba20f2238ba15d961b1a10ef6d575c59362"
#define CPP_IMAGE_BYTES UINT64_C(7651328)
#define CPP_CPU_SLOT_RVA UINT64_C(0x4a0ab0)
#define CPP_GPU_SLOT_RVA UINT64_C(0x4a0ab8)
#define CPP_CPU_RVA UINT64_C(0x11a040)
#define CPP_GPU_RVA UINT64_C(0x119cb0)
#define CPP_PAINTER_LIMIT 128
/* Browser refs, vectors, pixels, scroll data and accelerated info stay opaque.
 * This is the custom Steam ABI observed at 2f9ca2 / 2f96a0, not upstream CEF. */
typedef void (CPP_ABI *cpp_cpu_fn)(void *, void *, int, const void *, const void *, int, int, const void *, float);
typedef void (CPP_ABI *cpp_gpu_fn)(void *, void *, int, const void *, const void *);
enum cpp_counter {
    CPP_CPU_ENTRIES, CPP_GPU_ENTRIES, CPP_MISSING_ORIGINAL, CPP_NATIVE_ID_UNREADABLE,
    CPP_RECORDS_DROPPED, CPP_SLOT_INSTALLED, CPP_SLOT_ALREADY, CPP_SLOT_REJECTED,
    CPP_ROLLBACK_FAILED, CPP_COUNTER_COUNT
};
typedef struct {
    uint64_t slot_rva, expected_rva, original, observed, installed, rejected;
} cpp_slot;
typedef struct {
    uint64_t painter, native_browser_id, identity_valid, cpu_entries, gpu_entries,
        view_entries, popup_entries, other_entries;
    int64_t last_width, last_height, last_type;
    uint64_t first_tick, last_tick;
} cpp_painter;
typedef struct {
    char magic[8];
    uint64_t schema, bytes, pid, process_start, ready, status, sequence;
    uint64_t counters[CPP_COUNTER_COUNT];
    uint64_t slot_count, painter_count, helper_base, image_bytes;
    cpp_slot slots[2];
    cpp_painter painters[CPP_PAINTER_LIMIT];
} cpp_stats;
_Static_assert(offsetof(cpp_stats,counters)==64,"C++ stats header ABI changed");
_Static_assert(sizeof(cpp_stats)==13576,"Update the controller C++ schema");
#endif
