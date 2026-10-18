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

    /// Desktop WebKit is the single owner of general Steam toasts, even above
    /// a game. CEF retains its per-app queue (e.g. the Shift+Tab introduction).
    /// Discard only the duplicate general presentation queue using Steam's
    /// own clear operation; keep its tray, callbacks, settings and modal logic.
    static let originalGameToastOwnershipScript = """
    (function () {
      var store = window.NotificationStore;
      if (window.__sevoGameToastOwnership)
        return store.BAnyContextRenderingToasts() ? "draining" : "already installed";
      if (!store || !Array.isArray(store.m_rgNotificationToasts)
          || !store.m_mapAppOverlayToasts
          || typeof store.BAnyContextRenderingToasts !== "function"
          || typeof store.ClearAllToastNotifications !== "function"
          || typeof store.DispatchNextToast !== "function"
          || typeof store.PopNextToastNotification !== "function"
          || typeof store.PlayNotificationSound !== "function") return "unavailable";
      var dispatch = store.DispatchNextToast;
      var pop = store.PopNextToastNotification;
      var sound = store.PlayNotificationSound;
      var appToasts = new WeakSet();
      function publish() {
        if (store.m_rgNotificationToasts.length) {
          store.ClearAllToastNotifications();
          return;
        }
        return dispatch.apply(this, arguments);
      }
      function next(appid) {
        var queue = appid && store.m_mapAppOverlayToasts.get(appid);
        if (!queue || !queue.length) return;
        var notification = pop.apply(this, arguments);
        if (notification && typeof notification === "object") appToasts.add(notification);
        return notification;
      }
      function play(notification) {
        if (notification && appToasts.has(notification)) return sound.apply(this, arguments);
      }
      store.DispatchNextToast = publish;
      store.PopNextToastNotification = next;
      store.PlayNotificationSound = play;
      if (store.DispatchNextToast !== publish || store.PopNextToastNotification !== next
          || store.PlayNotificationSound !== play) {
        store.DispatchNextToast = dispatch;
        store.PopNextToastNotification = pop;
        store.PlayNotificationSound = sound;
        return "unavailable";
      }
      window.__sevoGameToastOwnership = true;
      store.ClearAllToastNotifications();
      // Clear does not dismiss an item already popped into React's active
      // list. Let that original animation finish before WebKit starts.
      return store.BAnyContextRenderingToasts() ? "draining" : "installed";
    })()
    """

}
