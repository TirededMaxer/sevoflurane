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
}
