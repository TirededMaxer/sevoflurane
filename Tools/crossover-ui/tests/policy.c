#include <assert.h>
#include <stdio.h>
#include "sevo_ui_policy.h"
int main(int argc, char **argv)
{
    char *original = argv[0];
    const char *names[] = {"steam.exe", "C:\\Program Files (x86)\\Steam\\steamwebhelper.exe", "/tmp/StEaMeRrOrRePoRtEr64.ExE", "explorer.exe", "wineboot.exe"};
    unsigned index;
    (void)argc;
    setenv("CX_HIDE_STEAM_DOCK", "1", 1);
    unsetenv("SEVO_OWNER_PID");
    argv[0] = "steam.exe";
    assert(!sevo_ui_policy());
    setenv("SEVO_OWNER_PID", "123", 1);
    for (index = 0; index < sizeof(names) / sizeof(names[0]); ++index)
    {
        argv[0] = (char *)names[index];
        assert(sevo_ui_policy());
    }
    argv[0] = "cs2.exe";
    assert(!sevo_ui_policy());
    argv[0] = "my-steam.exe";
    assert(!sevo_ui_policy());
    argv[0] = "sevo-ui-probe.exe";
    assert(!sevo_ui_policy());
    unsetenv("CX_HIDE_STEAM_DOCK");
    argv[0] = "steam.exe";
    assert(!sevo_ui_policy());
    argv[0] = original;
    puts("PASS: scoped Steam suppression, Windows and Unix paths, case matching, normal CrossOver and games preserved");
    return 0;
}
