# Embedded overlay experiment

This code is excluded from stable application packages. The local daily-use application remains the stable native-panel overlay. Do not enable `EmbeddedOverlayLaunch` or package these libraries solely because a compositor counter or fixture passes.

The previous live candidate produced real Metal composites but failed clarity, pointer interaction and game input isolation. The producer was 1512×982 for a 3024×1964 Retina display. WineContentView is flipped; the old normalization flipped its Y coordinate a second time. The installed CrossOver 26.3 driver also posts raw mouse/HID wheel events directly into WineEventQueue, bypassing NSApplication.sendEvent.

The cloud-only probe checks an alternative CALayer inside an existing game-sized NSWindow. It retains native physical-pixel stripes and refuses a 1x frame on a 2x surface. This is presentation inside the same window, not inside the game's Metal command buffer. The probe verifies no additional window or responder change. It does not demonstrate Steam or CS2 integration.

Private candidates use that layer presenter in the existing CS2 window and capture the WKWebView at the actual backing scale. The bridge follows game geometry, rejects undersampled snapshots and restores the accepted native panel when a frame cannot be displayed. The native input route has passed a real hidden-WKWebView click and Unicode key-event test (cloud run 39054388833); this is not live Chinese IME acceptance.

The experimental renderer uses flipped-aware pointer normalization, waits for Wine's actual NSApplication instance, and gates the CrossOver 26.3 event queue as well as AppKit events. Queue overflow no longer forwards captured UI input back to the game. Key and button releases remain available to clear previously held game input. The event prefix is specific to the currently installed CrossOver 26.3 ABI; do not apply it to other runtimes.

Before any new game candidate can ship:

- Validate the game-integrated presenter and true backing-scale image on the target Mac. A 1x image enlarged to 2x must fail acceptance.
- Verify pointer movement, click/drag, scrolling, child windows and keyboard entry through the actual hidden WKWebView. Validate English and Chinese composition separately.
- Verify game-side keyboard state and raw input while opening, using and closing the overlay, including held Shift, mouse buttons and repeated toggles. The present policy alone does not prove that the opening chord releases an already-held game binding.
- Verify fullscreen/windowed resizing, display changes, focus, menu-bar behavior, fallback and normal game controls after closing.
- Keep the stable package and published Release unchanged until live usability passes.

Run the `overlay_probe=true` GitHub workflow for the universal renderer, Metal readback, cross-architecture clock check and window-surface/input-policy fixture. Compile only in GitHub Actions.

A private full candidate uses `experimental_overlay=true` and `publish=false`. Normal builds omit the libraries; candidate manifests explicitly identify the experiment and the publisher rejects them. The public fork.4 Release remains the daily-use baseline until the new path passes live acceptance.
