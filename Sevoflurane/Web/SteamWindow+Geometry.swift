import AppKit

extension SteamWindow {
    /// The instance UID changes each launch; desktop and overlay keep separate
    /// frames while each kind keeps a stable key across client restarts.
    var placementName: String {
        let instance = SteamWindowRole.instanceUID(ofPopupNamed: name) == 0 ? "desktop" : "overlay"
        let base = role == .chat ? "chat" : SteamWindowRole.base(ofPopupNamed: name)
            .replacingOccurrences(of: #"_\d+$"#, with: "", options: .regularExpression)
        return "Sevo.Steam.\(instance).\(role).\(base)"
    }

    /// Restore a remembered frame, or center a window the user has never opened.
    func place(_ window: NSWindow) {
        if role.needsAReachableFrame {
            restoreForOpening(window)
        } else if let requestedOrigin {
            window.setFrameOrigin(SteamScreenSpace.appKitOrigin(
                steamX: requestedOrigin.x, steamY: requestedOrigin.y, size: window.frame.size,
            ))
        }
    }

    func restoreForOpening(_ window: NSWindow) {
        WindowPlacement.restoreOrCenter(window, key: placementName, autoSave: false)
    }

    /// Restore after Steam has finished applying a popup’s initial size.
    func prepareOpeningPlacement() {
        guard role.needsAReachableFrame, !hasBeenShown, let window = nsWindow else { return }
        restoreForOpening(window)
        hasBeenShown = true
    }

    func savePlacement() {
        guard role.needsAReachableFrame, hasBeenShown,
              let window = nsWindow, isWindowVisible,
              !window.styleMask.contains(.fullScreen) else { return }
        window.saveFrame(usingName: placementName)
    }

    /// Brings a window back onto a display when the frame it was given lands
    /// on none. A frame saved on a display that has since been unplugged, and
    /// a `MoveTo` computed against Steam's own screen model, both produce a
    /// window that exists and that nobody can reach.
    private func centerIfOffScreen(_ window: NSWindow, placedBy source: String) {
        guard role.needsAReachableFrame,
              !SteamScreenSpace.isOnSomeScreen(window.frame) else { return }
        EventLog.shared.log(
            .window,
            "\(name): \(source) put it at \(NSStringFromRect(window.frame)), "
                + "which is on no display — centering instead",
        )
        restoreForOpening(window)
    }

    /// Makes a dialog the desktop window's child, so it rides above it and
    /// moves with it.
    func attachDialogToDesktop() {
        guard role == .dialog, let window, window.parent == nil,
              let parent = host?.desktop?.nsWindow, parent.isVisible else { return }
        parent.addChildWindow(window, ordered: .above)
    }

    /// Steam renders the content and animation; AppKit supplies screen coordinates.
    func placeToast(_ window: NSWindow) {
        let screen = host?.desktop?.nsWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = host?.toastViewport ?? screen?.visibleFrame else { return }
        window.setFrameOrigin(Self.toastOrigin(size: window.frame.size, visibleFrame: visible))
    }

    static func toastOrigin(size: NSSize, visibleFrame: NSRect) -> NSPoint {
        NSPoint(x: visibleFrame.maxX - size.width - 12, y: visibleFrame.minY + 12)
    }

    /// Steam owns toast placement and each animation step. Coordinates are
    /// translated by moveTo; the bottom-right anchor is only an initial fallback.
    var ownsScreenPlacement: Bool { false }

    /// The largest side AppKit gives a window; a larger request gets this.
    nonisolated static let maximumSide: CGFloat = 10000
    /// The farthest from the primary display's origin a window is placed,
    /// with room for a window parked far off-screen.
    nonisolated static let maximumOffset: CGFloat = 1_000_000

    /// A size Steam asked for, held to what a window can be.
    nonisolated static func clampedSize(width: CGFloat, height: CGFloat) -> CGSize {
        CGSize(width: min(max(width, 0), maximumSide), height: min(max(height, 0), maximumSide))
    }

    /// One coordinate Steam asked for, held to ``maximumOffset``.
    nonisolated static func clampedOffset(_ value: CGFloat) -> CGFloat {
        min(max(value, -maximumOffset), maximumOffset)
    }

    func moveTo(x: CGFloat, y: CGFloat) {
        requestedOrigin = CGPoint(x: x, y: y)
        guard let window else { return }
        if role.needsAReachableFrame, !hasBeenShown {
            restoreForOpening(window)
            return
        }
        window.setFrameOrigin(
            SteamScreenSpace.appKitOrigin(
                steamX: x,
                steamY: y,
                size: window.frame.size,
            ),
        )
        centerIfOffScreen(window, placedBy: "Steam's MoveTo(\(Int(x)), \(Int(y)))")
    }

    func resizeTo(width: CGFloat, height: CGFloat) {
        requestedSize = CGSize(width: width, height: height)
        guard let window else { return }
        // Resizing an AppKit window grows it downward from its origin; Steam
        // expects the top-left to stay put, as it does on Windows.
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.setContentSize(requestedSize)
        window.setFrameTopLeftPoint(topLeft)
        if role.needsAReachableFrame, !hasBeenShown { restoreForOpening(window) }
        if role == .toast, requestedOrigin == nil { placeToast(window) }
    }

    /// Places a menu against the window that opened it.
    ///
    /// Steam computes the offset as `menuLeft - parentWindow.screenX`, so the
    /// coordinates are relative to the parent's top-left in screen space, and
    /// the first argument is the parent's restore-details token.
    func positionRelative(
        toWindowNamed parentName: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
    ) {
        realize()
        guard let window else { return }
        let parent = host?.steamOrigin(ofWindowNamed: parentName) ?? .zero
        requestedSize = CGSize(width: width, height: height)
        window.setContentSize(requestedSize)
        if role.needsAReachableFrame, !hasBeenShown {
            restoreForOpening(window)
            return
        }
        window.setFrameOrigin(
            SteamScreenSpace.appKitOrigin(
                steamX: parent.x + x,
                steamY: parent.y + y,
                size: window.frame.size,
            ),
        )
    }

    /// This window's top-left in the coordinates Steam measures in.
    var steamOrigin: CGPoint {
        guard let window else { return requestedOrigin ?? .zero }
        let rect = SteamScreenSpace.steamRect(from: window.frame)
        return CGPoint(x: rect.minX, y: rect.minY)
    }

    /// The display this window is measured against. A Mac with no display
    /// attached has no screen at all, and Steam is answered with a nominal
    /// 1920×1080 one.
    private var measuredScreen: (frame: NSRect, visible: NSRect, scale: CGFloat) {
        let viewport = (role == .context || role == .toast) ? host?.toastViewport : nil
        let gameScreen = viewport.flatMap { viewport in
            NSScreen.screens.first { $0.frame.contains(CGPoint(x: viewport.midX, y: viewport.midY)) }
        }
        if let screen = gameScreen ?? window?.screen ?? NSScreen.main ?? NSScreen.screens.first {
            return (screen.frame, screen.visibleFrame, screen.backingScaleFactor)
        }
        let nominal = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        return (nominal, nominal, 1)
    }

    /// This window's geometry and the display it is on, in Steam's
    /// coordinates. The screen's own origin travels with its size, the way
    /// ``monitorDimensions()`` reports `nUsableLeft`: a display at a
    /// negative x holds windows at a negative x, and a screen described by
    /// size alone cannot say so.
    func dimensions() -> [String: Any] {
        let screenRect = SteamScreenSpace.steamRect(from: measuredScreen.frame)
        var answer: [String: Any] = [
            "screenLeft": screenRect.minX,
            "screenTop": screenRect.minY,
            "screenWidth": screenRect.width,
            "screenHeight": screenRect.height,
        ]
        guard let window else {
            answer["x"] = requestedOrigin?.x ?? 0
            answer["y"] = requestedOrigin?.y ?? 0
            answer["width"] = requestedSize.width
            answer["height"] = requestedSize.height
            return answer
        }
        let rect = SteamScreenSpace.steamRect(from: window.frame)
        answer["x"] = rect.minX
        answer["y"] = rect.minY
        answer["width"] = window.contentLayoutRect.width
        answer["height"] = window.contentLayoutRect.height
        return answer
    }

    func monitorDimensions() -> [String: Any] {
        let screen = measuredScreen
        return Self.monitorDimensions(
            frame: screen.frame, visibleFrame: screen.visible,
            scale: screen.scale, flipLine: SteamScreenSpace.flipLine,
            presentationViewport: (role == .context || role == .toast) ? host?.toastViewport : nil,
        ).mapValues { $0 as Any }
    }

    /// Steam's monitor query uses physical pixels; its original page divides
    /// every coordinate and dimension by the corresponding display scale.
    /// MoveTo then receives logical coordinates, matching AppKit points.
    nonisolated static func monitorDimensions(
        frame: CGRect, visibleFrame: CGRect, scale: CGFloat, flipLine: CGFloat,
        presentationViewport: CGRect? = nil,
    ) -> [String: CGFloat] {
        let frame = presentationViewport ?? frame
        let visibleFrame = presentationViewport ?? visibleFrame
        return [
            "flHorizontalScale": scale,
            "flVerticalScale": scale,
            "nFullLeft": frame.minX * scale,
            "nFullTop": (flipLine - frame.maxY) * scale,
            "nFullWidth": frame.width * scale,
            "nFullHeight": frame.height * scale,
            "nUsableLeft": visibleFrame.minX * scale,
            "nUsableTop": (flipLine - visibleFrame.maxY) * scale,
            "nUsableWidth": visibleFrame.width * scale,
            "nUsableHeight": visibleFrame.height * scale,
        ]
    }
}
