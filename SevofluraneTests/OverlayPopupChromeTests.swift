import AppKit
import Testing
import WebKit
@testable import Sevoflurane

@MainActor
struct OverlayPopupChromeTests {
    @Test
    func `overlay popup panels retain close controls without activating the app`() throws {
        for role in [SteamWindowRole.friends, .chat, .auxiliary, .controllerConfig] {
            let panel = SteamPanel(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                hasTitleBar: role.hasPopupChrome,
            )
            #expect(panel.styleMask.contains(.nonactivatingPanel))
            #expect(panel.styleMask.contains(.titled))
            #expect(panel.styleMask.contains(.closable))
            let closeButton = try #require(panel.standardWindowButton(.closeButton))
            #expect(!closeButton.isHidden)
            #expect(closeButton.isEnabled)
        }
    }

    @Test
    func `menus and the full game overlay remain borderless`() {
        for role in [SteamWindowRole.menu, .gameOverlay] {
            let panel = SteamPanel(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                hasTitleBar: role.hasPopupChrome,
            )
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
