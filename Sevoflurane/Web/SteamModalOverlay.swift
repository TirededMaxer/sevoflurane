import WebKit

/// Keeps Steam's modal overlay in step with the windows the app tears down.
///
/// A Steam dialog that gets its own window is two objects, not one. The
/// content goes into a popup (`PopupWindow_…`), and a second, invisible modal
/// is pushed into the desktop's own modal manager to hold the dimming overlay
/// up while the dialog is answered. The desktop's `FullModalOverlay` carries
/// `display: none` exactly while that manager's modal list is empty, so the
/// library behind it comes back only when the invisible modal is removed.
///
/// What removes it is the popup document's `unload` event: `CPopup.OnUnload`
/// stops tracking the popup, runs the modal's `fnOnClose`, and that closes the
/// invisible modal. Under CEF that event is the popup window closing. Here it
/// is the page teardown that follows the web view being released, which is a
/// different thing and lands whenever the app lets go — measured on a popup
/// closed the way Steam closes one, `window.close()` set `closed` to true on
/// the opener's handle and delivered no `pagehide` and no `unload` at all.
/// The dialog leaves the screen, the overlay stays, and the library sits
/// behind a scrim that nothing can dismiss.
///
/// So the app fires those two events itself, from the context page, which is
/// where the popup's `Window` object and Steam's listeners both live. It works
/// after the popup's web view is already gone, because the context page holds
/// the object either way, and a second delivery is a no-op because the first
/// clears the popup Steam would act on.
extension SteamWebHost {
    /// Runs the teardown Steam expects from a popup whose window has closed.
    ///
    /// Addressed by popup name rather than by web view: the events have to be
    /// dispatched in the context page's realm, where the listeners were
    /// registered.
    func notifyPopupUnloaded(named name: String) {
        guard !name.isEmpty else { return }
        evaluateInContextPage(Self.popupUnloadScript(popup: name))
    }

    private func evaluateInContextPage(_ script: String) {
        Task(name: "Notify popup unloaded") { [weak self] in
            _ = await self?.evaluateInContext(script)
        }
    }

    private static func popupUnloadScript(popup name: String) -> String {
        """
        (function () {
          try {
            var popups = window.g_PopupManager && g_PopupManager.m_mapPopups;
            var entry = popups && popups.get(\(JSLiteral.string(name)));
            var win = entry && entry.m_popup;
            if (!win) return "absent";
            win.dispatchEvent(new win.Event("pagehide"));
            win.dispatchEvent(new win.Event("unload"));
            return "unloaded";
          } catch (e) {
            return "error: " + e;
          }
        })()
        """
    }

}
