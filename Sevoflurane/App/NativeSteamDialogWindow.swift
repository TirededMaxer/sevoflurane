import AppKit

/// A window adapter, not a new message-box policy. Steam supplies every control,
/// its rectangle, enabled/default state and lifetime; AppKit supplies its paint.
@MainActor
final class NativeSteamDialogWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    let window: OriginalSteamDialogPanel
    private(set) var dialog: SteamNativeDialog
    private(set) var controls: [UInt64: NSView] = [:]
    private let send: ([String]) -> Void
    private var closingFromOriginal = false
    private var originalControls: [UInt64: SteamNativeDialog.Control] = [:]

    init?(dialog: SteamNativeDialog, send: @escaping ([String]) -> Void) {
        guard let width = dialog.clientWidth, let height = dialog.clientHeight,
              width > 0, height > 0, dialog.controls != nil else { return nil }
        self.dialog = dialog
        self.send = send
        var mask: NSWindow.StyleMask = [.titled]
        if dialog.canClose == true { mask.insert(.closable) }
        window = OriginalSteamDialogPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                         styleMask: mask, backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.managed, .fullScreenNone]
        window.delegate = self
        window.cancelOriginal = { [weak self] in
            guard let self,
                  let control = self.dialog.controls?.first(where: { $0.id == 2 && $0.enabled && $0.className.lowercased() == "button" }) else { return }
            self.send(self.controlArguments(control.handle, "click"))
        }
        window.contentView = OriginalClientView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.setAccessibilityIdentifier("steam-original-dialog-\(dialog.handle)")
        update(dialog)
        if !window.setFrameUsingName("SteamOriginalDialog.\(dialog.title)") { window.center() }
        window.setContentSize(NSSize(width: width, height: height))
        window.setFrameAutosaveName("SteamOriginalDialog.\(dialog.title)")
    }

    func showOriginal() {
        Task { [weak self] in
            guard let self, !closingFromOriginal else { return }
            _ = await DesktopSpacePlacement.place(window)
            guard !closingFromOriginal else { return }
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Only the original window's disappearance closes the adapter. A user click
    /// can cause validation, another prompt or no close at all in Steam.
    func originalDidClose() {
        closingFromOriginal = true
        window.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closingFromOriginal { return true }
        if dialog.canClose == true {
            send(["answer", String(dialog.handle), String(dialog.pid), "0"])
        }
        return false
    }

    func update(_ snapshot: SteamNativeDialog) {
        dialog = snapshot
        window.title = snapshot.title
        window.standardWindowButton(.closeButton)?.isEnabled = snapshot.canClose == true
        if let width = snapshot.clientWidth, let height = snapshot.clientHeight,
           window.contentView?.frame.size != NSSize(width: width, height: height) {
            window.setContentSize(NSSize(width: width, height: height))
        }
        let originals = snapshot.controls ?? []
        let handles = Set(originals.map(\.handle))
        for handle in Array(controls.keys) where !handles.contains(handle) {
            controls.removeValue(forKey: handle)?.removeFromSuperview()
            originalControls.removeValue(forKey: handle)
        }
        window.defaultButtonCell = nil
        var tabOrder: [NSView] = []
        for original in originals {
            let changedKind = originalControls[original.handle].map {
                $0.className != original.className || ($0.style & 15) != (original.style & 15)
            } ?? false
            if changedKind { controls.removeValue(forKey: original.handle)?.removeFromSuperview() }
            originalControls[original.handle] = original
            let view: NSView
            if let existing = controls[original.handle] { view = existing }
            else {
                guard let created = makeControl(original) else {
                    EventLog.shared.log(.client, "Steam control needs a presentation adapter: \(original.className), style=\(original.style)")
                    continue
                }
                view = created
                controls[original.handle] = view
                window.contentView?.addSubview(view)
            }
            view.frame = NSRect(x: original.x, y: original.y, width: original.width, height: original.height)
            if let button = view as? NSButton {
                button.title = SteamNativeDialog.displayTitle(original.text)
                button.isEnabled = original.enabled
                button.state = original.checkState == 2 ? .mixed : original.checkState == 1 ? .on : .off
                button.keyEquivalent = original.isDefault ? "\r" : original.id == 2 ? "\u{1b}" : ""
                if original.isDefault, original.enabled { window.defaultButtonCell = button.cell as? NSButtonCell }
            } else if let field = view as? NSTextField {
                field.isEnabled = original.enabled
                // A password is never read back by the helper. Don't erase
                // locally entered characters or interrupt an active IME editor.
                let editing = field.currentEditor().map { window.firstResponder === $0 } ?? false
                if !original.password, !editing {
                    field.stringValue = original.text
                }
            } else if let image = view as? NSImageView {
                image.image = Self.originalIcon(original.iconBGRA)
            } else if let box = view as? NSBox {
                box.title = SteamNativeDialog.displayTitle(original.text)
            } else if let progress = view as? NSProgressIndicator {
                progress.minValue = original.minimum ?? 0
                progress.maxValue = original.maximum ?? 100
                progress.doubleValue = original.value ?? 0
            }
            if original.tabStop, original.enabled, view.acceptsFirstResponder { tabOrder.append(view) }
        }
        // EnumChildWindows retains the original child/Z order, which the Win32
        // dialog manager also uses for Tab. Don't let AppKit reorder the buttons.
        for (index, view) in tabOrder.enumerated() {
            view.nextKeyView = tabOrder[(index + 1) % tabOrder.count]
        }
        window.autorecalculatesKeyViewLoop = false
        if window.firstResponder === window { window.initialFirstResponder = tabOrder.first }
    }

    private func makeControl(_ original: SteamNativeDialog.Control) -> NSView? {
        let kind = original.className.lowercased()
        if kind == "button" {
            let type = original.style & 15
            if type == 7 {
                let box = NSBox()
                box.boxType = .primary
                return box
            }
            let button = NSButton(title: "", target: self, action: #selector(clicked(_:)))
            if [2, 3, 5, 6].contains(type) {
                button.setButtonType(.switch)
                button.allowsMixedState = type == 5 || type == 6
            } else if type == 4 || type == 9 { button.setButtonType(.radio) }
            else { button.bezelStyle = .rounded }
            button.tag = Int(original.handle)
            button.setAccessibilityIdentifier("steam-control-\(original.id)")
            return button
        }
        if kind == "static" {
            // Text/static frames remain separate; original line breaks and
            // alignment stay attached to the same control rather than a summary.
            let type = original.style & 31
            if type == 3 {
                let image = NSImageView()
                image.imageScaling = .scaleProportionallyUpOrDown
                return image
            }
            guard type == 0 || type == 1 || type == 2 || type == 12 else { return nil }
            let label = NSTextField(wrappingLabelWithString: original.text)
            label.alignment = type == 1 ? .center : type == 2 ? .right : .left
            label.isSelectable = false
            return label
        }
        if kind == "edit" {
            let field = original.password ? NSSecureTextField() : NSTextField()
            field.isEditable = original.style & 0x800 == 0 // ES_READONLY
            field.isSelectable = true
            field.tag = Int(original.handle)
            field.delegate = self
            field.lineBreakMode = original.style & 4 != 0 ? .byWordWrapping : .byClipping
            field.cell?.wraps = original.style & 4 != 0
            return field
        }
        if kind == "msctls_progress32" {
            let progress = NSProgressIndicator()
            progress.style = .bar
            progress.isIndeterminate = false
            return progress
        }
        return nil
    }

    private static func originalIcon(_ hex: String?) -> NSImage? {
        guard let hex, hex.utf8.count == 8192 else { return nil }
        let digits = Array(hex.utf8)
        func nibble(_ c: UInt8) -> UInt8 { c <= 57 ? c - 48 : c - 87 }
        var bytes = [UInt8](repeating: 0, count: 4096)
        for i in bytes.indices { bytes[i] = nibble(digits[i * 2]) * 16 + nibble(digits[i * 2 + 1]) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: 32, height: 32, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: 32, height: 32))
    }

    @objc private func clicked(_ sender: NSButton) {
        let handle = UInt64(sender.tag)
        guard let original = originalControls[handle], original.enabled else { return }
        send(controlArguments(handle, "click"))
        // AppKit's checkbox/radio tracking must not become a second state
        // machine. Read the resulting state from the original on the next scan.
        sender.state = original.checkState == 2 ? .mixed : original.checkState == 1 ? .on : .off
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        send(controlArguments(UInt64(field.tag), "focus"))
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        send(controlArguments(UInt64(field.tag), "text") + [field.stringValue])
    }

    private func controlArguments(_ handle: UInt64, _ action: String) -> [String] {
        ["control", String(dialog.handle), String(dialog.pid), String(handle), action]
    }
}

@MainActor
private final class OriginalClientView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class OriginalSteamDialogPanel: NSPanel {
    var cancelOriginal: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { cancelOriginal?() }
}
