import Foundation
import Testing
import WebKit
@testable import Sevoflurane

@Suite(.serialized)
@MainActor
struct NativeOverlayInputTests {
    @Test
    func originalDocumentInputIsRoutedOnceAndCleanupRestoresItsHandlers() async throws {
        let web = WKWebView()
        web.loadHTMLString("<button id='button'>Original button</button><script>window.ready=true;window.sent=[];window.__sevo=x=>sent.push(JSON.parse(x));window.clicks=0;button.onclick=()=>clicks++;</script>", baseURL: nil)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("window.ready")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let url = try #require(Bundle.main.url(forResource: "native_overlay_input", withExtension: "js"))
        let script = try String(contentsOf: url, encoding: .utf8)
        // Model the host heartbeat while unrelated AppKit tests occupy the run loop.
        let liveScript = script + ";__sevoOverlayInput.ping=Date.now()+60000;__sevoOverlayInput.enabled=true;'ready'"
        #expect(try await web.evaluateJavaScript(liveScript) as? String == "ready")
        _ = try await web.evaluateJavaScript("""
        button.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,clientX:10,clientY:20}));
        button.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true}));
        button.dispatchEvent(new KeyboardEvent('keydown',{bubbles:true,cancelable:true,key:'Tab',code:'Tab',shiftKey:true}));
        """)
        #expect(try await web.evaluateJavaScript("sent.length") as? Int == 1)
        #expect(try await web.evaluateJavaScript("sent[0].event") as? String == "mousedown")
        #expect(try await web.evaluateJavaScript("window.clicks") as? Int == 0)
        _ = try await web.evaluateJavaScript("window.__sevoOverlayInput.stop();button.click()")
        #expect(try await web.evaluateJavaScript("window.clicks") as? Int == 1)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('textarea,canvas').length") as? Int == 0)
    }

    @Test
    func emptyOrHiddenContentCannotStartInputHandoff() async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        web.loadHTMLString("<div id='empty' style='width:400px;height:300px'></div><script>window.ready=true</script>", baseURL: nil)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("window.ready")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await web.evaluateJavaScript(SteamWebKitOverlay.contentReadyScript) as? Bool == false)
        _ = try await web.evaluateJavaScript("empty.innerHTML='<button style=\"display:none\">Return to game</button>'")
        #expect(try await web.evaluateJavaScript(SteamWebKitOverlay.contentReadyScript) as? Bool == false)
        _ = try await web.evaluateJavaScript("empty.firstChild.style.display='block'")
        #expect(try await web.evaluateJavaScript(SteamWebKitOverlay.contentReadyScript) as? Bool == true)
    }

    @Test
    func unboundWindowCannotPretendToAnswerANativeQuery() async throws {
        let host = SteamWebHost()
        let overlay = SteamWebKitOverlay(host: host)
        let popup = SteamWindow(webView: WKWebView(), role: .gameOverlay,
            name: "desktopoverlay_uid1", size: CGSize(width: 400, height: 300), origin: nil, host: host)
        do {
            _ = try await overlay.windowCall("GetWindowDetails", args: [], popup: popup)
            Issue.record("An unbound window cannot return a fabricated native answer")
        } catch let error as CDPClient.Failure {
            #expect(error == .unreachable("Steam window is not bound"))
        }
    }

    @Test
    func nativeClickHitsTopButtonInInvisibleWebKitSource() async throws {
        let host = SteamWebHost()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let popup = SteamWindow(webView: web, role: .gameOverlay, name: "desktopoverlay_uid1",
            size: CGSize(width: 400, height: 300), origin: nil, host: host)
        popup.realize()
        defer { NativeOverlayInput.reset(web); popup.close() }
        web.loadHTMLString("""
        <button id="action" style="position:absolute;left:10px;top:10px;width:120px;height:40px"
          onclick="window.clicks++">Original action</button><script>window.clicks=0;window.ready=true</script>
        """, baseURL: nil)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("window.ready")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(try await web.evaluateJavaScript("window.ready") as? Bool == true)
        NativeOverlayInput.deliver(["event":"mousedown","x":30,"y":30,"button":0], to: popup)
        NativeOverlayInput.deliver(["event":"mouseup","x":30,"y":30,"button":0], to: popup)
        for _ in 0..<50 {
            if (try? await web.evaluateJavaScript("window.clicks")) as? Int == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await web.evaluateJavaScript("window.clicks") as? Int == 1)
        #expect(popup.nsWindow?.canBecomeKey == false)
        #expect(popup.nsWindow?.alphaValue == 0)
    }


    @Test
    func expiredBridgeCanBeReinstalledWithoutDuplicateHandlers() async throws {
        let web = WKWebView()
        web.loadHTMLString("<button id='button'>Original</button><script>window.ready=true;window.sent=[];window.__sevo=x=>sent.push(JSON.parse(x));window.clicks=0;button.onclick=()=>clicks++</script>", baseURL: nil)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("window.ready")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let url = try #require(Bundle.main.url(forResource: "native_overlay_input", withExtension: "js"))
        let script = try String(contentsOf: url, encoding: .utf8)
        _ = try await web.evaluateJavaScript(script + ";__sevoOverlayInput.ping=0")
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("typeof __sevoOverlayInput==='undefined'")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(try await web.evaluateJavaScript("typeof __sevoOverlayInput==='undefined'") as? Bool == true)
        _ = try await web.evaluateJavaScript("button.click()")
        #expect(try await web.evaluateJavaScript("window.clicks") as? Int == 1)
        let liveScript = script + ";__sevoOverlayInput.ping=Date.now()+60000;__sevoOverlayInput.enabled=true;'ready'"
        _ = try await web.evaluateJavaScript(liveScript)
        _ = try await web.evaluateJavaScript(liveScript)
        _ = try await web.evaluateJavaScript("button.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true}));button.click()")
        #expect(try await web.evaluateJavaScript("sent.length") as? Int == 1)
        #expect(try await web.evaluateJavaScript("window.clicks") as? Int == 1)
        _ = try await web.evaluateJavaScript("__sevoOverlayInput.stop()")
    }

    @Test
    func nativeAdapterUsesTheOriginalRequestWithoutManagingPopupState() async throws {
        let web = WKWebView()
        web.loadHTMLString("""
        <script>
        window.ready=true;window.opened=[];window.nativeCloses=0;
        window.surface={SteamClient:{Browser:{GetBrowserID:()=>71}},closed:false,close(){nativeCloses++}};
        window.open=(url,name,features)=>{opened.push({url,name,features});return surface};
        window.g_PopupManager={GetExistingPopup:()=>null};
        </script>
        """, baseURL: nil)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("window.ready")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let call = "(\(SteamWebKitOverlay.createWindowScript))"
        let request = """
        {name:'friendslist_uid42',query:'createflags=18&pid=42&browser=196610&openerid=17&centerOnBrowserID=16',
         features:'width=300,height=650,resizeable,status=0',ids:{16:4,17:7}}
        """
        #expect(try await web.evaluateJavaScript("\(call)(\(request))") as? String == "71")
        #expect(try await web.evaluateJavaScript("opened.length") as? Int == 1)
        #expect(try await web.evaluateJavaScript("opened[0].name") as? String == "friendslist_uid42")
        #expect(try await web.evaluateJavaScript("opened[0].features") as? String == "width=300,height=650,resizeable,status=0")
        #expect(try await web.evaluateJavaScript("new URL(opened[0].url).searchParams.get('browser')") as? String == "196610")
        #expect(try await web.evaluateJavaScript("new URL(opened[0].url).searchParams.get('openerid')") as? String == "7")
        #expect(try await web.evaluateJavaScript("new URL(opened[0].url).searchParams.get('centerOnBrowserID')") as? String == "4")
        _ = try await web.evaluateJavaScript("g_PopupManager.GetExistingPopup=()=>({m_popup:surface})")
        #expect(try await web.evaluateJavaScript("\(call)(\(request))") as? String == "71")
        #expect(try await web.evaluateJavaScript("opened.length") as? Int == 1)
        #expect(try await web.evaluateJavaScript("nativeCloses") as? Int == 0)
        #expect(try await web.evaluateJavaScript("typeof __sevoOverlayWindows") as? String == "undefined")
    }
}
