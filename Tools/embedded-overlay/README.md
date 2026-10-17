# Embedded macOS overlay prototype

This renderer composites the app's premultiplied BGRA surface into the game's
existing Metal command buffer before drawable presentation. It does not present
a second window. Native game events return through a shared-memory ring while
the producer heartbeat is fresh. The library only installs hooks after Wine has
assigned the exact `cs2.exe` executable identity; other processes are untouched.

Build only in the **Cloud build and release** GitHub workflow (`overlay_probe=true` for a renderer-only check). The universal
`sevo-overlay-check` performs actual GPU blending and pixel readback, and checks
that a stale producer releases input/rendering. A runner with no Metal device
reports an explicit skip; the downloaded check must then pass on the target Mac.
The shared surface is a private, user-owned runtime IPC file, not a build cache.

The transport and renderer are the first prototype stage. A successful pixel
check alone does not establish game injection, WebKit capture or input fidelity.

The application captures existing WebKit pages and actual AppKit traffic lights.
Alpha-zero backing panels schedule WebKit without taking key or intercepting
native input. Only CS2 with a fresh game presentation heartbeat uses this path;
other games retain the existing window implementation. Runtime acceptance must
check injection, game pixels, hover/clicks and focus separately.
