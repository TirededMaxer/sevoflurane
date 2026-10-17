import AppKit
import Testing
import WebKit
@testable import Sevoflurane

@MainActor
struct EmbeddedOverlayTests {
    @Test
    func `stable builds never inject the unaccepted compositor`() {
        #expect(EmbeddedOverlayLaunch.library == nil)
        #expect(EmbeddedOverlayLaunch.environment.isEmpty)
    }

    @Test
    func `embedded backing stays invisible and cannot intercept native input`() {
        let popup = SteamWindow(webView: WKWebView(), role: .gameOverlay, name: "desktopoverlay_uid730",
                                size: CGSize(width: 800, height: 600), origin: nil, host: nil)
        let backing = EmbeddedBackingWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        backing.isReleasedWhenClosed = false
        popup.window = backing
        popup.setEmbeddedPresentation(true, frame: NSRect(x: 20, y: 30, width: 800, height: 600))
        #expect(popup.embeddedPresented)
        #expect(popup.isWindowVisible)
        #expect(popup.window?.alphaValue == 0)
        #expect(popup.window?.ignoresMouseEvents == true)
        #expect(popup.window?.isKeyWindow == false)
        popup.setEmbeddedPresentation(false)
        #expect(!popup.isWindowVisible)
        #expect(!popup.embeddedPresented)
        #expect(backing.orderCount == 1)
        #expect(backing.keyCount == 0)
        popup.window = nil
    }

    @Test
    func `hidden backing receives real pointer clicks and keyboard text without taking key`() async throws {
        let host = SteamWebHost()
        let web = host.makeWebView(configuration: WKWebViewConfiguration())
        let popup = SteamWindow(webView: web, role: .gameOverlay, name: "desktopoverlay_fixture",
                                size: CGSize(width: 800, height: 600), origin: nil, host: host)
        host.popups[ObjectIdentifier(web)] = popup
        popup.setEmbeddedPresentation(true, frame: NSRect(x: 120, y: 160, width: 800, height: 600))
        defer { popup.detach(reason: .pageTeardown) }
        let window = try #require(popup.nsWindow)
        web.loadHTMLString("""
        <style>body{margin:0}input,button{position:absolute;left:20px;width:220px;height:40px}input{top:30px}button{top:100px}</style>
        <input id="field"><button id="button" onclick="window.clicks++">Click</button>
        <script>window.clicks=0;window.fixtureReady=true;</script>
        """, baseURL: nil)
        let eval = JavaScriptEvaluator()
        func read(_ js: String) async -> String? {
            await eval.evaluateInWebView(js, webView: web, timeout: .seconds(2))
        }
        for _ in 0..<80 {
            if await read("String(!!window.fixtureReady)") == "true" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(await read("String(!!window.fixtureReady)") == "true")
        func click(x: CGFloat, y: CGFloat) {
            let keyBefore = NSApp.keyWindow
            let inWeb = NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y)
            let point = window.convertPoint(toScreen: web.convert(inWeb, to: nil))
            for kind in [UInt32(1), UInt32(2)] {
                host.embeddedOverlay.route(kind: kind, key: 0, point: point, delta: .zero,
                                           modifiers: [], clicks: 1, text: "")
            }
            #expect(NSApp.keyWindow === keyBefore)
        }
        click(x: 60, y: 50)
        var focused: String?
        for _ in 0..<40 {
            focused = await read("document.activeElement.id")
            if focused == "field" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(focused == "field")
        for text in ["a", "中"] {
            let keyBefore = NSApp.keyWindow
            host.embeddedOverlay.route(kind: 7, key: 0, point: .zero, delta: .zero,
                                       modifiers: [], clicks: 0, text: text)
            host.embeddedOverlay.route(kind: 8, key: 0, point: .zero, delta: .zero,
                                       modifiers: [], clicks: 0, text: text)
            #expect(NSApp.keyWindow === keyBefore)
        }
        var value: String?
        for _ in 0..<40 {
            value = await read("document.getElementById('field').value")
            if value == "a中" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        // This checks Unicode key-event delivery; live IME composition is a
        // separate acceptance item and is not implied by the Chinese string.
        #expect(value == "a中")
        click(x: 60, y: 120)
        var clicks: String?
        for _ in 0..<40 {
            clicks = await read("String(window.clicks)")
            if clicks == "1" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(clicks == "1")
        #expect(window.alphaValue == 0)
        #expect(window.ignoresMouseEvents)
        #expect(!window.isKeyWindow)
    }

    @Test
    func `Retina capture keeps native pixel dimensions and refuses oversized frames`() throws {
        let size = try #require(EmbeddedSteamOverlay.captureSize(frame: NSRect(x: 0, y: 0, width: 1512, height: 982), scale: 2))
        #expect(size.width == 3024 && size.height == 1964)
        #expect(EmbeddedSteamOverlay.captureSize(frame: NSRect(x: 0, y: 0, width: 2560, height: 1440), scale: 2) == nil)
    }

    @Test
    func `CrossOver wrapper quotes paths without invoking a shell`() {
        let result = EmbeddedOverlayLaunch.wrapperEnvironment([
            "SEVO_OVERLAY_BRIDGE": "/Users/Name With Space/Overlay/cs2.surface",
            "DYLD_INSERT_LIBRARIES": "/Applications/A \"Test\".app/lib.dylib",
        ])
        #expect(result == "DYLD_INSERT_LIBRARIES=\"/Applications/A \\\"Test\\\".app/lib.dylib\" SEVO_OVERLAY_BRIDGE=\"/Users/Name With Space/Overlay/cs2.surface\"")
    }
}

@MainActor
private final class EmbeddedBackingWindow: NSWindow {
    var orderCount = 0
    var keyCount = 0
    override func orderFront(_: Any?) { orderCount += 1 }
    override func orderOut(_: Any?) {}
    override func makeKey() { keyCount += 1 }
}
