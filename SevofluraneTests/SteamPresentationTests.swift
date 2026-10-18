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
                     "new_steam_game_panel_uid730", "notificationtoasts_1_gameoverlay"] {
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
    func nativeWarningsKeepOriginalDefaultDisabledCancelAndOptionState() throws {
        let source = #"{"dialogs":[{"handle":33,"pid":22,"title":"Original warning","body":"Original detail","canClose":true,"buttons":[{"id":6,"title":"&Yes","enabled":false,"default":false},{"id":7,"title":"&No","enabled":true,"default":true},{"id":2,"title":"Cancel","enabled":true,"default":false}],"toggles":[{"id":21,"title":"Keep && remember","radio":false,"checked":true,"enabled":true}]}]}"#
        let dialog = try #require(SteamNativeDialog.decode(source).first)
        let alert = dialog.makeAlert()
        #expect(alert.messageText == "Original warning")
        #expect(alert.informativeText == "Original detail")
        #expect(dialog.presentedButtons.map(\.id) == [6, 7, 2])
        #expect(alert.buttons.map(\.title) == ["Yes", "No", "Cancel"])
        #expect(alert.buttons.map(\.isEnabled) == [false, true, true])
        #expect(alert.buttons.map(\.keyEquivalent) == ["", "\r", "\u{1b}"])
        #expect(dialog.toggles?.first?.checked == true)
        #expect(SteamNativeDialog.displayTitle("Keep && remember") == "Keep & remember")
    }

    @Test
    func unanswerableProgressWindowsGetNoInventedAction() throws {
        let source = #"{"dialogs":[{"handle":1,"pid":2,"title":"Steam","body":"Original progress","buttons":[],"canClose":false}]}"#
        let dialog = try #require(SteamNativeDialog.decode(source).first)
        #expect(dialog.presentedButtons.isEmpty)
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
