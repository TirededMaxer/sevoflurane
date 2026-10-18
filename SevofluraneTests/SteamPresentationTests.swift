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
    func originalToastStylesLayoutHandlersAndAnimationAreUnchanged() async throws {
        let web = WKWebView()
        web.loadHTMLString("""
        <style>body{font-family:serif}#toast{background:rgb(23,26,33);border-radius:2px;transition:opacity .125s linear}
        button{border-radius:0;width:120px;height:30px}</style>
        <div id="toast"><button id="action">Original Steam action</button><span id="body">Original message</span></div>
        <script>
        window.calls=0;window.originalButton=document.getElementById('action');
        window.originalHandler=function(){window.calls++};originalButton.onclick=originalHandler;
        window.inspect=function(){var b=getComputedStyle(originalButton),t=getComputedStyle(document.getElementById('toast'));
          return JSON.stringify({html:document.documentElement.outerHTML,font:getComputedStyle(document.body).fontFamily,
            buttonRadius:b.borderRadius,toastRadius:t.borderRadius,background:t.backgroundColor,animation:t.transitionDuration,
            width:originalButton.getBoundingClientRect().width})};window.ready=true;
        </script>
        """, baseURL: nil)
        try await ready(web)
        let before = try await web.evaluateJavaScript("inspect()") as? String
        _ = try await web.evaluateJavaScript(SteamPresentation.cleanupScript)
        #expect(try await web.evaluateJavaScript("inspect()") as? String == before)
        #expect(try await web.evaluateJavaScript("document.getElementById('action')===originalButton && originalButton.onclick===originalHandler") as? Bool == true)
        _ = try await web.evaluateJavaScript("originalButton.click()")
        #expect(try await web.evaluateJavaScript("window.calls") as? Int == 1)
        _ = try await web.evaluateJavaScript("document.getElementById('toast').remove()")
        #expect(try await web.evaluateJavaScript("document.getElementById('toast')===null") as? Bool == true)
    }

    @Test
    func originalClientMigrationNeverWrapsWindowOpenOrInstallsStyles() async throws {
        let web = WKWebView()
        web.loadHTMLString("""
        <iframe id="child"></iframe><script>
        window.handle=document.getElementById('child').contentWindow;
        window.originalOpen=window.open;window.intervals=0;window.setInterval=function(){intervals++};
        window.g_PopupManager={m_mapPopups:new Map([['friends',{m_popup:handle,m_strName:'friendslist_uid730'}]])};
        window.originalDOM=handle.document.documentElement.outerHTML;window.ready=true;
        </script>
        """, baseURL: nil)
        try await ready(web)
        #expect(try await web.evaluateJavaScript(SteamPresentation.originalClientScript) as? String == "original")
        #expect(try await web.evaluateJavaScript("window.open===originalOpen && intervals===0") as? Bool == true)
        #expect(try await web.evaluateJavaScript("handle.document.documentElement.outerHTML===originalDOM") as? Bool == true)
        #expect(try await web.evaluateJavaScript(SteamPresentation.originalClientScript) as? String == "original")
    }

    @Test
    func originalTitleStripRemainsVisibleAndInteractiveWhileReportingEmptyDragRegions() async throws {
        let configuration = WKWebViewConfiguration()
        let messages = DragReports()
        configuration.userContentController.add(messages, name: "sevoWindow")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), configuration: configuration)
        web.loadHTMLString("""
        <style>body{margin:0}.row{display:flex;width:900px;height:32px}.menus{width:140px}.space{flex:1}
        .controls{width:99px}.TitleBar{display:flex;height:32px}.TitleBar button{width:33px}</style>
        <div class="row"><div class="menus"><button id="menu">Steam</button></div><div class="space"></div>
        <div class="controls"><div class="TitleBar title-area"><button id="min">_</button><button id="max">□</button><button id="close">×</button></div></div></div>
        <script>window.calls=[];document.querySelectorAll('button').forEach(function(b){b.onclick=function(){calls.push(b.id)}});window.ready=true;</script>
        """, baseURL: nil)
        try await ready(web)
        let before = try await web.evaluateJavaScript("document.documentElement.outerHTML") as? String
        _ = try await web.evaluateJavaScript(SteamDesktopChrome.script)
        #expect(try await web.evaluateJavaScript("document.documentElement.outerHTML") as? String == before)
        for _ in 0..<80 {
            if messages.last != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let regions = try #require(messages.last)
        #expect(regions == [[140, 0, 661, 32]])
        _ = try await web.evaluateJavaScript("document.querySelectorAll('button').forEach(function(b){b.click()})")
        #expect(try await web.evaluateJavaScript("JSON.stringify(calls)") as? String == #"["menu","min","max","close"]"#)
    }

    @Test
    func sourceWindowControlsNeedNoMacTitlebarAndToastsHaveNoAddedMaterial() throws {
        for role in [SteamWindowRole.desktop, .login, .friends, .chat, .auxiliary, .bigPicture, .toast, .dialog] {
            let popup = SteamWindow(webView: WKWebView(), role: role, name: "source-ui-test",
                                    size: CGSize(width: 500, height: 300), origin: nil, host: nil)
            popup.realize()
            defer { popup.detach(reason: .pageTeardown) }
            let window = try #require(popup.nsWindow)
            #expect(!window.styleMask.contains(.titled))
            #expect(window.toolbar == nil)
            #expect(window.standardWindowButton(.closeButton) == nil)
            #expect(window.contentView?.bounds.size == CGSize(width: 500, height: 300))
            #expect(window.contentView?.subviews.contains(where: { $0 is NSVisualEffectView }) == false)
            if role != .toast { #expect(window.canBecomeKey) }
            if !role.isPanel { #expect(window.canBecomeMain) }
        }
    }

    @Test
    func borderlessDocumentStillSupportsTheSystemCloseCommand() {
        let delegate = DocumentClose()
        let window = SteamDocumentWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                                         styleMask: [.borderless, .closable, .miniaturizable, .resizable],
                                         backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        defer { window.delegate = nil; window.close() }
        window.performClose(nil)
        #expect(delegate.calls == 1)
        #expect(window.standardWindowButton(.closeButton) == nil)
    }

    @Test
    func originalMaximizeUsesTheNativeWindowAndRestoresItsGeometry() throws {
        let screen = try #require(NSScreen.main)
        let delegate = DocumentZoom(frame: screen.visibleFrame.insetBy(dx: 50, dy: 20))
        let window = SteamDocumentWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 300),
                                         styleMask: [.borderless, .closable, .miniaturizable, .resizable],
                                         backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        let original = window.frame
        defer { window.delegate = nil; window.close() }
        window.performZoom(nil)
        #expect(window.frame == delegate.frame)
        #expect(window.isZoomed)
        window.performZoom(nil)
        #expect(window.frame == original)
        #expect(!window.isZoomed)
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

@MainActor
private final class DragReports: NSObject, WKScriptMessageHandler {
    var last: [[Double]]?
    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any]
        let args = body?["args"] as? [Any]
        last = args?.first as? [[Double]]
    }
}

@MainActor
private final class DocumentClose: NSObject, NSWindowDelegate {
    var calls = 0
    func windowShouldClose(_: NSWindow) -> Bool { calls += 1; return false }
}

@MainActor
private final class DocumentZoom: NSObject, NSWindowDelegate {
    let frame: NSRect
    init(frame: NSRect) { self.frame = frame }
    func windowWillUseStandardFrame(_: NSWindow, defaultFrame: NSRect) -> NSRect { frame }
}

/// Exercise the shipped shim itself. The fixture never connects to Steam;
/// only namespace enumeration and feature detection are under test.
@MainActor
struct SteamClientShapeTests {
    @Test
    func aClientProvidedBrowserViewRemainsOneEnumerableNamespace() async throws {
        let web = try await load(shape: #"{"BrowserView":{"Create":1},"Apps":{"RunGame":1},"WebChat":{"RegisterOverlayChatBrowserInfoChanged":1}}"#)
        #expect(try await web.evaluateJavaScript("Object.keys(SteamClient)") as? [String] == ["BrowserView", "Apps", "WebChat"])
        #expect(try await web.evaluateJavaScript("Reflect.ownKeys(SteamClient)") as? [String] == ["BrowserView", "Apps", "WebChat"])
        #expect(try await web.evaluateJavaScript("typeof SteamClient.WebChat.RegisterOverlayChatBrowserInfoChanged") as? String == "function")
    }

    @Test
    func aHostBrowserViewIsAddedOnceWithoutInventingClientFeatures() async throws {
        let web = try await load(shape: #"{"Apps":{"RunGame":1},"System":{"OpenInSystemBrowser":1}}"#)
        #expect(try await web.evaluateJavaScript("Object.keys(SteamClient)") as? [String] == ["Apps", "System", "BrowserView"])
        #expect(try await web.evaluateJavaScript("typeof SteamClient.Apps.RunGame") as? String == "function")
        #expect(try await web.evaluateJavaScript("typeof SteamClient.WebChat") as? String == "undefined")
        #expect(try await web.evaluateJavaScript("typeof SteamClient.System.Audio") as? String == "undefined")
    }

    private func load(shape: String) async throws -> WKWebView {
        let url = try #require(Bundle.main.url(forResource: "steamclient_shim", withExtension: "js"))
        let shim = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "%PAGE_PORT%", with: "8761")
            .replacingOccurrences(of: "%STEAM_HOSTS%", with: "[]")
        let web = WKWebView()
        web.loadHTMLString("""
        <script>
        window.__sevoShape=\(shape);
        window.SteamUIStore={WindowStore:{MainWindowInstance:{}}};
        window.collectionStore={allAppsCollection:{}};
        window.WebSocket=class {
          constructor(){this.readyState=0;this.bufferedAmount=0;}
          send(){} close(){this.readyState=3;} addEventListener(){} removeEventListener(){}
        };
        WebSocket.CONNECTING=0;WebSocket.OPEN=1;WebSocket.CLOSING=2;WebSocket.CLOSED=3;
        \(shim)
        window.fixtureReady=true;
        </script>
        """, baseURL: nil)
        for _ in 0..<80 {
            if (try? await web.evaluateJavaScript("window.fixtureReady===true")) as? Bool == true { return web }
            try await Task.sleep(for: .milliseconds(25))
        }
        _ = try #require((try? await web.evaluateJavaScript("window.fixtureReady===true")) as? Bool == true)
        return web
    }
}
