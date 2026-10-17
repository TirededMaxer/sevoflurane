import Foundation

/// The script that turns Steam's Windows chrome into macOS chrome.
///
/// Steam's title strip is a normal part of the page, so the adjustments are
/// too: its window buttons are removed because the traffic lights already do
/// that job, and its menu strip is removed because the macOS menu bar drives
/// those menus through ``SteamMenuMirror``. Everything is anchored on
/// `.TitleBar.title-area`, the one semantic class in that corner of the DOM —
/// the rest of Steam's class names are content hashes that change with every
/// client build.
///
/// The script is idempotent and re-applies itself: Steam writes the popup's
/// document from the opener and keeps copying stylesheets into its head, so an
/// injection that assumed a stable head would be undone.
enum SteamDesktopChrome {
    static let script = """
    (function () {
      if (window.__sevoChrome) { window.__sevoChrome.apply(); return "reapplied"; }
    
      var STYLE_ID = "sevo-macos-chrome";
      /* Every selector is static — anchored on `.TitleBar.title-area`, the one
         semantic class, via `:has()` — so the rules bite from the moment the
         style element exists, before the title row's first paint. Tagging the
         row from the MutationObserver instead would leave Steam's window
         controls visible for the beat between paint and observer. */
      var CSS = [
        /* The macOS traffic lights are the window controls; Steam's are a
           second set for a window manager this app does not have. Hiding the
           container rather than .title-area itself also releases the ~99px it
           reserves at the row's right edge — the title-area is absolutely
           positioned, so hiding only it leaves the gap. */
        "div:has(> .TitleBar.title-area) { display: none !important; }",
        /* The title row's first cell is the menu strip, mirrored into the
           macOS menu bar, which drives the same menus; two strips would
           fight. */
        "div:has(> div > .TitleBar.title-area) > :first-child { display: none !important; }",
        /* The unified-compact titlebar is 40pt; Steam's 24pt buttons sit at
           y=7 in its 32pt strip. One extra point centers them against the
           traffic lights. The margin sits on the account cluster (the row's
           last visible cell) rather than as row padding: row padding either
           widens the row (content-box) or eats the top point (border-box).
           12px puts the last icon's visual gap to the window edge at the same
           ~20pt the cluster keeps between its own buttons. */
        "div:has(> div > .TitleBar.title-area) { padding-top: 1px !important; }",
        "div:has(> div > .TitleBar.title-area) > :nth-last-child(2) { margin-inline-end: 12px !important; }"
      ].join("\\n");
    
      function titleArea() { return document.querySelector(".TitleBar.title-area"); }
    
      function titleRow() {
        var area = titleArea();
        return area && area.parentElement && area.parentElement.parentElement;
      }
    
      function apply() {
        if (!document.head) return;
        var style = document.getElementById(STYLE_ID);
        if (!style) {
          style = document.createElement("style");
          style.id = STYLE_ID;
          style.textContent = CSS;
          document.head.appendChild(style);
        }
        reportDragRegions();
      }
    
      function rectOf(el) {
        var r = el.getBoundingClientRect();
        return [Math.round(r.left), Math.round(r.top),
                Math.round(r.width), Math.round(r.height)];
      }
    
      /* WebKit does not implement CEF’s app-region dragging. Report the
         title strip minus the native traffic lights and interactive controls,
         then let AppKit handle drag and double-click maximize. */
      function dragRegions() {
        var row = titleRow();
        if (!row) return [];
        var r = row.getBoundingClientRect();
        if (!r.width || !r.height) return [];
        var spans = [[Math.max(r.left, 80), r.right]];
        var controls = Array.from(row.querySelectorAll('button, a, input, [role="button"], [role="menuitem"], [tabindex], [class*="Button"], [class*="button"], [class*="Account"], [class*="account"]'));
        // Steam’s account cluster uses hashed classes and div handlers.
        // Keep every populated title-row cell interactive as well.
        Array.from(row.children).forEach(function (node) {
          if (node.children.length || node.textContent.trim()) controls.push(node);
        });
        controls.forEach(function (node) {
          var b = node.getBoundingClientRect();
          if (!b.width || !b.height) return;
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

      var pending = 0;
      function reportDragRegions() {
        var handler = window.webkit && window.webkit.messageHandlers
          && window.webkit.messageHandlers.sevoWindow;
        if (!handler) return;
        handler.postMessage({ fn: "__dragRegions", args: [dragRegions()] });
      }
    
      function schedule() {
        if (pending) return;
        pending = setTimeout(function () { pending = 0; apply(); }, 150);
      }
    
      /* Observed on the Document node, not documentElement: this script runs
         against the popup's initial about:blank, and Steam then document.open()s
         it — which replaces the whole element tree but keeps the Document (and
         this observer) alive. An observer on the old documentElement dies with
         it, and the strip then flashes until something else re-applies. Until
         the style is in the *current* head, apply immediately instead of
         debouncing, so the CSS lands before the strip's first paint. */
      new MutationObserver(function () {
        if (document.head && !document.getElementById(STYLE_ID)) apply();
        else schedule();
      }).observe(document, { childList: true, subtree: true });
      window.addEventListener("resize", schedule);
    
      window.__sevoChrome = { apply: apply };
      apply();
      return "installed";
    })()
    """

    /// The login window: traffic lights are overlaid on Steam's strip, so
    /// only its close/minimize buttons are hidden, and the strip's empty
    /// stretch is reported as a drag surface.
    static let popupScript = """
    (function () {
      if (window.__sevoChrome) { window.__sevoChrome.apply(); return "reapplied"; }
    
      var STYLE_ID = "sevo-macos-chrome";
      var CSS = ".TitleBar.title-area .title-bar-actions { display: none !important; }";
    
      function apply() {
        if (!document.head) return;
        var style = document.getElementById(STYLE_ID);
        if (!style) {
          style = document.createElement("style");
          style.id = STYLE_ID;
          style.textContent = CSS;
          document.head.appendChild(style);
        }
        reportDragRegions();
      }
    
      function rectOf(el) {
        var r = el.getBoundingClientRect();
        return [Math.round(r.left), Math.round(r.top),
                Math.round(r.width), Math.round(r.height)];
      }
    
      /* The strip's empty stretch is the drag surface — on the login window
         that is `.title-area-children`, which spans the strip minus the
         controls and renders nothing. `.title-area-highlight` never qualifies:
         it is a full-width visual overlay, and reporting it would turn
         everything under it into a drag handle. */
      function dragRegions() {
        var out = [];
        var area = document.querySelector(".TitleBar.title-area");
        if (!area) return out;
        for (var i = 0; i < area.children.length; i++) {
          var child = area.children[i];
          if (child.classList.contains("title-area-highlight")) continue;
          if (!child.children.length && !child.textContent.trim()) {
            out.push(rectOf(child));
          }
        }
        return out;
      }
    
      var pending = 0;
      function reportDragRegions() {
        var handler = window.webkit && window.webkit.messageHandlers
          && window.webkit.messageHandlers.sevoWindow;
        if (!handler) return;
        handler.postMessage({ fn: "__dragRegions", args: [dragRegions()] });
      }
    
      function schedule() {
        if (pending) return;
        pending = setTimeout(function () { pending = 0; apply(); }, 150);
      }
    
      new MutationObserver(function () {
        if (document.head && !document.getElementById(STYLE_ID)) apply();
        else schedule();
      }).observe(document, { childList: true, subtree: true });
      window.addEventListener("resize", schedule);
    
      window.__sevoChrome = { apply: apply };
      apply();
      return "installed";
    })()
    """

    /// Steam's ordinary popups (friends, chat, the configurator, notes):
    /// the page draws its strip, `.TitleBar.title-area`, absolutely
    /// positioned inside a header of its own, and the macOS title bar is
    /// transparent over the page. The strip goes away, the header becomes the
    /// title bar: padded by the title-bar height so its content (the friends
    /// avatar, a chat's tabs) moves out from under the traffic lights, in
    /// Steam's own color all the way to the top edge. The friends header's
    /// backdrop, an SVG gradient Steam starts below its strip, is pulled up
    /// to the edge so the gradient runs under the lights with no band above
    /// it. The header's stretch right of the traffic lights is the window's
    /// drag handle.
    static let popupChromeScript = """
    (function () {
      if (window.__sevoChrome) { window.__sevoChrome.apply(); return "reapplied"; }
    
      var STYLE_ID = "sevo-macos-chrome";
      var BAR = 28;              /* the macOS title bar */
      var TRAFFIC_LIGHTS = 80;   /* the strip the buttons and their margin occupy */
      var CSS = [
        ".TitleBar.title-area { display: block !important; }",
        ".title-area-highlight, .singleWindowFocusBar { display: none !important; }",
        ".title-bar-actions.window-controls { display: none !important; }",
        "div:has(> .TitleBar.title-area) { box-sizing: content-box !important; padding-top: " + BAR + "px !important; }",
        "div:has(> .TitleBar.title-area) svg[class*=\\"Gradient\\"], div:has(> .TitleBar.title-area) > .currentUserContainer > svg { top: 0 !important; height: 100% !important; }"
      ].join("\\n");
    
      function apply() {
        if (!document.head) return;
        var style = document.getElementById(STYLE_ID);
        if (!style) {
          style = document.createElement("style");
          style.id = STYLE_ID;
          style.textContent = CSS;
          document.head.appendChild(style);
        }
        reportDragRegions();
      }
    
      function dragRegions() {
        var area = document.querySelector(".TitleBar.title-area");
        var header = area && area.parentElement;
        if (!header) return [];
        var r = header.getBoundingClientRect();
        var left = Math.round(r.left) + TRAFFIC_LIGHTS;
        var width = Math.round(r.width) - TRAFFIC_LIGHTS;
        if (width <= 0) return [];
        return [[left, Math.round(r.top), width, BAR]];
      }
    
      var pending = 0;
      function reportDragRegions() {
        var handler = window.webkit && window.webkit.messageHandlers
          && window.webkit.messageHandlers.sevoWindow;
        if (!handler) return;
        handler.postMessage({ fn: "__dragRegions", args: [dragRegions()] });
      }
    
      function schedule() {
        if (pending) return;
        pending = setTimeout(function () { pending = 0; apply(); }, 150);
      }
    
      new MutationObserver(function () {
        if (document.head && !document.getElementById(STYLE_ID)) apply();
        else schedule();
      }).observe(document, { childList: true, subtree: true });
      window.addEventListener("resize", schedule);
    
      window.__sevoChrome = { apply: apply };
      apply();
      return "installed";
    })()
    """
}
