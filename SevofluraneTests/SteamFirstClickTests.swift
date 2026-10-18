import AppKit
import Testing
import WebKit
@testable import Sevoflurane

@MainActor
struct SteamFirstClickTests {
    @Test
    func regularInactiveAppFinishesTheSamePressWhenActivationActuallyCompletes() throws {
        let owner = SteamWindow(webView: SteamWebView(), role: .desktop, name: "first-click-test",
                                size: CGSize(width: 600, height: 400), origin: nil, host: nil)
        let window = FocusRecordingWindow()
        owner.window = window
        window.contentView = owner.webView
        defer { owner.cancelPendingKeyboardPress(); window.close() }
        let surface = RecordingActivationSurface()
        surface.appPolicy = .regular
        surface.appIsActive = false
        surface.activateSelfImmediately = false
        owner.takeKeyboardForUserPress(try click(window), activation: Activation(surface: surface))
        #expect(window.keyRequests == 0)
        #expect(surface.steps == [.activateSelf])
        surface.appIsActive = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        #expect(window.keyRequests == 1)
        // A repeated notification must not replay the gesture or steal focus.
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        #expect(window.keyRequests == 1)
        #expect(surface.steps == [.activateSelf])
    }

    @Test
    func aCancelledPressCannotTakeFocusAtSomeLaterActivation() throws {
        let owner = SteamWindow(webView: SteamWebView(), role: .desktop, name: "cancel-click-test",
                                size: CGSize(width: 600, height: 400), origin: nil, host: nil)
        let window = FocusRecordingWindow()
        owner.window = window
        defer { owner.cancelPendingKeyboardPress(); window.close() }
        let surface = RecordingActivationSurface()
        surface.appPolicy = .regular
        surface.activateSelfImmediately = false
        owner.takeKeyboardForUserPress(try click(window), activation: Activation(surface: surface))
        owner.cancelPendingKeyboardPress()
        surface.appIsActive = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        #expect(window.keyRequests == 0)
    }

    @Test
    func firstMouseBelongsToDesktopContentAndItsDragSurface() {
        let web = SteamWebView()
        let content = SteamContentView(frame: .zero)
        #expect(web.acceptsFirstMouse(for: nil))
        #expect(content.acceptsFirstMouse(for: nil))
    }

    private func click(_ window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: 100),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
    }
}

@MainActor
private final class FocusRecordingWindow: NSWindow {
    var keyRequests = 0
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                   styleMask: [.titled], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }
    override var isVisible: Bool { true }
    override func makeKeyAndOrderFront(_ sender: Any?) { keyRequests += 1 }
}
