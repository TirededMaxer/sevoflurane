import AppKit
import Testing
import WebKit
@testable import Sevoflurane

extension AppKitPresentationTests {
    @MainActor
    struct LoginDockPolicyTests {
        @Test
        func hidingOrClosingTheLastLoginWindowReturnsToAccessory() {
            let previous = NSApp.activationPolicy()
            defer { NSApp.setActivationPolicy(previous) }
            let host = SteamWebHost()
            let login = SteamWindow(webView: WKWebView(), role: .login, name: "SP DesktopLoginWindow_uid0",
                                    size: CGSize(width: 400, height: 300), origin: nil, host: host)
            host.popups[ObjectIdentifier(login.webView)] = login
            login.realize()
            login.nsWindow?.orderFront(nil)
            ActivationPolicy.becomeRegular()
            _ = login.perform("HideWindow", [])
            #expect(NSApp.activationPolicy() == .accessory)
            login.nsWindow?.orderFront(nil)
            ActivationPolicy.becomeRegular()
            login.detach(reason: .pageTeardown)
            #expect(NSApp.activationPolicy() == .accessory)
        }

        @Test
        func aVisibleSettingsWindowKeepsTheDockAfterLoginCloses() {
            let previous = NSApp.activationPolicy()
            let settings = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
            settings.isReleasedWhenClosed = false
            settings.orderFront(nil)
            defer { settings.close(); NSApp.setActivationPolicy(previous) }
            ActivationPolicy.becomeRegular()
            let host = SteamWebHost()
            let login = SteamWindow(webView: WKWebView(), role: .login, name: "SP DesktopLoginWindow_uid0",
                                    size: CGSize(width: 400, height: 300), origin: nil, host: host)
            login.realize()
            login.nsWindow?.orderFront(nil)
            login.detach(reason: .pageTeardown)
            #expect(NSApp.activationPolicy() == .regular)
        }
    }
}
