import AppKit

extension SteamWebHost {
    /// Keep menu-bar diagnostics in step with Steam without driving its UI.
    func noteOverlayActivated(active: Bool, appID: String) {
        // A read-only observation: do not synthesize focus, input, opacity,
        // cursor restoration or child-window teardown around Steam's renderer.
        overlayActive = active
        overlayAppID = appID
        EventLog.shared.log(.window, "original Steam overlay \(active ? "active" : "inactive") for \(appID)")
    }

    /// Subscribes the context page to the client's overlay activation. The
    /// callback is Steam's own `OnOverlayActivated(unPID, unAppID, bActive, …)`
    /// (its handler does `GetOverlayInstance(appid, pid)` then, for a desktop
    /// overlay, `SetIsOverlayActive(bActive)`): the second argument is the
    /// app id, the third the shown flag. Both come back through the popup
    /// message handler as `__overlayActivated`; the app id lets the host close
    /// the overlay the way "Back to Game" does, `SetOverlayState(appid, 0)`.
    /// Re-registered on reload.
    static let overlayScript = """
    (function () {
      if (window.__sevoOverlay) return "already registered";
      if (!window.SteamClient || !SteamClient.Overlay
          || !SteamClient.Overlay.RegisterForOverlayActivated) return "unavailable";
      window.__sevoOverlay = true;
      SteamClient.Overlay.RegisterForOverlayActivated(function (pid, appid, active) {
        try {
          window.webkit.messageHandlers.sevoWindow.postMessage(
            { fn: "__overlayActivated", args: [active ? 1 : 0, String(appid || "")] });
        } catch (e) {}
      });
      return "registered";
    })()
    """
}
