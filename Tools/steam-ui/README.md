# Original standard Win32 dialog bridge

The helper observes Steam/Steam error-reporter windows in the exact managed Steam
installation directory. CEF helpers and games are excluded. Existing Steam HTML
popups already use their original document in the normal WebKit host; this bridge
is only for readable standard Win32 child controls.

`NativeSteamDialogs` observes original HWND/PID and client/frame geometry, text,
control order/IDs/rectangles, enabled/default/check/progress state, original HFONT
metrics, control colors, system colors and icon resources. A borderless AppKit
panel hosts WebKit vector text and standard Windows control primitives. No
NSAlert, NSButton, NSTextField or macOS restyling is used. Fonts are read through
an exact URL allowlist under the chosen bottle's Fonts directory; no fonts are
installed, downloaded or uploaded. Password edit contents are never scanned.

The original process remains authoritative. Buttons receive BM_CLICK, closing
requests WM_CLOSE, focus goes through WM_NEXTDLGCTL and edits through bounded WM_SETTEXT.
Every operation rechecks process image directory, PID, descendant HWND, class and
enabled/visible state. Text is carried in a short-lived mode-0600 UTF-16 file,
not a command-line argument. Default/Cancel/Tab and IME editing preserve the
original control identity. Only disappearance of the original window dismisses
its host. No process is terminated and no new Win32 hiding is introduced.

Original owner HWND and enabled state drive `modalityDidChange`; the application
must block its Steam host inputs while the original owner is disabled and restore
them when the original dialog disappears. Existing driver-wide infrastructure
window suppression is independent of this bridge.

Supported: readable Static text/icons, standard push/check/radio/group buttons,
Edit and progress controls. Owner-drawn VGUI surfaces, list/tree/combo controls,
custom themes, accessibility providers and arbitrary custom painting are not
reconstructed. Unsupported types are diagnosed without inventing visible text;
this is not a claim of pixel equivalence for those windows. Windows classic
primitives use original coordinates, fonts, control colors and system palette;
custom Windows theme rendering is not copied. Bitmap icon resources retain their
source resolution; text is not a screenshot and renders at display backing scale.

Build only with `Tools/steam-ui/build-cloud.sh` on the fresh GitHub Apple Silicon
runner. Output: `$RUNNER_TEMP/sevo-steam-ui/sevo-steam-ui.exe`, copied into the app's
`Contents/Resources/SteamUI/sevo-steam-ui.exe` by packaging. The executable is not
stored in Git. Dedicated app tests exercise the real WebKit document and original
control action protocol; actual Steam error/game acceptance remains a separate
runtime check.

Protocol, via the daemon-owned bottle only:

```
sevo-steam-ui.exe --steam-root C:\...\Steam
sevo-steam-ui.exe --steam-root C:\...\Steam control HWND PID CHILD click
sevo-steam-ui.exe --steam-root C:\...\Steam control HWND PID CHILD focus
sevo-steam-ui.exe --steam-root C:\...\Steam control HWND PID CHILD text-file UTF16_PATH
sevo-steam-ui.exe --steam-root C:\...\Steam answer HWND PID BUTTON_ID
```

BUTTON_ID zero requests original WM_CLOSE if WS_SYSMENU permits it. An optional
`--fixture` command supplies a local synthetic Win32 callback fixture; it is not a
real Steam error acceptance result. It still requires the explicit root argument.
