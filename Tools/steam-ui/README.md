# Steam original-window presentation bridge

The source of truth is the original Steam window, not a replacement message-box
workflow. The helper enumerates Steam/Steam error-reporter Win32 dialogs in the
same daemon-owned bottle. The AppKit host uses the original client size and each
control's rectangle, order, text, ID/handle, enabled/default/check state and icon
resource. It does not collapse the dialog into an `NSAlert`, invent a Close button,
close after a click, or infer the result. Original disappearance removes the host;
original changes update the same controls in place.

Actions validate the original PID and descendant handle. Buttons receive
`BM_CLICK`; closing requests `WM_CLOSE`; edit changes use `SetWindowTextW` on the
original edit control. The original Steam code still receives and handles the
result. Password contents are not collected. The UI does not terminate Steam.

The current AppKit adapters cover text/static icons, buttons, checkbox/radio/group
controls, text edits and progress bars. Custom-drawn dialogs with no readable
controls and other complex Win32 controls are not yet equivalent. CEF Steam
popups retain their original DOM in the existing WebKit bridge; game popups stay
in Steam's renderer. Do not count these paths as verified merely because the
Win32 helper fixture passed.

Build and test on the fresh GitHub Apple Silicon runner with
`Tools/steam-ui/build-cloud.sh`. It uses the checked-in minimal Win32 ABI and
import definitions, without a local Wine SDK or build cache. The older
`build.sh WINE_SOURCE GENERATED_HEADERS KERNEL32_IMPORT_LIBRARY` entry point is
retained for matching upstream-source comparison, not the local project workflow.

For the local fixture, copy the verified packaged helper as
`steamerrorreporter64.exe` and run `--fixture` through the authenticated daemon
`POST /bottle/run?timeout=60` API (one program argument per line), not the direct
`sevo run` debug launcher. It emits the original selected control ID and exits
after 45 seconds if unanswered. Tests do not submit anything to Steam or friends.
