import AppKit
import WebKit

// MARK: - React hover relay

extension SteamWindow {
    /// Runs Steam's own `onMouseEnter`/`onMouseLeave` handlers for the
    /// element path under the cursor.
    ///
    /// In a key window React's hover works off WKWebView's own tracking, but
    /// a menu panel is never key — and there, no deliverable mouse event runs
    /// a React enter/leave handler: forwarded native events and script
    /// dispatches both reach the document and its React root listener with
    /// no handler firing (clicks work; hover does not — measured). The
    /// handlers are still right there on each node's `__reactProps$…`, so
    /// the native tracking calls them directly: diff the ancestor path under
    /// the cursor against the last one, leave the departed nodes, enter the
    /// new ones. This is what keeps a hover menu open (the menu root's enter
    /// handler arms Steam's keep-alive flag) and what highlights its rows.
    func relayReactHover(contentPoint: NSPoint, contentHeight: CGFloat) {
        let x = Int(contentPoint.x)
        let y = Int(contentHeight - contentPoint.y)
        webView.evaluateJavaScript("""
        (function (x, y) {
          var el = document.elementFromPoint(x, y) || document.documentElement;
          var path = [];
          for (var n = el; n; n = n.parentElement) path.push(n);
          var prev = window.__sevoHoverPath || [];
          // WebKit freezes :hover in non-key windows, even when native mouse
          // events are forwarded. Reuse Steam's rules without taking key focus.
          if (\(role == .menu ? "true" : "false")) {
            var style = document.getElementById("sevo-nonkey-hover");
            if (!style || window.__sevoHoverCSSCount !== document.styleSheets.length) {
              if (!style) {
                style = document.createElement("style");
                style.id = "sevo-nonkey-hover";
                document.head.appendChild(style);
              }
              function mirror(rules) {
                var css = "";
                for (var r of rules) {
                  if (r.selectorText && r.selectorText.indexOf(":hover") >= 0) {
                    css += r.selectorText.replace(/:hover\\b/g, "[data-sevo-hover]") + "{" + r.style.cssText + "}";
                  } else if (r.cssRules) {
                    var children = mirror(r.cssRules);
                    if (children) css += r.cssText.slice(0, r.cssText.indexOf("{")) + "{" + children + "}";
                  }
                }
                return css;
              }
              var css = "";
              for (var sheet of Array.from(document.styleSheets)) {
                if (sheet.ownerNode === style || sheet.disabled) continue;
                try { css += mirror(sheet.cssRules); } catch (e) {}
              }
              style.textContent = css;
              window.__sevoHoverCSSCount = document.styleSheets.length;
            }
            prev.forEach(function (n) { if (path.indexOf(n) < 0) n.removeAttribute("data-sevo-hover"); });
            path.forEach(function (n) { n.setAttribute("data-sevo-hover", ""); });
          }
          function props(n) {
            var k = Object.keys(n).find(function (k) { return k.indexOf("__reactProps$") === 0; });
            return k ? n[k] : null;
          }
          function ev(n, type) {
            return { target: el, currentTarget: n, clientX: x, clientY: y,
                     relatedTarget: null, bubbles: true, type: type, buttons: 0,
                     preventDefault: function () {}, stopPropagation: function () {},
                     nativeEvent: { clientX: x, clientY: y } };
          }
          prev.forEach(function (n) {
            if (path.indexOf(n) >= 0) return;
            var p = props(n);
            if (p && p.onMouseLeave) try { p.onMouseLeave(ev(n, "mouseleave")); } catch (e) {}
          });
          for (var i = path.length - 1; i >= 0; i--) {
            var n = path[i];
            if (prev.indexOf(n) >= 0) continue;
            var p = props(n);
            if (p && p.onMouseEnter) try { p.onMouseEnter(ev(n, "mouseenter")); } catch (e) {}
          }
          window.__sevoHoverPath = path;
          return "";
        })(\(x), \(y))
        """)
    }

    /// Once the panel takes key focus, WebKit owns CSS hover again.
    func clearHoverAppearance() {
        guard role == .menu else { return }
        webView.evaluateJavaScript("""
        document.querySelectorAll('[data-sevo-hover]').forEach(function (n) {
          n.removeAttribute('data-sevo-hover');
        }); "";
        """)
    }

    /// The cursor left the window: run the leave handlers for everything
    /// still marked hovered, so Steam's dismiss logic arms.
    func relayReactHoverExit() {
        webView.evaluateJavaScript("""
        (function () {
          var prev = window.__sevoHoverPath || [];
          window.__sevoHoverPath = [];
          prev.forEach(function (n) {
            n.removeAttribute("data-sevo-hover");
            var k = Object.keys(n).find(function (k) { return k.indexOf("__reactProps$") === 0; });
            var p = k ? n[k] : null;
            if (p && p.onMouseLeave) {
              try {
                p.onMouseLeave({ target: n, currentTarget: n, relatedTarget: null,
                                 bubbles: true, type: "mouseleave",
                                 preventDefault: function () {}, stopPropagation: function () {},
                                 nativeEvent: {} });
              } catch (e) {}
            }
          });
          return "";
        })()
        """)
    }
}
