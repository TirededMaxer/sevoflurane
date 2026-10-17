import AppKit

/// Exact centering within the usable display, without AppKit’s upward bias.
@MainActor
enum WindowPlacement {
    static func center(_ window: NSWindow, on preferred: NSScreen? = nil) {
        guard let screen = preferred ?? NSScreen.main ?? window.screen ?? NSScreen.screens.first else { return }
        window.setFrameOrigin(centeredOrigin(size: window.frame.size, in: screen.visibleFrame))
    }

    static func centeredOrigin(size: NSSize, in visible: NSRect) -> NSPoint {
        NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
    }
}
