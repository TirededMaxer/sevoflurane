import Foundation

/// Remove only Sevoflurane's superseded visual theme. Steam supplies the
/// document, CSS, fonts, title controls and animations without host restyling.
nonisolated enum SteamPresentation {
    static let cleanupScript = """
    (function () {
      if (window.__sevoPresentationObserver) {
        window.__sevoPresentationObserver.disconnect();
        delete window.__sevoPresentationObserver;
      }
      var style = document.getElementById("sevo-macos-presentation");
      if (style) style.remove();
      if (document.documentElement)
        document.documentElement.removeAttribute("data-sevo-macos-ui");
      return "original";
    })()
    """

    /// A one-time migration for CEF pages already alive before an app upgrade.
    /// Do not wrap window.open, add styles or install a popup polling timer.
    static var originalClientScript: String {
        """
        (function () {
          function clean(win) {
            try {
              if (!win || win.closed) return;
              if (win.__sevoPresentationObserver) {
                win.__sevoPresentationObserver.disconnect();
                delete win.__sevoPresentationObserver;
              }
              var doc = win.document;
              var style = doc.getElementById("sevo-macos-presentation");
              if (style) style.remove();
              if (doc.documentElement) doc.documentElement.removeAttribute("data-sevo-macos-ui");
            } catch (e) {}
          }
          var map = window.g_PopupManager && g_PopupManager.m_mapPopups;
          if (map) map.forEach(function (record) { clean(record && record.m_popup); });
          return "original";
        })()
        """
    }

    /// Keep Steam's real in-game toast page and queue. Only the corner is a
    /// host presentation preference: games can request another corner through
    /// ISteamUtils, including the Shift+Tab introduction shown on game launch.
    static let gameToastCornerScript = """
    (function () {
      if (window.__sevoGameToastCorner) return "already installed";
      var store = window.overlayStore;
      var windows = window.SteamUIStore && SteamUIStore.WindowStore;
      if (!store || !windows || !windows.m_mapOverlayPopupByPID
          || typeof store.RegisterForBrowserCreated !== "function"
          || typeof store.RegisterForNotificationPositionChanged !== "function") return "unavailable";
      function place() {
        windows.m_mapOverlayPopupByPID.forEach(function (instance) {
          if (!instance || typeof instance.SetNotificationPosition !== "function") return;
          var position = instance.NotificationPosition;
          if (!position) return;
          instance.SetNotificationPosition(3, position.horizontalInset, position.verticalInset);
        });
      }
      // Store-level observers preserve Steam's existing native callback slot.
      // They see no notification text and never push or replay a toast.
      window.__sevoGameToastCorner = {
        created: store.RegisterForBrowserCreated(place),
        position: store.RegisterForNotificationPositionChanged(place)
      };
      place();
      return "installed";
    })()
    """


}
