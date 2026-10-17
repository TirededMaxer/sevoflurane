/* Keep Steam/CEF startup free of the overlay's AppKit/Metal dependencies.
 * Only the target game's initialized Wine process loads the renderer. */
#include <dispatch/dispatch.h>
#include <crt_externs.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdio.h>
#include <unistd.h>
#include <limits.h>
static int loaded;
static void loadRenderer(void) {
    if (loaded) return;
    char **args = *_NSGetArgv();
    const char *name = args && args[0] ? args[0] : "";
    for (const char *at = name; *at; ++at) if (*at == '/' || *at == '\\') name = at + 1;
    if (strcasecmp(name, "cs2.exe")) return;
    Dl_info info;
    if (!dladdr((void *)loadRenderer, &info) || !info.dli_fname) return;
    char path[PATH_MAX];
    strlcpy(path, info.dli_fname, sizeof(path));
    char *leaf = strrchr(path, '/');
    if (!leaf) return;
    strlcpy(leaf + 1, "SevoOverlayRenderer.dylib", sizeof(path) - (leaf + 1 - path));
    if (dlopen(path, RTLD_NOW | RTLD_LOCAL)) loaded = 1;
    else fprintf(stderr, "[SevoOverlay] game renderer could not load: %s\n", dlerror());
}
__attribute__((constructor)) static void bootstrap(void) {
    if (!getenv("SEVO_OVERLAY_BRIDGE")) return;
    for (int i = 0; i < 40; ++i) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ loadRenderer(); });
    }
}
