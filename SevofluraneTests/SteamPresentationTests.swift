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
    func nativeModalRestoresParentMouseStateAndCoversNewWindows() {
        let host = SteamWebHost()
        let parent = SteamWindow(webView: WKWebView(), role: .desktop, name: "SP Desktop_uid0",
                                 size: CGSize(width: 400, height: 300), origin: nil, host: host)
        host.popups[ObjectIdentifier(parent.webView)] = parent
        parent.realize()
        defer { parent.close() }
        parent.nsWindow?.ignoresMouseEvents = false
        host.setNativeDialogModal(true)
        #expect(parent.nsWindow?.ignoresMouseEvents == true)
        let later = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        later.ignoresMouseEvents = true
        host.applyNativeDialogModal(to: later)
        host.setNativeDialogModal(false)
        #expect(parent.nsWindow?.ignoresMouseEvents == false)
        #expect(later.ignoresMouseEvents)
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
    func gameToastsUseOriginalInstanceAndKeepInsetsAndCallbacks() async throws {
        let web = WKWebView()
        web.loadHTMLString("""
        <script>
        window.registrations=0;window.nativeRegistrations=0;window.originalQueue=[{id:10001}];
        window.created=[];window.positions=[];
        window.overlayStore={
          RegisterForBrowserCreated:function(fn){created.push(fn);registrations++;return {unregister:function(){}};},
          RegisterForNotificationPositionChanged:function(fn){positions.push(fn);registrations++;return {unregister:function(){}};}
        };
        window.first={NotificationPosition:{position:2,horizontalInset:18,verticalInset:24},
          SetNotificationPosition:function(p,x,y){this.NotificationPosition={position:p,horizontalInset:x,verticalInset:y};}};
        window.SteamUIStore={WindowStore:{m_mapOverlayPopupByPID:new Map([[1,first]])}};
        window.SteamClient={Overlay:{RegisterForNotificationPositionChanged:function(){nativeRegistrations++;}}};
        window.ready=true;
        </script>
        """, baseURL: nil)
        try await ready(web)
        #expect(try await web.evaluateJavaScript(SteamPresentation.gameToastCornerScript) as? String == "installed")
        #expect(try await web.evaluateJavaScript("JSON.stringify(first.NotificationPosition)") as? String == #"{"position":3,"horizontalInset":18,"verticalInset":24}"#)
        _ = try await web.evaluateJavaScript("first.NotificationPosition.position=2;positions[0](730,2,18,24)")
        #expect(try await web.evaluateJavaScript("first.NotificationPosition.position") as? Int == 3)
        #expect(try await web.evaluateJavaScript("originalQueue.length") as? Int == 1)
        #expect(try await web.evaluateJavaScript("nativeRegistrations") as? Int == 0)
        #expect(try await web.evaluateJavaScript(SteamPresentation.gameToastCornerScript) as? String == "already installed")
        #expect(try await web.evaluateJavaScript("registrations") as? Int == 2)
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

    @Test
    func browserDialogResponsesReachTheNativeView() async throws {
        let messages = BrowserViewReports()
        let web = try await load(shape: "{}", messages: messages)
        _ = try await web.evaluateJavaScript("""
        var browser=SteamClient.BrowserView.Create({});
        browser.DialogResponse(true);browser.DialogResponse(false);
        """)
        for _ in 0..<80 {
            if messages.responses.count == 2 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(messages.responses == [true, false])
    }

    @Test
    func gameBrowserSubscriptionsStayWithOriginalSteam() async throws {
        let messages = BrowserViewReports()
        let web = try await load(shape: #"{"Overlay":{"GetOverlayBrowserInfo":1,"RegisterOverlayBrowserInfoChanged":1},"WebChat":{"GetOverlayChatBrowserInfo":1,"RegisterOverlayChatBrowserInfoChanged":1}}"#, messages: messages)
        let result = try await web.callAsyncJavaScript("""
          var a=SteamClient.Overlay.RegisterOverlayBrowserInfoChanged(function(){throw Error('wrong renderer')});
          var b=SteamClient.WebChat.RegisterOverlayChatBrowserInfoChanged(function(){throw Error('wrong renderer')});
          a.unregister();b.unregister();
          var info=await SteamClient.Overlay.GetOverlayBrowserInfo();
          var chats=await SteamClient.WebChat.GetOverlayChatBrowserInfo();
          return JSON.stringify({info:info,chats:chats,forwarded:window.sentCommands});
        """, arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(result == #"{"info":[],"chats":[],"forwarded":[]}"#)
    }

    @Test
    func desktopToastContextNeverRegistersForNativeGameFocus() async throws {
        let messages = BrowserViewReports()
        let web = try await load(shape: #"{"System":{"UI":{"RegisterForOverlayGameWindowFocusChanged":1}}}"#, messages: messages)
        let result = try await web.callAsyncJavaScript("""
          var focus=[];
          var a=SteamClient.System.UI.RegisterForOverlayGameWindowFocusChanged(function(app,pid){focus.push([app,pid]);});
          var b=SteamClient.System.UI.RegisterForOverlayGameWindowFocusChanged(function(){throw Error('unregistered callback')});
          b.unregister();await Promise.resolve();a.unregister();
          return JSON.stringify({focus:focus,forwarded:window.sentCommands});
        """, arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(result == #"{"focus":[[0,0]],"forwarded":[]}"#)
    }

    @Test
    func gameBrowserSnapshotsKeepIndependentShapesAndLocalSubscriptions() async throws {
        let web = try await load(shape: #"{"Overlay":{"GetOverlayBrowserInfo":1,"RegisterOverlayBrowserInfoChanged":1},"WebChat":{"GetOverlayChatBrowserInfo":1,"RegisterOverlayChatBrowserInfoChanged":1}}"#, messages: BrowserViewReports())
        let result = try await web.callAsyncJavaScript("""
          var a=0,b=0;
          var first=SteamClient.Overlay.RegisterOverlayBrowserInfoChanged(()=>a++);
          var second=SteamClient.WebChat.RegisterOverlayChatBrowserInfoChanged(()=>b++);
          var snapshot={browsers:[{unPID:42,nBrowserID:12}],chats:[{chatBrowserID:13}],app:730,pid:42};
          __sevoUpdateNativeOverlay(snapshot);__sevoUpdateNativeOverlay(snapshot);
          first.unregister();snapshot.browsers=[];__sevoUpdateNativeOverlay(snapshot);second.unregister();
          return JSON.stringify({a:a,b:b,info:await SteamClient.Overlay.GetOverlayBrowserInfo(),
            chats:await SteamClient.WebChat.GetOverlayChatBrowserInfo(),forwarded:sentCommands});
        """, arguments: [:], in: nil, contentWorld: .page) as? String
        #expect(result == #"{"a":1,"b":1,"info":[],"chats":[{"chatBrowserID":13}],"forwarded":[]}"#)
    }

    private func load(shape: String, messages: BrowserViewReports? = nil) async throws -> WKWebView {
        let url = try #require(Bundle.main.url(forResource: "steamclient_shim", withExtension: "js"))
        let shim = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "%PAGE_PORT%", with: "8761")
            .replacingOccurrences(of: "%STEAM_HOSTS%", with: "[]")
        let configuration = WKWebViewConfiguration()
        if let messages { configuration.userContentController.add(messages, name: "sevoWindow") }
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.loadHTMLString("""
        <script>
        window.__sevoShape=\(shape);
        window.SteamUIStore={WindowStore:{MainWindowInstance:{}}};
        window.collectionStore={allAppsCollection:{}};
        window.sentCommands=[];
        window.WebSocket=class {
          constructor(){this.readyState=1;this.bufferedAmount=0;}
          send(value){window.sentCommands.push(JSON.parse(value));} close(){this.readyState=3;} addEventListener(){} removeEventListener(){}
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

@MainActor
private final class BrowserViewReports: NSObject, WKScriptMessageHandler {
    var responses: [Bool] = []
    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let args = body["args"] as? [Any], args.count == 3,
              args[1] as? String == "dialogResponse", let answer = args[2] as? Bool else { return }
        responses.append(answer)
    }
}
