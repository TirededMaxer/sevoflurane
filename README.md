# Sevoflurane — TirededMaxer fork

Based on [kageroumado/sevoflurane](https://github.com/kageroumado/sevoflurane). This fork adds title-strip dragging and double-click maximize, original Steam corner toasts, local Win32 error-dialog relay, and menu-bar cloud upload status. See [fork scope, build and validation](FORK_NOTES.md).

Sevoflurane brings a Proton-like experience to Mac, running Windows and macOS games from the same Steam interface. Native WebKit windows replace Steam’s Wine-rendered Chromium UI, while Steam runs in the background with its original corner toasts. Older games get resizable windows and upscaling.

<a href="https://github.com/TirededMaxer/sevoflurane/releases/latest"><img src=".github/download.svg" alt="Download Sevoflurane for Mac" width="360" height="80"></a>

![Sevoflurane](.github/sevoflurane-library.png)

## Highlights

- Run Windows and native Mac games from one library, choosing the version per game.
- Use Steam through WebKit windows while the Windows client runs in the background; see its original notifications at the bottom-right of the display.
- Resize older games and upscale them with Lanczos, MetalFX, Anime4K, or CuNNy.
- Give each game its own Dock icon and graphics settings.

<details>
<summary>Full feature list</summary>

- **Setup:** guided Steam installation; new or existing bottles; Dormison, CrossOver, and CrossOver Preview; fonts, legacy runtimes, Rosetta, and Game Porting Toolkit installation; background setup and `sevo setup`.
- **Steam:** Library, Store, Friends, chats, Big Picture, keyboard, and controller configuration in Mac windows; native menus, clipboard, launch-choice alerts, `steam://` links, and Steam corner toasts.
- **Personalization:** CSS styles with live reload, Streamer Mode, and Low Power Mode/Reduce Motion integration.
- **Compatibility:** per-version ratings from Sevoflurane runs, AppleGamingWiki, and ProtonDB; anti-cheat information; library medals, native-Mac markers, and a playable-on-this-Mac filter. Linux ratings are displayed separately from the Mac filter.
- **Launchers:** recent and installed games in the menu bar and Dock menu; per-launch or persistent renderer choices; Quick Launch for external programs.
- **Game windows (Dormison):** independent Dock icons, Game Mode, resizable fixed-resolution windows, Lanczos/MetalFX/Anime4K/CuNNy upscaling, live filters, frame-rate limits, and CPU/GPU/frame-time overlays.
- **Input and media:** Xbox/PlayStation controller input with rumble; DLSS through MetalFX on D3DMetal. Dormison adds raw mouse input, cursor confinement, native Win32 menus, CPU caps, and hardware H.264/HEVC decoding.
- **Native games:** macOS game installs and per-game version switching on supported engines; optional handoff to Steam for Mac. Native NW.js games retain Steam playtime and achievements.
- **Game sessions:** display-awake holds, stuck-game termination, complete process cleanup, Steam reconnection, and Discord activity; Dormison also relays games’ own Discord integration.
- **External games:** Finder `.exe` launch and thumbnails, installer tracking, Quick Launch, non-Steam library entries, Steam Input, overlay, and run reports. Kernel-driver dependencies are reported.
- **Configuration:** searchable per-engine and per-game graphics, input, performance, DLL, and environment settings; known fixes with undo; dependency repair; Proton-style launch-option import.
- **Storage:** per-game and category sizes, cache/engine cleanup, external libraries, and sharing installed games across bottles with separate saves.
- **Recovery:** client watchdog, crash-loop detection, lost-wake recovery, orphan cleanup, helper/bottle repair, cache resets, and recovery guides. A running game survives a Sevoflurane crash; reopening reattaches.
- **Privacy in this fork:** no application auto-updater, usage/statistics uploads, crash/report submissions, or macOS notification module. Compatibility databases and manual engine/renderer downloads remain available.
- **Diagnostics:** run records, frame-time traces, logs, crash reports, per-game recording levels, local diagnostic ZIP export, Process Monitor, CPU-cap suggestions, and `sevo perf compare`.
- **Automation:** CLI/MCP and manual engine switching. Steam keeps its own updates and cloud-save sync. The menu bar shows upload status from Steam’s local cloud log.
- [Detailed feature reference](REFERENCE.md#full-feature-list). Dormison-specific features require that engine.

</details>

## Notes

- Apple silicon · macOS 26+ · Rosetta. Setup offers Dormison or CrossOver; DirectX 12 requires D3DMetal.
- [Game compatibility](https://kagerou.glass/sevoflurane/games/) · [Renderer choices and limits](REFERENCE.md#renderers).
- **Settings → About → Save Diagnostics…** collects a report. [CLI/MCP reference](REFERENCE.md#command-line) · [Contributing](CONTRIBUTING.md).
- [English](README.md) · [简体中文](README.zh-CN.md).
