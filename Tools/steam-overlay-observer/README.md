# Steam overlay metadata observer

An independent, opt-in diagnostic tool for this fork's exact Windows x64 Steam CEF build. It does not ship in or rebuild Sevoflurane. The DLL is loaded from a private temporary session directory into existing, full-path-matched AMD64 `steamwebhelper.exe` processes only. It does not start/stop Steam or a game, overwrite Valve files, alter inputs, read frame pixels, replace frames, create windows, or install hotkeys.

## Build and evidence

Run **Cloud overlay metadata observer** (`.github/workflows/overlay-observer.yml`) manually. All compilation and tests run on a fresh `xcode-27` Apple Silicon runner without restored compilation caches. Download the resulting Actions artifact to a temporary directory and verify `archive.sha256` before extracting. This workflow creates no Release and does not change the application version or installation.

The cloud fixture compiles the same callback bodies as Microsoft x64-ABI functions into a macOS x86_64 executable and runs it through Rosetta. It checks six-argument creation, exact return values/LastError, the ten-argument custom paint callback including its final float, opaque GPU-pointer forwarding without dereferencing it, shared-handler accounting, slot outcomes, separate CEF/Steam IDs, and concurrent counts. Python tests decode the actual C fixture file and reject corrupt/torn schemas and changed session payloads. The Windows DLL/attacher are separately cross-compiled and inspected as PE32+ AMD64. These checks do not establish compatibility or performance inside a real Steam/game process.

## Manual observation

Steam must already be running normally. Keep the original CEF overlay subscriptions and original consumer intact; do not restore the abandoned WebKit callback ownership or screenshot path. Attach before a naturally occurring new game-browser lifecycle if creation evidence is needed. An already-created overlay can be reused across Shift+Tab operations and may produce no new create/getter calls.

```sh
python3 -B observer.py attach
python3 -B observer.py status --session /private/tmp/sevo-overlay-observer-SESSION
```

`attach` prints the actual session path, build source, exact-matching Wine PIDs, loader outcome and Win32 errors. Module loading is not hook readiness: request `status` separately and check `ready=true`, `status=0`, and the IAT/slot outcomes. The DLL hashes its loaded libcef file and validates all three `cef_api_hash` strings before installing any callback. Initialization status is 2=libcef missing, 3=SHA mismatch/read failure, 4=API-hash mismatch, 5=export missing, 6=invalid host PE, 7=no matching creation import. Status 0 with `ready=false` can be initialization still in progress. No automatic retry loop is installed.

To cover helpers which appeared later, explicitly repeat attach with **the same session**:

```sh
python3 -B observer.py attach --session /private/tmp/sevo-overlay-observer-SESSION
```

An already-loaded exact DLL path is reported `already_loaded` without starting another loader thread or resetting statistics. A different observer session already present in a process is rejected. Each attach enumerates once; it does not follow future processes. A load timeout retains path memory which the loader might still be using; it neither frees that memory nor terminates the thread.

Keep the session directory and DLL present until Steam and all matching helpers have exited normally. There is intentionally no live unload, automatic process termination or automatic session deletion. After normal exit and verifying no matching helper remains, the session directory and downloaded build can be removed.

## Reading results

- `create_calls` counts calls; `async_accepted` means the original asynchronous create returned nonzero, **not** that a browser completed creation. `async_rejected`, `sync_nonnull` and `sync_null` are separate. Every captured create record includes the untouched result and original `windowless`, `shared_texture` and `external_begin_frame` flags. Recording capacity is bounded; `records_dropped` exposes overflow while forwarding continues.
- `render_getters`/`display_getters` count getter calls. `unique_handlers` counts unique handler addresses per kind. Handler rows connect client→handler; slot rows expose original callback module/RVA and installed/already/null/rejected counts. A nonempty handler is not proof that a paint slot was installed.
- CPU/GPU entry counters increment before original-function lookup. `missing_original` is an abnormal observer failure, not a legitimate empty-render result. Browser rows connect handler→local CEF ID, paint type, dimensions and counts. GPU dimensions are not guessed; the opaque custom accelerated-info object is forwarded unchanged and never inspected.
- Only a bounded `SP Overlay: gamePID/SteamBrowserID/type` title is parsed. No other title text is saved. The local CEF `get_identifier` value and Steam's target-browser ID are deliberately separate. Correlate them with the original CEF page/native overlay metadata; they need not be equal. No chat, keyboard, mouse, complete command line or frame data is collected.
- Metadata rows use a sequence guard; a read during a row update reports a retryable error. Top-level counters are independent monotonic samples, not an atomic snapshot across all helpers. The numeric process creation time distinguishes reused Wine PIDs and prevents a new process from resetting an earlier stats file.

The probe only hooks the main helper EXE's existing `libcef.dll` creation imports. Existing clients, new helpers after enumeration, dynamically resolved calls, or creation calls imported by another DLL remain coverage gaps. If the original overlay is visible but a ready, correctly identified probe still sees zero paints, inspect that coverage before selecting a different rendering path. Do not force CPU/shared-texture/external-begin-frame flags to manufacture a result.

## ABI provenance

Calibration is archived in `Docs/LocalValidation/steam-overlay-rea-42/cef-abi-evidence.json` and `native-report.json`: CEF126/Chromium126.0.6478.183, original libcef SHA-256 `c85bf94462b3c79baeac63823db52d15e116eead71ea414e5d3a112c59e434d3`, customized platform/universal/commit API hashes pinned in `observer.h`. This customized ABI differs from official CEF6478. The confirmed client/display/render/browser slots and custom ten-argument paint signature are used; lifespan, input and accelerated-info layouts are not inferred from upstream headers. Original six-argument create calls/results, callback pointers, original return references and all callback arguments are forwarded unchanged once. The tool does not own the client's or handler's reference lifecycle.
