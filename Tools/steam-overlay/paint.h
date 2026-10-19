#ifndef SEVO_STEAM_PAINT_H
#define SEVO_STEAM_PAINT_H
#include <stdint.h>
#define CPP_ABI __attribute__((ms_abi))
#define CPP_HELPER_SHA "5ee6df1a5a2237dd3efb7d7042b02ba20f2238ba15d961b1a10ef6d575c59362"
#define CPP_IMAGE_BYTES 7651328u
#define CPP_CPU_SLOT_RVA 0x4a0ab0u
#define CPP_CPU_RVA 0x11a040u
typedef void (CPP_ABI *cpp_cpu_fn)(void *,void *,int,const void *,const void *,int,int,const void *,float);
#endif
