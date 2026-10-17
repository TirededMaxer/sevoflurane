import AppKit

/// Exact centering within the usable display, without AppKit’s upward bias.
@MainActor
enum WindowPlacement {
    /// Native windows use AppKit's frame persistence. Steam saves only after
    /// showing, so its initial CEF move/resize calls cannot overwrite a restore.
    static func restoreOrCenter(_ window: NSWindow, key: String, on screen: NSScreen? = nil, autoSave: Bool = true) {
        let restored = window.setFrameUsingName(key, force: true)
        if !restored || !SteamScreenSpace.isOnSomeScreen(window.frame) {
            center(window, on: screen)
        }
        if autoSave { window.setFrameAutosaveName(key) }
    }

    static func center(_ window: NSWindow, on preferred: NSScreen? = nil) {
        guard let screen = preferred ?? NSScreen.main ?? window.screen ?? NSScreen.screens.first else { return }
        window.setFrameOrigin(centeredOrigin(size: window.frame.size, in: screen.visibleFrame))
    }

    static func centeredOrigin(size: NSSize, in visible: NSRect) -> NSPoint {
        NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
    }
}
