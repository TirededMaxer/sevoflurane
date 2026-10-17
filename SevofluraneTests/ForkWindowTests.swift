import AppKit
import Testing
import WebKit
@testable import Sevoflurane

@MainActor
struct ForkWindowTests {
    @Test
    func desktopTitleStripDragsAndDoubleClickMaximizes() throws {
        let owner = SteamWindow(webView: WKWebView(), role: .desktop, name: "SP Desktop_uid0", size: CGSize(width: 900, height: 600), origin: nil, host: nil)
        let window = TrackingWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let view = SteamContentView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        view.owner = owner
        window.contentView = view
        _ = owner.perform("__dragRegions", [[[80, 0, 500, 40]]])
        func click(_ count: Int, y: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 180, y: y), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 1))
        }
        view.mouseDown(with: try click(1, y: 580))
        #expect(window.drags == 1)
        view.mouseDown(with: try click(2, y: 580))
        #expect(window.zooms == 1)
        #expect(window.drags == 1)
        view.mouseDown(with: try click(2, y: 300))
        #expect(window.zooms == 1)
    }

    @Test
    func desktopToolbarRouteIgnoresContentAndOtherWindows() throws {
        let owner = SteamWindow(webView: WKWebView(), role: .desktop, name: "title-route-test", size: CGSize(width: 900, height: 600), origin: nil, host: nil)
        owner.realize()
        defer { owner.detach(reason: .pageTeardown) }
        let window = try #require(owner.nsWindow)
        window.setFrameAutosaveName("")
        _ = owner.perform("__dragRegions", [[[80, 0, 500, 40]]])
        let content = try #require(window.contentView)
        func event(at point: NSPoint, in target: NSWindow) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: target.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1))
        }
        let body = content.convert(NSPoint(x: 180, y: 200), to: nil)
        #expect(!owner.handleTitleStripMouseDown(try event(at: body, in: window)))
        let other = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        #expect(!owner.handleTitleStripMouseDown(try event(at: NSPoint(x: 180, y: 580), in: other)))
        let header = content.convert(NSPoint(x: 180, y: content.bounds.height - 20), to: nil)
        #expect(owner.handleTitleStripMouseDown(try event(at: header, in: window)))
    }

    @Test
    func steamToastUsesBottomRightAndNeverTakesFocus() {
        let host = SteamWebHost()
        host.overlayActive = true
        let toast = SteamWindow(webView: WKWebView(), role: .toast, name: "notificationtoasts_1_desktop", size: CGSize(width: 360, height: 90), origin: nil, host: host)
        toast.realize()
        #expect(toast.nsWindow is SteamToastPanel)
        #expect(toast.nsWindow?.canBecomeKey == false)
        #expect(toast.nsWindow?.canBecomeMain == false)
        #expect(toast.nsWindow?.hidesOnDeactivate == false)
        #expect(SteamWindowRole.toast.isPanel)
        #expect(SteamWindowRole.toast.isShowable)
        #expect(SteamWindow.toastOrigin(size: NSSize(width: 360, height: 90), visibleFrame: NSRect(x: 100, y: 40, width: 1400, height: 900)) == NSPoint(x: 1128, y: 52))
        toast.close()
    }

    @Test
    func packagedNativeDialogHelperExists() {
        #expect(NativeSteamDialogs.helperURL != nil)
    }

    @Test
    func nativeDialogRetainsUnicodeAndButtonIdentity() throws {
        let scan = #"{"dialogs":[{"handle":65618,"pid":204,"title":"Steam \u6d4b\u8bd5\u9519\u8bef","body":"\u8fde\u63a5\u5931\u8d25","buttons":[{"id":1,"title":"\u786e\u5b9a"},{"id":2,"title":"\u53d6\u6d88"}]}]}"#
        let dialogs = SteamNativeDialog.decode("Wine startup message\n" + scan + "\n")
        let dialog = try #require(dialogs.first)
        #expect(dialog.title == "Steam 测试错误")
        #expect(dialog.body == "连接失败")
        #expect(dialog.buttons.map(\.id) == [1, 2])
        #expect(dialog.buttons.map(\.title) == ["确定", "取消"])
        #expect(dialog.identity == "204:65618")
        #expect(SteamNativeDialog.decode("not a scan").isEmpty)
    }
}

@MainActor
private final class TrackingWindow: NSWindow {
    var drags = 0
    var zooms = 0
    override func performDrag(with event: NSEvent) { drags += 1 }
    override func zoom(_ sender: Any?) { zooms += 1 }
}
