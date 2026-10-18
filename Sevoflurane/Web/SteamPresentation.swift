import Foundation

/// Appearance only: original elements, handlers, text, callbacks and timers
/// remain owned by Steam. This stylesheet adds no notification policy.
nonisolated enum SteamPresentation {
    static let css = """
    html[data-sevo-macos-ui] { font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif; }
    html[data-sevo-macos-ui] button,
    html[data-sevo-macos-ui] .DialogButton { border-radius: 8px !important; }
    html[data-sevo-macos-ui] input,
    html[data-sevo-macos-ui] textarea,
    html[data-sevo-macos-ui] select { border-radius: 6px; }
    html[data-sevo-macos-ui] .ModalDialogPopup { border-radius: 12px; }
    html[data-sevo-macos-ui="toast"],
    html[data-sevo-macos-ui="toast"] body { background: transparent !important; }
    html[data-sevo-macos-ui="toast"] body > div { border-radius: 14px; overflow: hidden; }
    """

    // The original game UI keeps its actual Windows/Steam controls. Only their
    // paint and placement change; clicks still reach the same Steam handlers.
    static let gameControlsCSS = """
    html[data-sevo-macos-ui="game"] .TitleBar.title-area {
      inset-inline-start: 12px !important; inset-inline-end: auto !important;
      display: flex; flex-direction: row-reverse; gap: 8px;
    }
    html[data-sevo-macos-ui="game"] .TitleBar.title-area .title-area-icon {
      width: 12px !important; height: 12px !important; margin-block: 10px !important;
      border-radius: 50% !important; background: #8e8e93 !important;
    }
    html[data-sevo-macos-ui="game"] .TitleBar.title-area .title-area-icon:has(.SVGIcon_Minimize) { background: #febc2e !important; }
    html[data-sevo-macos-ui="game"] .TitleBar.title-area .title-area-icon:has(.SVGIcon_Maximize),
    html[data-sevo-macos-ui="game"] .TitleBar.title-area .title-area-icon:has(.SVGIcon_Restore) { background: #28c840 !important; }
    html[data-sevo-macos-ui="game"] .TitleBar.title-area .title-area-icon.closeButton { background: #ff5f57 !important; }
    html[data-sevo-macos-ui="game"] .TitleBar.title-area .title-area-icon svg { opacity: 0; }
    html[data-sevo-macos-ui="game"] .TitleBar.title-area:hover .title-area-icon svg { opacity: 0.65; }
    html[data-sevo-macos-ui="game"] .titleBarContainer { padding-inline-start: 80px; }
    """

    static func script(role: SteamWindowRole) -> String {
        installationScript(kind: role == .toast ? "toast" : "window", controls: false)
    }

    private static func installationScript(kind: String, controls: Bool) -> String {
        """
        (function () {
          var kind = \(JSLiteral.string(kind));
          var css = \(JSLiteral.string(css + (controls ? "\n" + gameControlsCSS : "")));
          function apply() {
            if (!document.documentElement) return;
            if (document.documentElement.getAttribute("data-sevo-macos-ui") !== kind)
              document.documentElement.setAttribute("data-sevo-macos-ui", kind);
            if (!document.head || document.getElementById("sevo-macos-presentation")) return;
            var style = document.createElement("style");
            style.id = "sevo-macos-presentation"; style.textContent = css;
            document.head.appendChild(style);
          }
          apply();
          if (!window.__sevoPresentationObserver && document.documentElement) {
            window.__sevoPresentationObserver = new MutationObserver(apply);
            window.__sevoPresentationObserver.observe(document.documentElement, {childList:true});
            if (document.head) window.__sevoPresentationObserver.observe(document.head, {childList:true});
          }
          return "styled";
        })()
        """
    }

    /// Run in the original CEF SharedJSContext. Forward window.open with its
    /// exact receiver, arguments and return value; decorate each returned page.
    /// No overlay state, hotkey, cursor, sound or notification function is replaced.
    static var originalClientScript: String {
        let appearanceCSS = css + "\n" + gameControlsCSS
        return """
        (function () {
          if (window.__sevoOriginalAppearance) return "already installed";
          function style(win, name) {
            try {
              if (!win || win === window || win.closed) return;
              var kind = String(name || win.name || "").indexOf("notificationtoasts") === 0 ? "toast" : "game";
              var doc = win.document;
              function apply() {
                if (!doc.documentElement) return;
                if (doc.documentElement.getAttribute("data-sevo-macos-ui") !== kind)
                  doc.documentElement.setAttribute("data-sevo-macos-ui", kind);
                if (doc.head && !doc.getElementById("sevo-macos-presentation")) {
                  var node = doc.createElement("style");
                  node.id = "sevo-macos-presentation";
                  node.textContent = \(JSLiteral.string(appearanceCSS));
                  doc.head.appendChild(node);
                }
                if (win.__sevoPresentationObserver && doc.head)
                  win.__sevoPresentationObserver.observe(doc.head, {childList:true});
              }
              apply();
              if (!win.__sevoPresentationObserver && doc.documentElement) {
                win.__sevoPresentationObserver = new win.MutationObserver(apply);
                win.__sevoPresentationObserver.observe(doc.documentElement, {childList:true});
                if (doc.head) win.__sevoPresentationObserver.observe(doc.head, {childList:true});
              }
            } catch (e) {}
          }
          function scan() {
            var map = window.g_PopupManager && g_PopupManager.m_mapPopups;
            if (map) map.forEach(function (record) { style(record && record.m_popup, record && record.m_strName); });
          }
          var open = window.open;
          window.open = function () {
            var result = open.apply(this, arguments);
            style(result, arguments[1]);
            return result;
          };
          window.__sevoOriginalAppearance = true;
          scan();
          window.setInterval(scan, 1000);
          return "installed";
        })()
        """
    }
}
