import Foundation
import Testing
import WebKit
@testable import Sevoflurane

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
        #expect(try await web.evaluateJavaScript(script) as? String == "ready")
        _ = try await web.evaluateJavaScript("window.__sevoOverlayInput.enabled=true")
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
    func earlyWindowQueryWaitsForBindingAndHonorsCancellation() async throws {
        let host = SteamWebHost()
        let overlay = SteamWebKitOverlay(host: host)
        let popup = SteamWindow(webView: WKWebView(), role: .gameOverlay,
            name: "desktopoverlay_uid1", size: CGSize(width: 400, height: 300), origin: nil, host: host)
        var completed = false
        let query = Task { @MainActor in
            defer { completed = true }
            _ = try await overlay.windowCall("GetWindowDetails", args: [], popup: popup)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!completed)
        query.cancel()
        do {
            _ = try await query.value
            Issue.record("An unavailable binding cannot answer a window query with nil")
        } catch is CancellationError {} catch { Issue.record("Unexpected failure: \(error)") }
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

}
