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
    func integratedPageUsesTheWholeViewportWithoutATitlebarInset() async throws {
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
            // This checks the rendering engine's viewport and hit-test origin.
            // Hosted CI can lack IOSurface support, so pixel snapshots are
            // not a reliable compositor check on that runner.
            #expect(try await web.evaluateJavaScript("document.elementFromPoint(innerWidth / 2, 1).id") as? String == "edge")
            let height = try await web.evaluateJavaScript("innerHeight") as? Double
            #expect(height == Double(web.bounds.height))
            if #available(macOS 26.0, *) {
                #expect(web.obscuredContentInsets.top == 0)
            }
            _ = try await web.evaluateJavaScript("document.querySelector('button').click()")
            #expect(try await web.evaluateJavaScript("window.clicked") as? Bool == true)
        }
    }

    @Test
    func modalsUseSteamsSizeWhileLoginAndChatKeepTheirExistingRestoration() throws {
        for role in [SteamWindowRole.login, .dialog, .chat] {
            let popup = SteamWindow(webView: WKWebView(), role: role, name: "size-regression",
                                    size: CGSize(width: 705, height: 470), origin: nil, host: nil)
            let key = popup.placementName
            let saved = NSWindow(contentRect: NSRect(x: 200, y: 100, width: 850, height: 719),
                                 styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            saved.isReleasedWhenClosed = false
            saved.saveFrame(usingName: key)
            defer {
                popup.detach(reason: .pageTeardown)
                saved.close()
                UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(key)")
            }
            popup.realize()
            let window = try #require(popup.nsWindow)
            let content = try #require(window.contentView)
            if role != .dialog {
                #expect(content.bounds.size == CGSize(width: 850, height: 719))
            } else {
                #expect(content.bounds.size == CGSize(width: 705, height: 470))
                popup.resizeTo(width: 720, height: 460)
                popup.prepareOpeningPlacement()
                #expect(content.bounds.size == CGSize(width: 720, height: 460))
            }
        }
    }

    @Test
    func reauthenticationLoadingAndFormDoNotOverflowTheViewport() async throws {
        let web = WKWebView()
        let popup = SteamWindow(webView: web, role: .dialog, name: "loading-regression",
                                size: CGSize(width: 705, height: 470), origin: nil, host: nil)
        popup.realize()
        defer { popup.detach(reason: .pageTeardown) }
        let window = try #require(popup.nsWindow)
        window.orderFront(nil)
        web.loadHTMLString("""
        <style>
        html,body,#root{height:100%;margin:0}
        .VZ6x_grhNkIYJG__jEEyp{height:100%;border:1px solid #333;box-shadow:inset 1px 1px #555}
        .title{height:30px;flex-shrink:0}
        ._1TR3CCCdSmI-0MXucYBuP2{height:100%;width:100%;display:flex;align-items:center;justify-content:center}
        ._27A5ub1QLLIMmgywKVMg4z{flex:1;min-height:0}
        .VZ6x_grhNkIYJG__jEEyp:has(>._27A5ub1QLLIMmgywKVMg4z){display:flex;flex-direction:column}
        </style>
        <div id="root"><div class="VZ6x_grhNkIYJG__jEEyp DesktopUI">
        <div class="title"><div class="TitleBar title-area"></div></div>
        <div id="state" class="_1TR3CCCdSmI-0MXucYBuP2"><button>Ready</button></div>
        </div></div><script>window.ready=true;</script>
        """, baseURL: nil)
        var ready = false
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("window.ready === true")) as? Bool == true { ready = true; break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(ready)
        _ = try await web.evaluateJavaScript(SteamDesktopChrome.dialogScript)
        for size in [NSSize(width: 705, height: 470), NSSize(width: 850, height: 719)] {
            window.setContentSize(size)
            for state in ["_1TR3CCCdSmI-0MXucYBuP2", "_27A5ub1QLLIMmgywKVMg4z"] {
                _ = try await web.evaluateJavaScript("document.getElementById('state').className='\(state)'; window.scrollTo(0,0)")
                let fits = try await web.evaluateJavaScript("document.documentElement.scrollHeight === innerHeight && document.documentElement.scrollWidth === innerWidth") as? Bool
                #expect(fits == true)
                let border = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('.VZ6x_grhNkIYJG__jEEyp')).borderTopWidth") as? String
                #expect(border == "0px")
            }
        }
    }

    @Test
    func hoverCardsKeepSteamsPositionAndVisibilityWithoutNativeChrome() throws {
        for name in ["SP Desktop_uid0", "SP DesktopLoginWindow_uid0", "friendslist_uid0", "chat_1_uid0", "PopupWindow_1_uid0"] {
            #expect(SteamWindowRole(popupName: name).hasNativeFrame)
        }
        for name in ["contextmenu_1_uid0", "notificationtoasts_uid0", "SP Keyboard_uid0", "hoverpopup_uid0"] {
            #expect(!SteamWindowRole(popupName: name).hasNativeFrame)
        }
        let role = SteamWindowRole(popupName: "hoverpopup_uid0")
        #expect(role == .hover)
        #expect(!role.hasNativeFrame)
        #expect(!role.hasPopupChrome)
        #expect(!role.needsAReachableFrame)
        #expect(!role.allowsOcclusionDetection)
        let popup = SteamWindow(webView: WKWebView(), role: role, name: "hoverpopup_uid0",
                                size: CGSize(width: 328, height: 184), origin: nil, host: nil)
        popup.realize()
        defer { popup.detach(reason: .pageTeardown) }
        let window = try #require(popup.nsWindow)
        let content = try #require(window.contentView)
        #expect(window is NSPanel)
        #expect(!window.styleMask.contains(.titled))
        #expect(window.standardWindowButton(.closeButton) == nil)
        #expect(content.subviews.allSatisfy { !($0 is SteamWindowControls) })
        #expect(window.isVisible && window.alphaValue == 0)
        popup.positionRelative(toWindowNamed: "friendslist_uid0", x: 120, y: 180, width: 328, height: 184)
        let frame = window.frame
        let previousKeyWindow = NSApp.keyWindow
        popup.show(activating: true)
        #expect(window.frame == frame)
        #expect(NSApp.keyWindow === previousKeyWindow)
        #expect(!window.isKeyWindow)
        #expect(popup.isWindowVisible)
        _ = popup.perform("HideWindow", [])
        #expect(!popup.isWindowVisible)
        #expect(window.isVisible && window.alphaValue == 0)
        popup.show(activating: false)
        #expect(popup.isWindowVisible)
        #expect(window.frame == frame)
        #expect(SteamWindowRole.usesOriginalGameOverlay(popupName: "hoverpopup_uid730"))
    }

    private final class ActionWindow: NSWindow {
        var actions: [String] = []
        override func performClose(_: Any?) { actions.append("close") }
        override func performMiniaturize(_: Any?) { actions.append("minimize") }
        override func performZoom(_: Any?) { actions.append("zoom") }
    }
}
