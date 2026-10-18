# Original Steam painter experiment

This is an opt-in feasibility experiment for the exact Windows x64 Steam CEF recorded in `cef-abi-evidence.json`. It is not a finished WebKit overlay. App launch does not install or enable it.

`libcef.dll` forwards the complete 222-export original surface to `sevo_libcef_original.dll`. Only the two browser-creation entrypoints inspect the client handler slots. x64 tail thunks preserve all creation and accelerated-paint arguments. CPU painting retains Valve's ten-argument callback, including its custom scroll-offset pointer and page scale. The original handler object, reference-counting, game renderer, activation, hotkeys and input remain Steam's.

Observation mode records counts, dimensions, numeric browser IDs and ABI rejection only. Titles are checked for the original `SP Overlay:` prefix; title text, keystrokes and messages are not recorded. Normal paints call the original callback with the original arguments. Only an explicit `arm` request supplies one WebKit test-card frame, at the exact observed dimensions. A full dirty rectangle restores original pixels on the next original repaint. The request is consumed once. This does not prove continuous performance, GPU sharing or full WebKit input integration.

The CPU frame is generated once with WebKit's snapshot API solely to validate the original consumer boundary. It is not a revived continuous screenshot/Metal overlay. An accelerated-only client is observed without forcing CPU rendering; frame replacement refuses to arm until an actual CPU overlay paint is recorded.

All compilation and checks run in the fresh Apple Silicon release workflow. `probe-manifest.json` binds the generated proxy and native fixture to the source. The original CEF API hashes and struct-size checks guard the callbacks, and installation requires the exact original DLL SHA. CEF updates require fresh ABI calibration.

## Local test procedure

The cloud-built app stores these tools in `Contents/Resources/OverlayPainterProbe`. Do not run the source build script locally. The installer uses the normal `sevo status` client guard and never starts or stops Steam itself.

1. Normally quit Steam and Sevoflurane, then run `python3 install_probe.py install` from the installed resource directory. The existing DLL is renamed in the same folder; it is not copied into a second project archive.
2. Start Sevoflurane normally. When convenient, open CS2's main menu and the Steam overlay, then run `python3 install_probe.py status`. No match/dedicated server is required.
3. While the overlay is open, select its live stats file and run `python3 install_probe.py arm --stats-file /private/tmp/sevo-painter-.../cef-....stats`. Check that `replacement_paints` and then `restored_paints` increase. A one-frame flash can be too brief for visual acceptance; this stage checks delivery, not animation quality.
4. Normally quit Steam and Sevoflurane, then run `python3 install_probe.py restore`. Restoration checks the original, proxy and config hashes before replacing anything. Keep the small stats as test evidence, then remove the temporary stats directory.

No local runtime or visual acceptance has been recorded. Installer `install/restore` is an explicit separate operation; packaging and installing the app alone leave Valve files unchanged.
