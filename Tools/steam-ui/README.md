# Steam native-dialog relay

`sevo-steam-ui.exe` is a freestanding x86-64 Windows console helper built from
`steam-ui.c`, using Wine headers and Windows import libraries. It enumerates
Steam/Steam error-reporter Win32 dialogs in the daemon’s bottle and returns UTF-16
text as escaped JSON. The app presents that text and the original button labels in
an `NSAlert`. Button answers verify the owning PID and control before posting
`WM_COMMAND`; neither scanning nor answering terminates Steam.

The helper reads conventional dialog children, excluding password edits. It handles
standard `#32770` dialogs and VGUI/SDL dialogs exposing child text. Custom-drawn
dialogs with no readable controls cannot be reconstructed by this bridge. CEF
windows are handled by the existing WebKit bridge; game and installer UI stay
interactive. The CrossOver driver suppression patch is a separate, matching-runtime
requirement; see `../crossover-ui/README.md`.

Build with Homebrew `llvm` and `lld`, matching Wine headers/generated headers and
the matching `kernel32` import library:

```sh
Tools/steam-ui/build.sh /path/to/wine /path/to/wine-build/include /path/to/libkernel32.a
```

For a local relay fixture, copy the helper as `steamerrorreporter64.exe` and launch
it with `--fixture` through `sevo run --wait`. It creates a Chinese error dialog,
prints the selected button ID, and times out after 45 seconds. Production scans use
only the daemon’s authenticated bottle-run API. No network submission is included.
