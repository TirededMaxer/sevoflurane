import AppKit
import Testing
import WebKit
@testable import Sevoflurane

@MainActor
struct EmbeddedOverlayTests {
    @Test
    func `embedded backing stays invisible and cannot intercept native input`() {
        let popup = SteamWindow(webView: WKWebView(), role: .gameOverlay, name: "desktopoverlay_uid730",
                                size: CGSize(width: 800, height: 600), origin: nil, host: nil)
        popup.setEmbeddedPresentation(true, frame: NSRect(x: 20, y: 30, width: 800, height: 600))
        #expect(popup.embeddedPresented)
        #expect(popup.isWindowVisible)
        #expect(popup.window?.alphaValue == 0)
        #expect(popup.window?.ignoresMouseEvents == true)
        #expect(popup.window?.isKeyWindow == false)
        popup.setEmbeddedPresentation(false)
        #expect(!popup.isWindowVisible)
        #expect(!popup.embeddedPresented)
        popup.window?.close()
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
