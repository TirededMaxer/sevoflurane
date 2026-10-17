import AppKit
import Darwin
import WebKit

/// macOS-hosted Steam pages become pixels in the game's existing Metal frame.
/// Backing windows stay invisible and never become key or activate this app.
@MainActor
final class EmbeddedSteamOverlay {
    typealias Create = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
    typealias Read = @convention(c) (UnsafeMutableRawPointer, UInt32) -> UInt64
    typealias Publish = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer, UInt32, UInt32) -> Void
    typealias Deactivate = @convention(c) (UnsafeMutableRawPointer) -> Void
    typealias Pop = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32

    weak var host: SteamWebHost?
    private var surface: UnsafeMutableRawPointer?
    private var read: Read?
    private var publish: Publish?
    private var deactivate: Deactivate?
    private var pop: Pop?
    private var captureTask: Task<Void, Never>?
    private var inputTimer: Timer?
    private weak var hovered: SteamWindow?
    private weak var pressed: SteamWindow?
    private weak var keyboard: SteamWindow?
    private var drag: (SteamWindow, NSPoint, NSRect)?
    private(set) var presenting = false
    private var frame = NSRect.zero

    init(host: SteamWebHost) {
        self.host = host
        guard EmbeddedOverlayLaunch.library != nil else { return }
        let create: Create = SevoOverlayCreate
        read = SevoOverlayRead
        publish = SevoOverlayPublish
        deactivate = SevoOverlayDeactivate
        pop = SevoOverlayPop
        try? FileManager.default.createDirectory(at: EmbeddedOverlayLaunch.surface.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        surface = EmbeddedOverlayLaunch.surface.path.withCString { create($0) }
    }

    /// A live presentation callback, rather than merely an injected library,
    /// is required before replacing the external overlay.
    var connected: Bool {
        guard let surface, let read else { return false }
        let then = read(surface, 6), now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        return then > 0 && now >= then && now - then < 750_000_000
    }

    func show(root: SteamWindow, frame: NSRect) {
        self.frame = frame
        presenting = true
        root.setEmbeddedPresentation(true, frame: frame)
        guard captureTask == nil else { return }
        EventLog.shared.log(.window, "embedded overlay: using game's Metal presentation, no key window")
        inputTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drainInput() }
        }
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, presenting else { break }
                await capture()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    func hide() {
        for menu in windows where menu.role == .menu { menu.setEmbeddedPresentation(false) }
        presenting = false
        captureTask?.cancel(); captureTask = nil
        inputTimer?.invalidate(); inputTimer = nil
        if let surface { deactivate?(surface) }
        hovered?.relayReactHoverExit()
        hovered = nil; pressed = nil; keyboard = nil; drag = nil
    }

    private var windows: [SteamWindow] {
        guard let host else { return [] }
        let root = host.popups.values.filter { $0.role == .gameOverlay && $0.embeddedPresented }
        let children = host.overlayChildren.filter(\.embeddedPresented)
        let menus = host.popups.values.filter { $0.role == .menu && $0.embeddedPresented }
        return Array(root) + children + menus.sorted { $0.name < $1.name }
    }

    private func capture() async {
        guard let surface, let publish, frame.width > 0, frame.height > 0 else { return }
        let scale = min(1, 2048 / frame.width, 2048 / frame.height)
        let width = max(1, Int(frame.width * scale)), height = max(1, Int(frame.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        for popup in windows {
            guard let window = popup.window else { continue }
            let config = WKSnapshotConfiguration()
            config.afterScreenUpdates = false
            guard let image = try? await popup.webView.takeSnapshot(configuration: config),
                  presenting, !Task.isCancelled,
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let webRect = window.convertToScreen(popup.webView.convert(popup.webView.bounds, to: nil))
                .offsetBy(dx: -frame.minX, dy: -frame.minY)
            context.draw(cg, in: webRect)
            // Draw actual AppKit traffic lights after the web snapshot. They
            // remain the same controls, with their original targets/actions.
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(kind), !button.isHidden,
                      let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { continue }
                button.cacheDisplay(in: button.bounds, to: bitmap)
                if let cg = bitmap.cgImage {
                    let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
                        .offsetBy(dx: -frame.minX, dy: -frame.minY)
                    context.draw(cg, in: rect)
                }
            }
        }
        guard presenting, !Task.isCancelled, let pixels = context.data else { return }
        publish(surface, pixels, UInt32(width), UInt32(height))
    }

    private func drainInput() {
        guard presenting, let surface, let pop else { return }
        var bytes = [UInt8](repeating: 0, count: 128)
        while bytes.withUnsafeMutableBytes({ pop(surface, $0.baseAddress!) }) != 0 {
            bytes.withUnsafeBytes { packet in
                let kind = packet.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
                let key = packet.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
                let x = packet.loadUnaligned(fromByteOffset: 8, as: Double.self)
                let y = packet.loadUnaligned(fromByteOffset: 16, as: Double.self)
                let dx = packet.loadUnaligned(fromByteOffset: 24, as: Double.self)
                let dy = packet.loadUnaligned(fromByteOffset: 32, as: Double.self)
                let modifiers = NSEvent.ModifierFlags(rawValue: UInt(packet.loadUnaligned(fromByteOffset: 40, as: UInt64.self)))
                let count = Int(min(64, packet.loadUnaligned(fromByteOffset: 48, as: UInt32.self)))
                let clicks = Int(packet.loadUnaligned(fromByteOffset: 52, as: UInt32.self))
                let text = String(decoding: packet[56 ..< 56 + count], as: UTF8.self)
                route(kind: kind, key: UInt16(key), point: NSPoint(x: frame.minX + x * frame.width, y: frame.maxY - y * frame.height),
                      delta: NSPoint(x: dx, y: dy), modifiers: modifiers, clicks: clicks, text: text)
            }
        }
    }

    private func route(kind: UInt32, key: UInt16, point: NSPoint, delta: NSPoint,
                       modifiers: NSEvent.ModifierFlags, clicks: Int, text: String) {
        if kind >= 7 {
            if kind == 7, key == 48, modifiers.contains(.shift) { host?.closeOverlay(); return }
            guard let target = keyboard ?? windows.last,
                  let event = NSEvent.keyEvent(with: kind == 7 ? .keyDown : kind == 8 ? .keyUp : .flagsChanged,
                                               location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: target.window?.windowNumber ?? 0, context: nil,
                                               characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: key) else { return }
            target.ensureWebKeyboardResponder()
            let responder = target.window?.firstResponder ?? target.webView
            if kind == 7 { responder.keyDown(with: event) }
            else if kind == 8 { responder.keyUp(with: event) }
            else { responder.flagsChanged(with: event) }
            return
        }
        if let (popup, anchor, initial) = drag {
            if kind == 3 { popup.window?.setFrameOrigin(NSPoint(x: initial.minX + point.x - anchor.x, y: initial.minY + point.y - anchor.y)) }
            if kind == 2 { drag = nil }
            return
        }
        let hit = windows.reversed().first { $0.window?.frame.contains(point) == true }
        if hovered !== hit { hovered?.relayReactHoverExit(); hovered = hit }
        guard let popup = (kind == 2 || kind == 5) ? (pressed ?? hit) : hit, let window = popup.window else { return }
        let local = window.convertPoint(fromScreen: point)
        let web = popup.webView.convert(local, from: nil)
        popup.relayReactHover(contentPoint: web, contentHeight: popup.webView.bounds.height)
        if kind == 1 || kind == 4 {
            keyboard = popup; pressed = popup
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                if let button = window.standardWindowButton(type), !button.isHidden,
                   button.bounds.contains(button.convert(local, from: nil)) {
                    button.performClick(nil); pressed = nil; return
                }
            }
            if popup.role.hasPopupChrome, local.y > window.contentLayoutRect.maxY {
                drag = (popup, point, window.frame); return
            }
            window.makeFirstResponder(popup.webView)
        }
        if kind == 6 {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                   wheel1: Int32(delta.y), wheel2: Int32(delta.x), wheel3: 0),
                  let event = NSEvent(cgEvent: cg) else { return }
            popup.webView.scrollWheel(with: event); return
        }
        let type: NSEvent.EventType = kind == 1 ? .leftMouseDown : kind == 2 ? .leftMouseUp : kind == 4 ? .rightMouseDown : kind == 5 ? .rightMouseUp : .mouseMoved
        guard let event = NSEvent.mouseEvent(with: type, location: local, modifierFlags: modifiers,
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: clicks, pressure: kind == 1 ? 1 : 0) else { return }
        let view = popup.webView.hitTest(web) ?? popup.webView
        switch kind {
        case 1: view.mouseDown(with: event)
        case 2: view.mouseUp(with: event); pressed = nil
        case 4: view.rightMouseDown(with: event)
        case 5: view.rightMouseUp(with: event); pressed = nil
        default: view.mouseMoved(with: event)
        }
    }
}
