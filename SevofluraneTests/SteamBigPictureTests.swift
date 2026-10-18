import AppKit
import Testing
import WebKit
@testable import Sevoflurane

@MainActor
struct SteamBigPictureTests {
    @Test
    func originalCreationFlagEntersAndLeavesRealFullscreen() async throws {
        let popup = SteamWindow(webView: WKWebView(), role: .auxiliary, name: "",
            size: CGSize(width: 900, height: 600), origin: nil, host: nil)
        popup.adopt(name: "SP BPM_uid0", parameters: "createflags=6292753")
        defer { popup.detach(reason: .pageTeardown) }
        #expect(popup.role == .bigPicture)
        #expect(popup.requestsInitialFullScreen)
        let window = try #require(popup.nsWindow)
        let original = window.frame
        let completed = FullscreenCompletion()
        let entered = NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification,
            object: window, queue: .main) { _ in MainActor.assumeIsolated { completed.entered = true } }
        let exited = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification,
            object: window, queue: .main) { _ in MainActor.assumeIsolated { completed.exited = true } }
        defer { NotificationCenter.default.removeObserver(entered); NotificationCenter.default.removeObserver(exited) }
        popup.show(activating: true)
        for _ in 0..<100 {
            if completed.entered { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(completed.entered)
        #expect(window.styleMask.contains(.fullScreen))
        #expect(window.frame == window.screen?.frame)
        // CEF's Window.ToggleFullScreen binding stays the exit operation.
        _ = popup.perform("ToggleFullScreen", [])
        for _ in 0..<100 {
            if completed.exited { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(completed.exited)
        #expect(!window.styleMask.contains(.fullScreen))
        #expect(window.frame == original)
    }

    @Test
    func windowedBigPictureDoesNotAcquireFullscreen() {
        let popup = SteamWindow(webView: WKWebView(), role: .auxiliary, name: "",
            size: CGSize(width: 900, height: 600), origin: nil, host: nil)
        popup.adopt(name: "SP BPM_uid0", parameters: "createflags=6291729")
        defer { popup.detach(reason: .pageTeardown) }
        #expect(!popup.requestsInitialFullScreen)
        #expect(popup.nsWindow?.styleMask.contains(.fullScreen) == false)
    }
}

@MainActor
private final class FullscreenCompletion {
    var entered = false
    var exited = false
}
