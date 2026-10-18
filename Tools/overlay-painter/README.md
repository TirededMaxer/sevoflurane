# Original Steam painter experiment

Opt-in feasibility experiment for the exact Windows x64 Steam CEF in `cef-abi-evidence.json`. App launch never enables it. This is not a finished WebKit overlay.

Steam restored a disk DLL proxy during the build 46 bootstrap test before any callback was observed. That route and its installer/export-forwarder code have been removed. The successor attaches only after normal client startup, without changing any Valve file. The helper checks the full executable path and AMD64 architecture, loads the probe, then verifies its module path. The probe checks the original CEF API hashes and patches only the helper executable's two browser-creation IAT imports. Unknown existing hooks are rejected. Existing browsers are untouched; subsequently created browser clients are observed.

x64 tail thunks preserve creation and accelerated-paint arguments. CPU painting retains Valve's ten-argument callback, including scroll offset and page scale. Normal paints call the original callback with the original arguments. Original handler objects, reference counting, game renderer, activation, hotkeys and input stay Steam's. Observation records counters, dimensions, numeric browser IDs and ABI rejection only. Titles are checked for `SP Overlay` identity but not recorded; keystrokes and messages are not logged.

An explicit one-frame request gives the original CPU painter a WebKit test card at the observed dimensions. The next original repaint restores original pixels. WebKit snapshot is used once to test this boundary; continuous capture/compositing is not implemented. Accelerated-only clients are observed without forcing CPU rendering. Frame replacement requires an actual CPU overlay paint. Continuous performance, GPU sharing and full WebKit input remain unproven.

## Cloud-built local procedure

Tools reside in the installed app's `Contents/Resources/OverlayPainterProbe`. All compilation and tests run on a fresh Apple Silicon GitHub runner. Payload hashes bind the DLL, attachment helper and native fixture to their source. Changed CEF builds require fresh ABI calibration.

1. Start Steam normally. Run `python3 painter_probe.py attach`. Record the returned session directory. No game is launched by the tool.
2. Inspect with `python3 painter_probe.py status --session /private/tmp/sevo-painter-…`. After browser creation, check `iat_hooks`, rejection and CPU/GPU counters. Loading a module alone is not callback acceptance.
3. When game testing is authorized and convenient, open the overlay at its main menu. Only if CPU overlay paints are recorded, use `arm --session … --stats-file …/cef-PID.stats`. Check replacement and subsequent restoration counters. One brief frame is delivery evidence, not animation acceptance.
4. Normally stop Steam, then use `finish --session …` to collect counts and delete the experiment's temporary files. No DLL unload is attempted while Steam runs. Failed attachment retains the diagnostic session for inspection and the same stopped-client cleanup.

No game runtime or visual acceptance is implied by cloud fixture checks. This experimental candidate cannot be published as the finished release.
