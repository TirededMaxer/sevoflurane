import AppKit
import Testing
import WebKit
@testable import Sevoflurane

@MainActor
struct ScreenPlacementTests {
    /// A wide display at the origin with a portrait one to its left, which is
    /// the layout the 2026-09-08 playtest ran on.
    private let displays = [
        CGRect(x: 0, y: 0, width: 3840, height: 2160),
        CGRect(x: -1440, y: 0, width: 1440, height: 2560),
    ]

    @Test
    func independentWindowsIgnoreInitialSteamPositionAndRecenterAfterSizing() throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        for role in [SteamWindowRole.desktop, .bigPicture, .login, .controllerConfig, .auxiliary, .friends, .chat, .dialog] {
            let owner = SteamWindow(webView: WKWebView(), role: role, name: "center-test", size: CGSize(width: 600, height: 360), origin: CGPoint(x: 2, y: 2), host: nil)
            owner.realize()
            defer { owner.detach(reason: .pageTeardown) }
            let window = try #require(owner.nsWindow)
            func expectCentered() {
                #expect(abs(window.frame.midX - screen.visibleFrame.midX) < 0.5, "\(role)")
                #expect(abs(window.frame.midY - screen.visibleFrame.midY) < 0.5, "\(role)")
            }
            expectCentered()
            owner.moveTo(x: 0, y: 0)
            owner.resizeTo(width: 620, height: 380)
            expectCentered()
            owner.positionRelative(toWindowNamed: "none", x: 1, y: 1, width: 640, height: 400)
            owner.prepareOpeningPlacement()
            expectCentered()
            let moved = NSPoint(x: window.frame.minX + 30, y: window.frame.minY + 20)
            window.setFrameOrigin(moved)
            owner.prepareOpeningPlacement()
            #expect(window.frame.origin == moved, "Re-showing a visible window keeps its user position")
            _ = owner.perform("HideWindow", [])
            owner.prepareOpeningPlacement()
            expectCentered()
        }
    }

    @Test
    func overlayChildOpensCenteredWithoutChangingRootOverlayOrToastPlacement() throws {
        let host = SteamWebHost()
        host.overlayActive = true
        let child = SteamWindow(webView: WKWebView(), role: .chat, name: "chat_uid123", size: CGSize(width: 600, height: 360), origin: CGPoint(x: 0, y: 0), host: host)
        child.realize()
        defer { child.detach(reason: .pageTeardown) }
        child.prepareOpeningPlacement()
        let window = try #require(child.nsWindow)
        let screen = try #require(window.screen)
        #expect(abs(window.frame.midX - screen.visibleFrame.midX) < 0.5)
        #expect(abs(window.frame.midY - screen.visibleFrame.midY) < 0.5)
        _ = child.perform("SetHideOnClose", [true])
        window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY))
        #expect(!child.windowShouldClose(window))
        child.prepareOpeningPlacement()
        #expect(abs(window.frame.midX - screen.visibleFrame.midX) < 0.5)
        #expect(abs(window.frame.midY - screen.visibleFrame.midY) < 0.5)
        #expect(!SteamWindowRole.gameOverlay.needsAReachableFrame)
        #expect(!SteamWindowRole.toast.needsAReachableFrame)
    }

    @Test
    func exactCenterUsesUsableDisplayIncludingNegativeCoordinates() {
        #expect(WindowPlacement.centeredOrigin(size: NSSize(width: 600, height: 400), in: NSRect(x: -1440, y: 40, width: 1440, height: 2500)) == NSPoint(x: -1020, y: 1090))
    }

    @Test
    func `a window inside a display is on a screen`() {
        #expect(SteamScreenSpace.isOnSomeScreen(
            CGRect(x: 200, y: 200, width: 1280, height: 800), screens: displays,
        ))
    }

    @Test
    func `a window on the display at a negative x is on a screen`() {
        #expect(SteamScreenSpace.isOnSomeScreen(
            CGRect(x: -1440, y: 804, width: 1440, height: 1110), screens: displays,
        ))
    }

    @Test
    func `the parked context page is on no screen`() {
        #expect(!SteamScreenSpace.isOnSomeScreen(
            CGRect(x: -20_000, y: -20_000, width: 1280, height: 800), screens: displays,
        ))
    }

    @Test
    func `a frame saved on a display that has been unplugged is on no screen`() {
        #expect(!SteamScreenSpace.isOnSomeScreen(
            CGRect(x: -1440, y: 804, width: 1440, height: 1110), screens: [displays[0]],
        ))
    }

    /// The corner above the wide display and right of the portrait one is
    /// inside the box around both and covered by neither.
    @Test
    func `the empty corner of an L-shaped layout is on no screen`() {
        let corner = CGRect(x: 100, y: 2300, width: 400, height: 200)
        let union = displays.reduce(CGRect.null) { $0.union($1) }
        #expect(union.intersects(corner))
        #expect(!SteamScreenSpace.isOnSomeScreen(corner, screens: displays))
    }

    @Test
    func `a window with no displays at all is on no screen`() {
        #expect(!SteamScreenSpace.isOnSomeScreen(
            CGRect(x: 0, y: 0, width: 100, height: 100), screens: [],
        ))
    }

    @Test
    func `the windows a person goes looking for are the ones held to a screen`() {
        for role in [
            SteamWindowRole.desktop, .bigPicture, .login, .controllerConfig,
            .auxiliary, .friends, .chat, .dialog,
        ] {
            #expect(role.needsAReachableFrame, "\(role) is a window a person opens")
        }
    }

    /// Steam parks a context menu at (99788, 99544) between uses and places
    /// it against its parent on every show; pulling it back onto a display
    /// would leave menus stacked in the middle of the screen.
    @Test
    func `the windows Steam parks nowhere are left where it puts them`() {
        for role in [SteamWindowRole.context, .menu, .keyboard, .toast, .gameOverlay] {
            #expect(!role.needsAReachableFrame, "\(role) is one Steam places itself")
        }
    }
}
