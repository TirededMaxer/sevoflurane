import Foundation

/// Presentation only: AppKit supplies window controls and the native menu bar.
/// Steam's original page handlers and menu commands remain in place.
enum SteamDesktopChrome {
    static let script = dragScript(desktop: true)
    static let popupScript = dragScript(desktop: false)
    static let popupChromeScript = dragScript(desktop: false, popupHeader: true)

    private static func dragScript(desktop: Bool, popupHeader: Bool = false) -> String {
        """
        (function () {
          if (window.__sevoOriginalDrag) { window.__sevoOriginalDrag(); return "reapplied"; }
          var desktop = \(desktop ? "true" : "false");
          var popupHeader = \(popupHeader ? "true" : "false");
          function restyle() {
            if (!document.head || document.getElementById("sevo-macos-chrome")) return;
            var style = document.createElement("style"); style.id = "sevo-macos-chrome";
            style.textContent = ".TitleBar.title-area .title-bar-actions,.title-bar-actions.window-controls{display:none!important}";
            if (desktop) style.textContent +=
              "div:has(> .TitleBar.title-area){display:none!important}"+
              "div:has(> div > .TitleBar.title-area)>:first-child{display:none!important}";
            else if (popupHeader) style.textContent +=
              ".TitleBar.title-area{display:block!important}"+
              ".title-area-highlight,.singleWindowFocusBar{display:none!important}"+
              "div:has(> .TitleBar.title-area){box-sizing:content-box!important;padding-top:28px!important}";
            else style.textContent += ".TitleBar.title-area{padding-inline-start:80px!important}";
            document.head.appendChild(style);
          }
          function regions() {
            var area = document.querySelector(".TitleBar.title-area");
            var row = desktop ? area && area.parentElement && area.parentElement.parentElement : area;
            if (!row) return [];
            var r = row.getBoundingClientRect();
            if (!r.width || !r.height) return [];
            var spans = [[Math.max(r.left, 80), r.right]];
            var controls = Array.from(row.querySelectorAll(
              'button,a,input,select,textarea,[role="button"],[role="menuitem"],[tabindex],.title-bar-actions,.title-area-icon,[class*="Button"],[class*="button"],[class*="Account"],[class*="account"]'));
            if (desktop) Array.from(row.children).forEach(function (node) {
              if (node.children.length || node.textContent.trim()) controls.push(node);
            });
            controls.forEach(function (node) {
              var b = node.getBoundingClientRect();
              if (!b.width || !b.height || b.bottom <= r.top || b.top >= r.bottom) return;
              spans = spans.flatMap(function (span) {
                if (b.right <= span[0] || b.left >= span[1]) return [span];
                var parts = [];
                if (b.left > span[0]) parts.push([span[0], b.left]);
                if (b.right < span[1]) parts.push([b.right, span[1]]);
                return parts;
              });
            });
            return spans.filter(function (span) { return span[1] - span[0] > 2; })
              .map(function (span) { return [span[0], r.top, span[1] - span[0], r.height]; });
          }
          function report() {
            restyle();
            var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sevoWindow;
            if (handler) handler.postMessage({fn:"__dragRegions", args:[regions()]});
          }
          var pending = false;
          function schedule() {
            if (pending) return;
            pending = true;
            requestAnimationFrame(function () { pending = false; report(); });
          }
          new MutationObserver(function () { restyle(); schedule(); }).observe(document, {childList:true, subtree:true, attributes:true});
          window.addEventListener("resize", schedule);
          window.__sevoOriginalDrag = report;
          report();
          return "installed";
        })()
        """
    }
}
