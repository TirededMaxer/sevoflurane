import Foundation

/// Presentation only: AppKit supplies window controls and the native menu bar.
/// Steam's original page handlers and menu commands remain in place.
enum SteamDesktopChrome {
    static let script = dragScript(desktop: true)
    static let popupScript = dragScript(desktop: false)

    private static func dragScript(desktop: Bool) -> String {
        """
        (function () {
          if (window.__sevoOriginalDrag) { window.__sevoOriginalDrag(); return "reapplied"; }
          var desktop = \(desktop ? "true" : "false");
          function restyle() {
            if (!document.head) return;
            if (desktop) {
              var header = document.querySelector('.TitleBar.title-area');
              if (header && !header.closest('.ModalDialogPopup,.FullModalOverlay,[role="dialog"]')) {
                var titleRow = header.parentElement;
                var menuRow = titleRow && titleRow.parentElement && titleRow.parentElement.firstElementChild;
                [titleRow, menuRow].forEach(function (row) {
                  if (row && !row.hasAttribute('data-sevo-native-title-row'))
                    row.setAttribute('data-sevo-native-title-row', '');
                });
              }
            }
            if (document.getElementById("sevo-macos-chrome")) return;
            var style = document.createElement("style"); style.id = "sevo-macos-chrome";
            style.textContent = ".title-bar-actions.window-controls{display:none!important}"+
              ".TitleBar .title-area-highlight,.singleWindowFocusBar{display:none!important}"+
              ".socialListTab .tabLabel{white-space:nowrap;overflow:hidden}"+
              ".socialListTab.TabSearchActive .tabLabel{visibility:hidden}";
            if (desktop) style.textContent +=
              "[data-sevo-native-title-row]{display:none!important}";
            else style.textContent +=
              ".TitleBar.title-area{box-sizing:border-box!important;padding-inline-start:80px!important}"+
              // Steam login CSS module 53576 adds a border outside height:100%.
              // Its loading component (37909) also requests 100% below a 30px
              // title strip. Fit both inside the native content viewport.
              ".VZ6x_grhNkIYJG__jEEyp{box-sizing:border-box!important;border:0!important;box-shadow:none!important}"+
              ".VZ6x_grhNkIYJG__jEEyp:has(>._1TR3CCCdSmI-0MXucYBuP2){display:flex!important;flex-direction:column!important}"+
              ".VZ6x_grhNkIYJG__jEEyp>._1TR3CCCdSmI-0MXucYBuP2{height:auto!important;min-height:0!important;flex:1!important}"+
              // Steam's own macOS header layouts: the avatar and chat tabs
              // are siblings of TitleBar, so insetting TitleBar alone misses them.
              ".friendListHeaderContainer{box-shadow:none!important}"+
              ".titleBarContainer.ChatTabs{border-top:0!important;box-shadow:none!important;padding-top:0!important}"+
              ".friendListHeaderContainer .currentUserContainer{padding-top:28px!important}"+
              ".chatTabSetContainer.inclient{padding-inline-start:101px!important;padding-inline-end:0!important}";
            document.head.appendChild(style);
          }
          function regions() {
            var area = document.querySelector(".TitleBar.title-area");
            var row = desktop ? area && area.parentElement && area.parentElement.parentElement : area;
            if (!row) return [];
            var r = row.getBoundingClientRect();
            if (!r.width || !r.height) return [];
            var spans = [[Math.max(r.left, 80), r.right]];
            // Popup controls (including chat tabs) can be siblings of the
            // absolute TitleBar. Do not turn their clicks into native drags.
            var scope = !desktop && area.parentElement ? area.parentElement : row;
            var controls = Array.from(scope.querySelectorAll("*")).filter(function (node) {
              if (node.matches('button,a,input,select,textarea,[role="button"],[role="tab"],[role="menuitem"],[tabindex],.no-drag,[draggable="true"]')) return true;
              var key = Object.keys(node).find(function (key) { return key.indexOf("__reactProps$") === 0; });
              var props = key && node[key];
              return props && (props.onClick || props.onMouseDown || props.onPointerDown || props.onDragStart);
            });
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
