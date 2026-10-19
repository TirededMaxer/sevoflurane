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
}
