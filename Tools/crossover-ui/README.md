# CrossOver UI compatibility

Sevoflurane's managed engine supplies a driver shim that prevents Steam's Windows UI from appearing. The CrossOver launch path does not load that shim. The JavaScript popup sweep can only hide CEF windows after they appear, and the tray-host cleanup runs after login. Native Steam error dialogs are outside that sweep.

This patch adds the same window-ordering boundary directly to an existing CrossOver 26.3 driver. It also skips native status-item creation and foreground activation for the selected infrastructure processes. `NSWindowOut` still reaches AppKit so closing and teardown work normally.

Suppression requires both `SEVO_OWNER_PID` (set by the existing Sevoflurane daemon) and `CX_HIDE_STEAM_DOCK=1` (the user's existing bottle opt-in). Process names are matched after Wine has assigned the Windows executable path, using either separator and case-insensitive complete names. Games, arbitrary programs, and CrossOver launches without a Sevoflurane owner keep their windows and status items. `SteamSetup.exe` is deliberately left interactive.

The patch targets the current local CrossOver 26.3 input/presentation build, including its existing Steam Dock patch. Apply the matching COEditor Wine patch before using this compatibility patch. It does not install a different engine, change registry settings, or replace the app/helper signature.

## Build and verify

On macOS, with Xcode installed and the matching Wine source/build folders:

```sh
python3 Tools/crossover-ui/build-driver.py \
  --wine-source /path/to/patched-wine-source \
  --wine-build /path/to/matching-wine-build \
  --output /path/to/new-output-folder \
  --test
```

The script stages only the affected sources, applies the patch, recompiles three Cocoa objects, and uses the matching build's object list and flags. It checks exported symbols and the ad-hoc signature. It leaves the source, existing build products, and installed runtime untouched. `--test` runs process-scope checks plus 31 real AppKit window/tray assertions; the AppKit checks require a desktop session and briefly create test windows.

With all bottle programs stopped, back up the installed `winemac.so` before replacing it with this output in the same matched runtime. If a local component-maintenance manifest is in use, back up and update its payload and checksum together. Never install the driver into another Wine version or an unmatched input ABI.

## Diagnostics and validation

Suppressed window and status-item requests append to `~/Library/Logs/Sevoflurane-windows.log`, with the executable, PID, operation, window title and size. This preserves a record when a Steam dialog is hidden; it does not recover the dialog's child text or fix its underlying network/game-launch error. Sevoflurane's normal client and game diagnostics still apply.

Local verification on 2026-10-17:

- Release driver compiled; exported symbols unchanged; signature verified.
- Process-scope tests and 31 AppKit checks passed, including Steam error-reporter windows, the tray, normal CrossOver, and game windows.
- Actual boot recorded suppression of the Windows Steam login window and two explorer tray requests. The native Sevoflurane account page rendered, then the real CS2 window appeared.
- The app, helper, bottle configuration, `ntdll`, `win32u`, graphics components, and existing physical-wheel reader remained unchanged. The new game log still recorded the physical wheel reader opening.
- The user's intermittent original garbled error window has not yet recurred during this verification. Its underlying failure cause remains unconfirmed.

The ordering approach and infrastructure list follow [Dormison's dock shim](https://github.com/kageroumado/dormison/blob/main/build-macos/dock-shim/sevo_dock_shim.c). Changes to Wine sources remain under the Wine source files' LGPL-2.1-or-later terms; see `COPYING.LIB`.
