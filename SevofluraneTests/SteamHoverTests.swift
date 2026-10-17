import AppKit
import Testing
import WebKit
@testable import Sevoflurane

@MainActor
struct SteamHoverTests {
    @Test
    func aNonKeyMenuUsesSteamHoverStylesAndReactEnterLeave() async throws {
        let webView = WKWebView()
        let owner = SteamWindow(webView: webView, role: .menu, name: "hover-test", size: CGSize(width: 220, height: 160), origin: nil, host: nil)
        owner.realize()
        defer { owner.detach(reason: .pageTeardown) }
        owner.show(activating: false)
        let window = try #require(owner.nsWindow)
        let content = try #require(window.contentView as? SteamContentView)
        webView.loadHTMLString("""
        <style>body{margin:0}.row{height:60px;background:rgb(10,20,30)}.row:hover{background:rgb(220,222,223)}.row.disabled:hover{background:rgb(10,20,30)}@media(min-width:1px){.row:hover span{color:rgb(61,68,80)}}</style>
        <div id="one" class="row"><span>First</span></div><div id="two" class="row">Second</div>
        <script>
        window.entered=[];window.left=[];
        for(const n of document.querySelectorAll('.row'))n.__reactProps$fixture={onMouseEnter:()=>entered.push(n.id),onMouseLeave:()=>left.push(n.id)};
        </script>
        """, baseURL: nil)
        let evaluator = JavaScriptEvaluator()
        for _ in 0..<60 {
            if await evaluator.evaluateInWebView("String(!!window.entered)", webView: webView, timeout: .seconds(2)) == "true" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        func move(y: CGFloat, type: NSEvent.EventType = .mouseMoved) throws -> NSEvent {
            if type == .mouseMoved {
                return try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 20, y: content.bounds.height - y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
            }
            return try #require(NSEvent.enterExitEvent(with: type, location: NSPoint(x: 20, y: content.bounds.height - y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
        }
        content.mouseEntered(with: try move(y: 20, type: .mouseEntered))
        content.mouseMoved(with: try move(y: 20))
        func read(_ script: String) async -> String? {
            await evaluator.evaluateInWebView(script, webView: webView, timeout: .seconds(2))
        }
        // Evaluate calls follow the native dispatch in WebKit's event queue.
        var hovered: String?
        for _ in 0..<40 {
            hovered = await read("String(document.querySelector('#one').hasAttribute('data-sevo-hover'))")
            if hovered == "true" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(hovered == "true")
        #expect(await read("getComputedStyle(document.querySelector('#one')).backgroundColor") == "rgb(220, 222, 223)")
        #expect(await read("getComputedStyle(document.querySelector('#one span')).color") == "rgb(61, 68, 80)")
        #expect(await read("JSON.stringify(entered)") == #"["one"]"#)
        // Enter is unthrottled and covers a fast transition to the next item.
        content.mouseEntered(with: try move(y: 80, type: .mouseEntered))
        content.mouseMoved(with: try move(y: 80))
        #expect(await read("JSON.stringify(entered)") == #"["one","two"]"#)
        #expect(await read("JSON.stringify(left)") == #"["one"]"#)
        #expect(await read("getComputedStyle(document.querySelector('#two')).backgroundColor") == "rgb(220, 222, 223)")
        #expect(await read("getComputedStyle(document.querySelector('#one')).backgroundColor") == "rgb(10, 20, 30)")
        #expect(await read("document.querySelector('#two').classList.add('disabled'); getComputedStyle(document.querySelector('#two')).backgroundColor") == "rgb(10, 20, 30)")
        #expect(await read("document.querySelector('#two').classList.remove('disabled'); getComputedStyle(document.querySelector('#two')).backgroundColor") == "rgb(220, 222, 223)")
        // Selection/navigation must clear the native and relayed hover too.
        owner.clearMenuHover()
        #expect(await read("String(document.querySelectorAll('[data-sevo-hover]').length)") == "0")
        content.mouseExited(with: try move(y: 180, type: .mouseExited))
        #expect(await read("JSON.stringify(left)") == #"["one","two"]"#)
        #expect(await read("getComputedStyle(document.querySelector('#two')).backgroundColor") == "rgb(10, 20, 30)")
    }
}
