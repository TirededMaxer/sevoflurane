import AppKit
import Testing
import WebKit
@testable import Sevoflurane

@MainActor
struct OverlayPopupChromeTests {
    @Test
    func `desktop and login remain activating windows while overlay is open`() {
        let host = SteamWebHost()

        for role in [SteamWindowRole.desktop, .login] {
            let popup = SteamWindow(webView: WKWebView(), role: role, name: "scope-test",
                                    size: CGSize(width: 400, height: 300), origin: nil, host: host)
            popup.realize()
            #expect(!(popup.window is NSPanel))
            #expect(popup.window?.styleMask.contains(.nonactivatingPanel) == false)
            popup.window?.close()
        }
    }

    @Test
    func `menus and on screen keyboard remain borderless panels`() throws {
        for role in [SteamWindowRole.menu, .keyboard] {
            let owner = popup(role: role)
            owner.realize()
            defer { owner.detach(reason: .pageTeardown) }
            let panel = try #require(owner.nsWindow as? SteamPanel)
            #expect(panel.styleMask.contains(.nonactivatingPanel))
            #expect(!panel.styleMask.contains(.titled))
            #expect(panel.standardWindowButton(.closeButton) == nil)
        }
    }

    @Test
    func `reported title strip starts an explicit native drag`() throws {
        let owner = popup(role: .friends)
        let window = DragWindow()
        let content = SteamContentView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        content.owner = owner
        window.contentView = content
        _ = owner.perform("__dragRegions", [[[80, 0, 300, 28]]])
        let event = try click(x: 100, y: 286, window: window)
        content.mouseDown(with: event)
        #expect(window.dragCount == 1)

        // Body clicks still belong to WebKit and must not move the window.
        content.mouseDown(with: try click(x: 100, y: 100, window: window))
        #expect(window.dragCount == 1)
    }

    @Test
    func `the game sized overlay never starts a native window drag`() throws {
        let owner = popup(role: .gameOverlay)
        let window = DragWindow()
        let content = SteamContentView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        content.owner = owner
        window.contentView = content
        _ = owner.perform("__dragRegions", [[[0, 0, 400, 300]]])
        content.mouseDown(with: try click(x: 100, y: 286, window: window))
        #expect(window.dragCount == 0)
    }

    @Test
    func `desktop chat follows Steam show while the original overlay is active`() {
        let host = SteamWebHost()

        let owner = chat(named: "chat_ChatWindow_4_uid0", host: host)
        let window = OrderWindow()
        owner.window = window

        owner.show(activating: false)
        #expect(window.orderCount == 1)
        _ = owner.perform("HideWindow", [])
        #expect(window.hideCount == 1)
    }

    @Test
    func `game chat never orders a desktop window`() {
        let host = SteamWebHost()

        let owner = chat(named: "chat_ChatWindow_5_uid1320", host: host)
        let window = OrderWindow()
        owner.window = window

        owner.show(activating: false)
        #expect(owner.usesOriginalGameOverlay)
        #expect(window.orderCount == 0)
    }

    @Test
    func `desktop chat works normally when the overlay is closed`() {
        let host = SteamWebHost()
        let owner = chat(named: "chat_ChatWindow_4_uid0", host: host)
        let window = OrderWindow()
        owner.window = window

        owner.show(activating: false)
        #expect(window.orderCount == 1)
    }

    private func chat(named name: String, host: SteamWebHost) -> SteamWindow {
        SteamWindow(
            webView: WKWebView(), role: .chat, name: name,
            size: CGSize(width: 400, height: 300), origin: nil, host: host,
        )
    }

    private func popup(role: SteamWindowRole) -> SteamWindow {
        SteamWindow(
            webView: WKWebView(), role: role, name: "drag-test",
            size: CGSize(width: 400, height: 300), origin: nil, host: nil,
        )
    }

    private func click(x: CGFloat, y: CGFloat, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: x, y: y),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1,
        ))
    }
}

@MainActor
private final class DragWindow: NSWindow {
    var dragCount = 0

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false,
        )
    }

    override func performDrag(with _: NSEvent) {
        dragCount += 1
    }
}

@MainActor
private final class OrderWindow: NSWindow {
    var orderCount = 0
    var hideCount = 0

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false,
        )
        isReleasedWhenClosed = false
    }

    override func orderFrontRegardless() { orderCount += 1 }
    override func orderFront(_: Any?) { orderCount += 1 }
    override func orderOut(_: Any?) { hideCount += 1 }
}
