import AppKit
import WebKit

// MARK: - React hover relay

extension SteamWindow {
    /// Menu CSS follows one explicit cursor path. WebKit can retain :hover
    /// after a non-activating panel loses key; duplicating those selectors
    /// leaves the original frozen rule active, so replace it in this document.
    static let controlledMenuHoverScript = """
    (function () {
      var old = document.getElementById("sevo-nonkey-hover");
      if (old) old.remove();
      var seen = window.__sevoHoverSheets || (window.__sevoHoverSheets = new WeakMap());
      function rewrite(rules) {
        for (var r of rules) {
          if (r.selectorText && r.selectorText.indexOf(":hover") >= 0)
            r.selectorText = r.selectorText.replace(/:hover\\b/g, "[data-sevo-hover]");
          if (r.cssRules) rewrite(r.cssRules);
        }
      }
      function refreshStyles() {
        for (var sheet of Array.from(document.styleSheets)) {
          if (sheet.disabled) continue;
          try {
            if (seen.get(sheet) !== sheet.cssRules.length) {
              rewrite(sheet.cssRules);
              seen.set(sheet, sheet.cssRules.length);
            }
          } catch (e) {}
        }
      }
      refreshStyles();
      if (!window.__sevoSetCSSHoverPath) {
        window.__sevoSetCSSHoverPath = function (path) {
          (window.__sevoCSSHoverPath || []).forEach(function (n) {
            if (path.indexOf(n) < 0) n.removeAttribute("data-sevo-hover");
          });
          path.forEach(function (n) { n.setAttribute("data-sevo-hover", ""); });
          window.__sevoCSSHoverPath = path;
        };
        // A key menu receives native DOM events; a non-key menu uses the
        // AppKit relay below. Both update the same CSS path without calling
        // React enter/leave twice in the native path.
        function track(event) {
          refreshStyles();
          var path = [];
          for (var n = event.target; n && n.nodeType === 1; n = n.parentElement) path.push(n);
          window.__sevoSetCSSHoverPath(path);
        }
        function clear() { window.__sevoSetCSSHoverPath([]); }
        document.addEventListener("mousemove", track, true);
        document.addEventListener("mouseover", track, true);
        document.addEventListener("mouseleave", clear, true);
        document.addEventListener("mouseup", clear, true);
        window.addEventListener("blur", clear, true);
      }
    })();
    """

    /// Runs Steam's own `onMouseEnter`/`onMouseLeave` handlers for the
    /// element path under the cursor.
    ///
    /// In a key window React's hover works off WKWebView's own tracking, but
    /// a menu panel may be non-key — and there, no deliverable mouse event runs
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
            \(Self.controlledMenuHoverScript)
            window.__sevoSetCSSHoverPath(path);
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

    /// A selected menu can navigate before AppKit delivers mouseExited.
    /// Clear both WebKit's native :hover and the React/CSS relay, including
    /// when the panel became key during the press.
    func clearMenuHover() {
        guard role == .menu else { return }
        let exit = Selector(("_simulateMouseExit:"))
        if let window,
           let event = NSEvent.enterExitEvent(with: .mouseExited, location: NSPoint(x: -1, y: -1),
                                              modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                              trackingNumber: 0, userData: nil), webView.responds(to: exit) {
            webView.perform(exit, with: event)
        }
        relayReactHoverExit()
    }

    /// Once the panel takes key focus, WebKit owns CSS hover again.
    func clearHoverAppearance() {
        guard role == .menu else { return }
        webView.evaluateJavaScript("""
        if (window.__sevoSetCSSHoverPath) window.__sevoSetCSSHoverPath([]);
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
          if (window.__sevoSetCSSHoverPath) window.__sevoSetCSSHoverPath([]);
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
