import AppKit
import Testing
import WebKit
@testable import Sevoflurane

@MainActor
struct SteamPresentationTests {
    @Test
    func originalGamePagesNeverAcquireNativeMirrorWindows() {
        let host = SteamWebHost()
        for name in ["desktopoverlay_uid730", "gamepadoverlay_uid730", "friendslist_uid730",
                     "chat_ChatWindow_1_uid730", "contextmenu_4_uid730", "PopupWindow_warning_uid730",
                     "new_steam_game_panel_uid730", "notificationtoasts_1_gameoverlay", "notificationtoasts_uid730-123"] {
            let popup = SteamWindow(webView: WKWebView(), role: SteamWindowRole(popupName: name),
                                    name: name, size: CGSize(width: 400, height: 300), origin: nil, host: host)
            host.windowDidAdopt(popup)
            popup.realize()
            popup.show(activating: true)
            #expect(popup.usesOriginalGameOverlay, "\(name)")
            #expect(popup.nsWindow == nil, "\(name)")
        }
        #expect(EmbeddedOverlayLaunch.environment.isEmpty)
        #expect(EmbeddedOverlayLaunch.library == nil)
    }

    @Test
    func desktopPagesKeepTheirOwnNativeWindows() {
        for name in ["SP Desktop_uid0", "SP DesktopLoginWindow_uid0", "friendslist_uid0",
                     "chat_ChatWindow_1_uid0", "notificationtoasts_1_desktop", "PopupWindow_warning_uid0"] {
            #expect(!SteamWindowRole.usesOriginalGameOverlay(popupName: name), "\(name)")
        }
        #expect(!SteamWindowRole.usesOriginalGameOverlay(popupName: "SP Desktop_uid1"))
        #expect(!SteamWindowRole.usesOriginalGameOverlay(popupName: "SP BPM_uid1"))
    }

    @Test
    func overlayStateObservationLeavesFocusAndSavedChildWindowsAlone() {
        let host = SteamWebHost()
        let child = SteamWindow(webView: WKWebView(), role: .chat, name: "chat_1_uid730",
                                size: CGSize(width: 400, height: 300), origin: nil, host: host)
        host.overlayChildren = [child]
        let key = NSApp.keyWindow
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        host.noteOverlayActivated(active: true, appID: "730")
        host.noteOverlayActivated(active: false, appID: "730")
        #expect(host.overlayChildren.count == 1)
        #expect(host.overlayKeyMonitor == nil)
        #expect(host.overlayFrontObserver == nil)
        #expect(NSApp.keyWindow === key)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == front)
        #expect(!host.chatShowIsUnasked)
    }

    @Test
    func toastStylingPreservesOriginalContentClickAndDismissal() async throws {
        let web = WKWebView()
        web.loadHTMLString("""
        <style>#toast{transition:opacity .125s linear}</style>
        <div id="toast"><button id="action">Original Steam action</button><span id="body">Original message</span></div>
        <script>
        window.calls=0;window.originalButton=document.getElementById('action');
        window.originalHandler=function(){window.calls++};originalButton.onclick=originalHandler;
        window.ready=true;
        </script>
        """, baseURL: nil)
        try await ready(web)
        _ = try await web.evaluateJavaScript(SteamPresentation.script(role: .toast))
        #expect(try await web.evaluateJavaScript("document.getElementById('body').textContent") as? String == "Original message")
        #expect(try await web.evaluateJavaScript("document.getElementById('action')===originalButton && originalButton.onclick===originalHandler") as? Bool == true)
        _ = try await web.evaluateJavaScript("originalButton.click()")
        #expect(try await web.evaluateJavaScript("window.calls") as? Int == 1)
        #expect(try await web.evaluateJavaScript("getComputedStyle(document.getElementById('toast')).transitionDuration") as? String == "0.125s")
        _ = try await web.evaluateJavaScript("document.getElementById('toast').remove()")
        #expect(try await web.evaluateJavaScript("document.getElementById('toast')===null") as? Bool == true)
    }

    @Test
    func originalWindowOpenKeepsReceiverArgumentsAndHandle() async throws {
        let web = WKWebView()
        web.loadHTMLString("""
        <iframe id="child"></iframe><script>
        window.receiver={};window.forwarded=[];window.handle=document.getElementById('child').contentWindow;
        window.open=function(){forwarded.push({receiver:this===window.receiver,args:Array.from(arguments)});return handle};
        window.g_PopupManager={m_mapPopups:new Map()};window.ready=true;
        </script>
        """, baseURL: nil)
        try await ready(web)
        #expect(try await web.evaluateJavaScript(SteamPresentation.originalClientScript) as? String == "installed")
        #expect(try await web.evaluateJavaScript("window.open.call(receiver,'about:blank','friendslist_uid730','width=400')===handle") as? Bool == true)
        #expect(try await web.evaluateJavaScript("JSON.stringify(forwarded)") as? String == #"[{"receiver":true,"args":["about:blank","friendslist_uid730","width=400"]}]"#)
        #expect(try await web.evaluateJavaScript("handle.document.documentElement.getAttribute('data-sevo-macos-ui')") as? String == "game")
        #expect(try await web.evaluateJavaScript(SteamPresentation.originalClientScript) as? String == "already installed")
    }

    @Test
    func toastWindowFollowsOriginalAnimationCoordinates() throws {
        let popup = SteamWindow(webView: WKWebView(), role: .toast, name: "notificationtoasts_1_desktop",
                                size: CGSize(width: 360, height: 90), origin: nil, host: nil)
        popup.realize()
        defer { popup.detach(reason: .pageTeardown) }
        let window = try #require(popup.nsWindow)
        _ = popup.perform("MoveTo", [100, 200, 1])
        let first = window.frame.origin
        #expect(first == SteamScreenSpace.appKitOrigin(steamX: 100, steamY: 200, size: window.frame.size))
        _ = popup.perform("MoveTo", [100, 230, 1])
        #expect(window.frame.origin.y == first.y - 30)
        popup.show(activating: false)
        #expect(window.frame.origin.y == first.y - 30)
    }

    private func originalWarning() throws -> SteamNativeDialog {
        let source = #"{"dialogs":[{"handle":33,"pid":22,"title":"Original warning","body":"Not a layout specification","canClose":true,"clientWidth":404,"clientHeight":142,"buttons":[],"controls":[{"handle":101,"id":10,"className":"Static","text":"Original detail","style":0,"x":16,"y":20,"width":370,"height":40,"enabled":true,"tabStop":false,"password":false,"default":false,"checkState":0},{"handle":102,"id":1,"className":"Button","text":"&Yes","style":0,"x":220,"y":82,"width":80,"height":28,"enabled":false,"tabStop":true,"password":false,"default":false,"checkState":0},{"handle":103,"id":2,"className":"Button","text":"&Cancel","style":1,"x":310,"y":82,"width":80,"height":28,"enabled":true,"tabStop":true,"password":false,"default":true,"checkState":0},{"handle":104,"id":21,"className":"Button","text":"Keep && remember","style":3,"x":16,"y":65,"width":180,"height":24,"enabled":true,"tabStop":true,"password":false,"default":false,"checkState":1}]}]}"#
        return try #require(SteamNativeDialog.decode(source).first)
    }

    @Test
    func nativeWarningsKeepOriginalGeometryControlsDefaultAndOptions() throws {
        let adapter = try #require(NativeSteamDialogWindow(dialog: try originalWarning(), send: { _ in }))
        defer { adapter.originalDidClose() }
        #expect(adapter.window.title == "Original warning")
        #expect(adapter.window.contentView?.frame.size == NSSize(width: 404, height: 142))
        #expect(adapter.controls.count == 4)
        #expect(adapter.controls[101]?.frame == NSRect(x: 16, y: 20, width: 370, height: 40))
        #expect((adapter.controls[101] as? NSTextField)?.stringValue == "Original detail")
        let yes = try #require(adapter.controls[102] as? NSButton)
        let cancel = try #require(adapter.controls[103] as? NSButton)
        let toggle = try #require(adapter.controls[104] as? NSButton)
        #expect(yes.title == "Yes")
        #expect(!yes.isEnabled)
        #expect(cancel.frame == NSRect(x: 310, y: 82, width: 80, height: 28))
        #expect(adapter.window.defaultButtonCell === cancel.cell)
        #expect(cancel.keyEquivalent == "\r")
        #expect(toggle.title == "Keep & remember")
        #expect(toggle.state == .on)
        #expect(cancel.nextKeyView === toggle)
        #expect(toggle.nextKeyView === cancel)
    }

    @Test
    func nativeActionsForwardTheOriginalControlAndWaitForItsLifetime() throws {
        var calls: [[String]] = []
        let adapter = try #require(NativeSteamDialogWindow(dialog: try originalWarning(), send: { calls.append($0) }))
        defer { adapter.originalDidClose() }
        let cancel = try #require(adapter.controls[103] as? NSButton)
        cancel.performClick(nil)
        #expect(calls == [["control", "33", "22", "103", "click"]])
        #expect(adapter.controls.count == 4)
        adapter.window.cancelOperation(nil)
        #expect(calls.last == ["control", "33", "22", "103", "click"])
        #expect(!adapter.windowShouldClose(adapter.window))
        #expect(calls.last == ["answer", "33", "22", "0"])
    }

    @Test
    func originalChangesUpdateExistingControlsWithoutRebuildingOrRecentring() throws {
        var snapshot = try originalWarning()
        let adapter = try #require(NativeSteamDialogWindow(dialog: snapshot, send: { _ in }))
        defer { adapter.originalDidClose() }
        let originalLabel = adapter.controls[101]
        let origin = NSPoint(x: 120, y: 160)
        adapter.window.setFrameOrigin(origin)
        snapshot.controls?[0].text = "Original changed detail"
        snapshot.controls?[1].enabled = true
        snapshot.controls?[3].checkState = 0
        adapter.update(snapshot)
        #expect(adapter.controls[101] === originalLabel)
        #expect((adapter.controls[101] as? NSTextField)?.stringValue == "Original changed detail")
        #expect((adapter.controls[102] as? NSButton)?.isEnabled == true)
        #expect((adapter.controls[104] as? NSButton)?.state == .off)
        #expect(adapter.window.frame.origin == origin)
    }

    @Test
    func missingOriginalLayoutNeverBecomesAnInventedAlert() throws {
        let source = #"{"dialogs":[{"handle":1,"pid":2,"title":"Steam","body":"Original progress","buttons":[],"canClose":false}]}"#
        let dialog = try #require(SteamNativeDialog.decode(source).first)
        #expect(NativeSteamDialogWindow(dialog: dialog, send: { _ in }) == nil)
    }

    @Test
    func javascriptDialogUsesTheOriginalMessage() {
        let message = "Steam original warning\n原始提示"
        let alert = SteamWebCoordinator.javaScriptAlert(message: message, cancel: true)
        #expect(alert.messageText == message)
        #expect(alert.buttons.count == 2)
    }

    private func ready(_ web: WKWebView) async throws {
        for _ in 0..<80 {
            if (try? await web.evaluateJavaScript("window.ready===true")) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("WebKit fixture did not load")
    }
}
