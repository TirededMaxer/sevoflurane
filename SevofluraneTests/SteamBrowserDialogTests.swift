import AppKit
import Testing
import WebKit
@testable import Sevoflurane

@MainActor
struct SteamBrowserDialogTests {
    @Test(arguments: [true, false])
    func originalConfirmEventWaitsForSteamResponse(_ accepted: Bool) async throws {
        let (child, page) = try await fixture()
        defer { child.destroy() }
        let result = Task { @MainActor in
            try await child.webView.evaluateJavaScript("String(confirm('Original warning 原始提示'))") as? String
        }
        let event = try await waitForDialog(page)
        #expect(event == #"{"event":"confirm-dialog","args":["Original warning 原始提示"]}"#)
        child.respondToJavaScriptDialog(accepted)
        #expect(try await result.value == String(accepted))
        child.respondToJavaScriptDialog(!accepted) // A repeated reply has no completion left to invoke.
    }

    @Test
    func originalAlertAcknowledgesAndTeardownCancelsConfirm() async throws {
        let (child, page) = try await fixture()
        defer { child.destroy() }
        let alert = Task { @MainActor in
            try await child.webView.evaluateJavaScript("alert('Original alert');'acknowledged'") as? String
        }
        #expect(try await waitForDialog(page).contains("alert-dialog"))
        child.respondToJavaScriptDialog(true)
        #expect(try await alert.value == "acknowledged")
        _ = try await page.evaluateJavaScript("window.lastDialog=null")
        let confirm = Task { @MainActor in
            try await child.webView.evaluateJavaScript("String(confirm('Closing browser'))") as? String
        }
        _ = try await waitForDialog(page)
        child.destroy()
        #expect(try await confirm.value == "false")
    }

    private func fixture() async throws -> (BrowserViewChild, WKWebView) {
        let page = WKWebView()
        page.loadHTMLString("""
        <script>window.__sevoBV={91:function(event,args){if(event.endsWith('-dialog'))
          window.lastDialog=JSON.stringify({event:event,args:args})}};window.ready=true;</script>
        """, baseURL: nil)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let child = BrowserViewChild(id: 91, container: container, hostPage: page, host: SteamWebHost())
        child.webView.loadHTMLString("<script>window.ready=true;</script>", baseURL: nil)
        for web in [page, child.webView] {
            for _ in 0..<80 {
                if (try? await web.evaluateJavaScript("window.ready===true")) as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            _ = try #require(try await web.evaluateJavaScript("window.ready===true") as? Bool == true)
        }
        return (child, page)
    }

    private func waitForDialog(_ page: WKWebView) async throws -> String {
        for _ in 0..<80 {
            if let result = try? await page.evaluateJavaScript("window.lastDialog || ''") as? String,
               !result.isEmpty { return result }
            try await Task.sleep(for: .milliseconds(25))
        }
        let result = try await page.evaluateJavaScript("window.lastDialog || ''") as? String
        return try #require(result.flatMap { $0.isEmpty ? nil : $0 })
    }
}
