# Steam WebKit presentation adapter

The original Steam HTML/CSS/JavaScript runs in the host's existing WebKit popup
tree. The macOS frame producer supplies complete BGRA frames through a shared
three-plane exchange to the original CEF CPU paint callback. Steam retains its
game injection, compositor, window placement, fade, cursor, focus and hotkey.

Only this exact helper's CPU vtable slot is replaced. The browser reference,
scroll reference and float scale retain their original ABI and ownership.
Original GPU callbacks are untouched. A stopped or stale WebKit producer
restores the original pixels with a full repaint.

`build.sh` runs through the main release workflow on a fresh Apple Silicon
runner. It checks the same callback source under the Microsoft x64 ABI,
concurrent shared-plane ownership on ARM64 and x86_64, and the Windows payloads.
These checks supplement the actual game test; they do not establish it.
