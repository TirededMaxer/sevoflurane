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
