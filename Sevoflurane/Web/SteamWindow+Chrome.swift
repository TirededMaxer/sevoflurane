import AppKit
import WebKit

extension SteamWindow {
    /// The per-role window dressing: title bar treatment, background, level,
    /// and visibility behavior.
    func applyRoleChrome(to window: NSWindow) {
        switch role {
        case .auxiliary, .controllerConfig, .friends, .chat:
            applyPopupChrome(to: window)
            window.collectionBehavior.insert(.fullScreenPrimary)
        case .desktop, .login:
            applyDesktopChrome(to: window)
        case .bigPicture:
            window.title = "Big Picture"
            window.backgroundColor = Self.steamBackground
            window.collectionBehavior.insert(.fullScreenPrimary)
        case .menu, .hover:
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .popUpMenu
            webView.underPageBackgroundColor = .clear
            // Menus stay ordered-in for their whole life, invisible at alpha
            // 0 — see `hide()`. Ordering in at realize time (adoption) means
            // even a menu's first show has no page-visibility gap, and
            // `hidesOnDeactivate` would order out and reopen the gap; Steam
            // dismisses menus on deactivation itself.
            window.hidesOnDeactivate = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        case .keyboard:
            // The keyboard floats over whatever is being typed into and stays
            // up while another app is frontmost.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .floating
            window.hidesOnDeactivate = false
            webView.underPageBackgroundColor = .clear
        case .gameOverlay:
            break // Owned by the original game renderer; never realized here.
        case .dialog:
            // Reconnect and other web dialogs share the page-integrated
            // controls used by sign-in. Keep their existing modal behavior.
            applyPopupChrome(to: window)
            window.hasShadow = true
            window.hidesOnDeactivate = false
        case .toast:
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            // Wine's fullscreen game is level 26, above the status bar (25).
            // A non-activating popup-menu-level panel remains visible over it.
            window.level = .popUpMenu
            window.hidesOnDeactivate = false
            window.isExcludedFromWindowsMenu = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            webView.underPageBackgroundColor = .clear
        case .context:
            break
        }
        if role.hasNativeFrame, role != .desktop, role != .bigPicture {
            window.title = webView.title ?? "Steam"
            titleObservation = webView.observe(\.title) { [weak window] view, _ in
                onMainThread {
                    guard let title = view.title, !title.isEmpty else { return }
                    window?.title = title
                }
            }
        }
    }

    /// A popup that carries its own header: the macOS title bar is
    /// transparent, and the title follows the page's.
    private func applyPopupChrome(to window: NSWindow) {
        // Steam names its own popups through the document title —
        // "Friends List", or the name of whoever a chat window is with.
        // The page's own header is the title bar (see
        // `SteamWindowRole.hasPopupChrome`), so the macOS one is
        // transparent and titleless; the title is kept for Mission
        // Control and the Window menu.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.title = webView.title ?? "Steam"
        window.backgroundColor = Self.steamBackground
    }

    /// The desktop and sign-in windows, whose title bar Steam draws itself.
    private func applyDesktopChrome(to window: NSWindow) {
        // The AppKit titlebar supplies native controls over Steam's top strip.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = Self.steamBackground
        // These are ordinary app windows, even when first created by the
        // menu-bar accessory. Never inherit membership in another app's
        // fullscreen Space; the user may still fullscreen Steam itself.
        window.level = .normal
        window.collectionBehavior = [.primary, .managed, .fullScreenPrimary]
        if role == .desktop {
            window.title = "Steam"
            window.toolbar = NSToolbar()
            window.toolbarStyle = .unifiedCompact
        }
    }

    static let steamBackground = NSColor(
        srgbRed: 0.086,
        green: 0.106,
        blue: 0.133,
        alpha: 1,
    )
}
