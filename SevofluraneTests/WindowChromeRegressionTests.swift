import AppKit
import Testing
import WebKit
@testable import Sevoflurane

/// Focused regressions for the missing traffic lights and duplicate top inset.
@MainActor
@Suite(.serialized)
struct WindowChromeRegressionTests {
    @Test
    func controlsRemainVisibleAndClickableAfterNativeLayout() throws {
        for role in [SteamWindowRole.login, .friends, .chat, .auxiliary, .controllerConfig, .dialog] {
            let popup = SteamWindow(webView: WKWebView(), role: role, name: "chrome-regression",
                                    size: CGSize(width: 500, height: 300), origin: nil, host: nil)
            popup.realize()
            defer { popup.detach(reason: .pageTeardown) }
            let window = try #require(popup.nsWindow)
            window.orderFront(nil)
            let content = try #require(window.contentView)
            let controls = try #require(content.subviews.compactMap { $0 as? SteamWindowControls }.first)
            let buttons = controls.subviews.compactMap { $0 as? NSButton }
            #expect(buttons.count == 3)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                window.setContentSize(NSSize(width: 620, height: 420))
                content.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                #expect(!controls.isHiddenOrHasHiddenAncestor)
                for button in buttons {
                    #expect(!button.isHiddenOrHasHiddenAncestor)
                    #expect(button.isEnabled)
                    #expect(button.target === window)
                    let center = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
                    let hitPoint = button.convert(center, to: content.superview)
                    let hit = content.hitTest(hitPoint)
                    #expect(hit === button || hit?.isDescendant(of: button) == true)
                    #expect(content.bounds.contains(controls.convert(button.frame, to: content)))
                }
            }
        }
    }

    @Test
    func standardButtonsUseTheWindowsOriginalActions() throws {
        let window = ActionWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try #require(window.contentView)
        let controls = SteamWindowControls(window: window, content: content)
        content.addSubview(controls)
        let buttons = controls.subviews.compactMap { $0 as? NSButton }
        #expect(buttons.count == 3)
        buttons.forEach { $0.performClick(nil) }
        #expect(window.actions == ["close", "minimize", "zoom"])
    }

    @Test
    func integratedPagePaintsAtTheTopOfItsWholeViewport() async throws {
        for role in [SteamWindowRole.login, .friends, .chat, .auxiliary, .controllerConfig, .dialog] {
            let web = WKWebView()
            let popup = SteamWindow(webView: web, role: role, name: "viewport-regression",
                                    size: CGSize(width: 500, height: 300), origin: nil, host: nil)
            popup.realize()
            defer { popup.detach(reason: .pageTeardown) }
            let window = try #require(popup.nsWindow)
            window.orderFront(nil)
            web.loadHTMLString("""
            <style>html,body{margin:0;background:#111;height:100%}#edge{position:fixed;top:0;left:0;right:0;height:8px;background:#ff00ff}</style>
            <style>.friendListHeaderContainer{box-shadow:inset #555 1px 1px 1px 0}.titleBarContainer.ChatTabs{padding-top:4px;border-top:1px solid black;box-shadow:inset 1px 1px #555}</style>
            <div id="edge"></div><div class="friendListHeaderContainer"><div class="TitleBar title-area"></div><div class="currentUserContainer">Profile</div></div>
            <div class="titleBarContainer ChatTabs"><div class="chatTabSetContainer inclient"><button onclick="window.clicked=true">Tab</button></div></div>
            <script>window.ready=true;</script>
            """, baseURL: nil)
            var ready = false
            for _ in 0..<100 {
                if (try? await web.evaluateJavaScript("window.ready === true")) as? Bool == true { ready = true; break }
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(ready)
            _ = try await web.evaluateJavaScript(SteamDesktopChrome.popupScript)
            #expect(try await web.evaluateJavaScript("getComputedStyle(document.querySelector('.friendListHeaderContainer')).boxShadow") as? String == "none")
            #expect(try await web.evaluateJavaScript("getComputedStyle(document.querySelector('.ChatTabs')).paddingTop") as? String == "0px")
            #expect(try await web.evaluateJavaScript("getComputedStyle(document.querySelector('.ChatTabs')).borderTopWidth") as? String == "0px")
            let dimensions = popup.dimensions()
            #expect(dimensions["height"] as? CGFloat == web.bounds.height)
            #expect(dimensions["width"] as? CGFloat == web.bounds.width)
            let image = try await web.takeSnapshot(configuration: nil)
            let data = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 1)?.usingColorSpace(.deviceRGB))
            #expect(color.redComponent > 0.9 && color.blueComponent > 0.9 && color.greenComponent < 0.1,
                    "The first webpage row must be the magenta header, not a native titlebar gap (\(role))")
            _ = try await web.evaluateJavaScript("document.querySelector('button').click()")
            #expect(try await web.evaluateJavaScript("window.clicked") as? Bool == true)
        }
    }

    private final class ActionWindow: NSWindow {
        var actions: [String] = []
        override func performClose(_: Any?) { actions.append("close") }
        override func performMiniaturize(_: Any?) { actions.append("minimize") }
        override func performZoom(_: Any?) { actions.append("zoom") }
    }
}
