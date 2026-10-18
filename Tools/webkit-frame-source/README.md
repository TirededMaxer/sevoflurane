# WebKit frame source diagnostic

An isolated macOS diagnostic for **public CARenderer → Metal → owned IOSurface → CPU BGRA**. It never opens Steam, reads user pages, injects into another process, changes the product, or replaces Steam's overlay. WKWebView remote-layer and video coverage are **unproven until the real GUI report passes**. A successful cloud build is not that acceptance.

## Cloud build and local execution

Dispatch **Cloud WebKit frame source diagnostic** (`webkit-frame-source.yml`). The fresh Apple Silicon runner compiles and runs the pixel-checker tests, checks the JavaScript syntax, builds one arm64 `.app`, ad hoc signs/verifies it and packages it with SHA-256 evidence. No build/package caches or third-party packages are used. CI does **not** launch NSApp or claim a GUI pass.

Download the successful artifact, verify `archive.sha256`, unzip outside the source checkout, and run its executable when local GUI validation is authorized:

```sh
"/path/to/WebKit Frame Source Diagnostic.app/Contents/MacOS/WebKitFrameSource"
```

The process runs for about 15 seconds (up to two additional seconds for a pending GPU completion), prints the private report path, then exits `0` only if the complete functional checks pass. A failure exits `2`; it is not a skipped test. The diagnostic writes only `/tmp/sevo-webkit-frame-source-XXXXXX/report.json`, in a directory created with `mkdtemp`. No screenshots, pixel files, account information, input events or network data are saved. Its source HTML is entirely synthetic and WK uses a nonpersistent data store. Canvas `captureStream()` feeds a muted video without camera, microphone or screen-capture permission.

The normal-level, nonactivating fixture panel does not make itself key or activate an existing user app. It first attempts a visible phase, covers **its own** source panel at five seconds, then hides only its own NSApp at nine seconds. This cannot establish visibility if the OS refuses to display a background application's panel; the report records actual `NSWindow.occlusionState`, hidden and active counts, and that phase fails if its intended condition was not observed.

## What is checked

The synthetic page has fixed colored corners, transparent outer edges, the same 16-bit generation encoded in four separated locations, CSS motion, programmatic scrolling, a Canvas 2D animation, WebGL and an animated CanvasCaptureStream video. The checker samples **actual completed BGRA bytes**, not JavaScript readiness alone. It verifies the full expected geometry, normalizes a detected vertical flip, validates all four generation values, rejects mixed/invalid/backwards generations, checks the Canvas/WebGL/video colors and requires changing hashes in every animated region.

Every phase needs at least eight distinct generation transitions and two changes in every animated region, with zero content/alpha/tearing/orientation/lock/GPU failures. The visible phase also needs actual visible samples; the covered phase needs actual occlusion; the hidden phase needs actual hidden and occluded samples. If WK stops producing fresh frames while hidden or occluded, the result is **failed**, with duplicate/transition counts showing why. This is functional continuous-frame acceptance, not a 60 FPS claim; distinct-generation FPS and submission/GPU-wait/lock/copy/total p50/p95 are reported separately.

Each target is a retained BGRA8Unorm IOSurface with its own Metal texture and CPU copy buffer. One CARenderer cycles three destinations with only one capture in flight; it does not bind the WK layer to multiple renderers. The source layer stays owned by this synthetic fixture. A transparent GPU clear precedes each full-bounds render, so unsupported/missing layers cannot pass using old pixels. An explicit one-pixel blit reads the tracked destination on the same supplied Metal queue; only its successful GPU completion permits `IOSurfaceLock` and CPU copying. The slot is held until completion and the entire CPU read ends. Read-only lock/unlock flags are symmetric. `AvoidSync` is not used. Failed locks never lead to a base-address read. A GPU timeout retains slots until process teardown and records failure without reading their pixels.

`copy_ms` includes orientation detection and row copying; `total_ms` also includes the pixel checker. Actual IOSurface width/height/rowBytes, requested geometry and window backing scale are reported. Renderer bounds remain WK's point bounds while the Metal target uses backing pixels: the colored corners at the expected *full target* coordinates deliberately fail if this public mapping does not preserve Retina dimensions. No success is inferred from a merely nonempty or partially rendered texture.

## Limits and next boundary

CARenderer may fail to render WK's remotely hosted compositing/video layers. Binding an existing WK layer to this renderer may also alter that fixture's onscreen rendering; this experiment does not assume that a layer usable by WindowServer is renderable by CARenderer. The diagnostic uses only this synthetic WK instance and does not discover private WebKit contexts, move a user window's layer, use render-server SPI, or fall back to `takeSnapshot`. Missing video or an unsupported layer graph remains a failure.

After a real GUI pass, the next separate experiment would copy these completed BGRA frames into the already identified Windows Steam triple-buffer producer protocol. Native activation, focus, fade, input routing and the `0x1d` consumer are outside this diagnostic and remain untouched.

Primary API contracts: [Apple CARenderer](https://developer.apple.com/documentation/quartzcore/carenderer), [Metal queue option](https://developer.apple.com/documentation/quartzcore/kcarenderermetalcommandqueue), and the shipped Apple SDK `CARenderer.h`, `MTLDevice.h`, `MTLCommandBuffer.h`, `MTLBlitCommandEncoder.h`, `IOSurfaceRef.h`, `IOSurfaceTypes.h`. No third-party rendering implementation is included.
