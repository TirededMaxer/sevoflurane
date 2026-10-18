import AppKit
import Foundation

/// A conventional Steam Win32 dialog, read in the same bottle as the client.
struct SteamNativeDialog: Decodable, Equatable, Sendable {
    struct Button: Decodable, Equatable, Sendable {
        var id: UInt32
        var title: String
        var enabled: Bool? = nil
        var isDefault: Bool? = nil
        private enum CodingKeys: String, CodingKey { case id, title, enabled; case isDefault = "default" }
    }
    struct Toggle: Decodable, Equatable, Sendable {
        var id: UInt32
        var title: String
        var radio: Bool
        var enabled: Bool
        var checked: Bool
    }
    var handle: UInt64
    var pid: UInt32
    var title: String
    var body: String
    var buttons: [Button]
    var toggles: [Toggle]? = nil
    var canClose: Bool? = nil
    var identity: String { "\(pid):\(handle)" }

    static func decode(_ output: String) -> [SteamNativeDialog] {
        struct Scan: Decodable { var dialogs: [SteamNativeDialog] }
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("{\"dialogs\":") }),
              let data = String(line).data(using: .utf8),
              let scan = try? JSONDecoder().decode(Scan.self, from: data) else { return [] }
        return scan.dialogs
    }
}

/// Mirrors Win32 error prompts instead of merely hiding their Wine windows.
/// All scans and responses go through the daemon, which remains the only bottle owner.
@MainActor
final class NativeSteamDialogs {
    private var monitor: Task<Void, Never>?
    private var seen: Set<String> = []
    private var queued: [SteamNativeDialog] = []
    private var presenting = false
    private var activeAlert: (String, NSAlert)?
    private var passivePanels: [String: NSPanel] = [:]


    static var helperURL: URL? {
        Bundle.main.url(forResource: "sevo-steam-ui", withExtension: "exe", subdirectory: "SteamUI")
            ?? Bundle.main.url(forResource: "sevo-steam-ui", withExtension: "exe")
    }

    func start(shouldScan: @escaping @MainActor () -> Bool) {
        guard monitor == nil else { return }
        guard let helper = Self.helperURL else {
            EventLog.shared.log(.app, "native Steam dialog helper is missing from the app bundle")
            return
        }
        monitor = Task(name: "Mirror native Steam dialogs") { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if shouldScan(), let result = await Self.run(helper, arguments: []), result.status == 0 {
                    let dialogs = SteamNativeDialog.decode(result.output)
                    let current = Set(dialogs.map(\.identity))
                    for identity in self.passivePanels.keys where !current.contains(identity) {
                        self.passivePanels.removeValue(forKey: identity)?.close()
                    }
                    if let (identity, alert) = self.activeAlert, !current.contains(identity), NSApp.modalWindow === alert.window {
                        NSApp.abortModal()
                        alert.window.orderOut(nil)
                    }
                    for dialog in dialogs where !self.seen.contains(dialog.identity) {
                        if dialog.buttons.isEmpty && dialog.canClose == false {
                            self.showPassive(dialog)
                            continue
                        }
                        self.queued.append(dialog)
                        EventLog.shared.log(.client, "native Steam dialog mirrored: \(dialog.title)")
                    }
                    self.seen = current
                    self.presentNext(helper)
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private static func run(_ helper: URL, arguments: [String]) async -> (status: Int32?, output: String)? {
        guard let request = ClientLifecycle.daemonRunRequest([helper.path] + arguments, timeout: .seconds(10)) else { return nil }
        switch await ClientLifecycle.daemonRun(request) {
        case let .answered(result): return result
        case .unreachable, .failed: return nil
        }
    }

    private func showPassive(_ dialog: SteamNativeDialog) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 150),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.title = dialog.title
        let label = NSTextField(wrappingLabelWithString: dialog.body)
        label.frame = NSRect(x: 24, y: 24, width: 392, height: 100)
        label.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(label)
        panel.center()
        panel.orderFront(nil)
        passivePanels[dialog.identity] = panel
    }

    private func presentNext(_ helper: URL) {
        guard !presenting, !queued.isEmpty else { return }
        let dialog = queued.removeFirst()
        guard seen.contains(dialog.identity) else { presentNext(helper); return }
        presenting = true
        ModalAlerts.present { [weak self] in
            let alert = dialog.makeAlert()
            self?.activeAlert = (dialog.identity, alert)
            let actions = (dialog.toggles ?? []).map { toggle in
                NativeDialogToggle(toggle: toggle) {
                    Task(name: "Click original Steam dialog option") {
                        _ = await Self.run(helper, arguments: ["answer", String(dialog.handle), String(dialog.pid), String(toggle.id)])
                    }
                }
            }
            if !actions.isEmpty {
                let stack = NSStackView(views: actions.map(\.button))
                stack.orientation = .vertical
                stack.alignment = .leading
                alert.accessoryView = stack
            }
            let buttons = dialog.presentedButtons
            let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            withExtendedLifetime(actions) {}
            self?.activeAlert = nil
            if buttons.indices.contains(index) {
                Task(name: "Answer native Steam dialog") {
                    _ = await Self.run(helper, arguments: ["answer", String(dialog.handle), String(dialog.pid), String(buttons[index].id)])
                    self?.presenting = false
                    self?.presentNext(helper)
                }
            } else {
                self?.presenting = false
            }
        }
    }
}

@MainActor
extension SteamNativeDialog {
    var presentedButtons: [Button] {
        buttons.isEmpty && canClose != false
            ? [Button(id: 0, title: String(localized: "Close"))] : buttons
    }

    func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        for original in presentedButtons {
            let button = alert.addButton(withTitle: Self.displayTitle(original.title))
            button.isEnabled = original.enabled ?? true
            // NSAlert otherwise makes its first button the default, which can
            // invert a Windows warning whose default is No or Cancel.
            button.keyEquivalent = original.isDefault == true ? "\r" : original.id == 2 ? "\u{1b}" : ""
        }
        return alert
    }

    static func displayTitle(_ title: String) -> String {
        var result = ""
        var characters = title.makeIterator()
        while let character = characters.next() {
            if character == "&" {
                if let next = characters.next() { result.append(next) }
            } else { result.append(character) }
        }
        return result
    }
}

@MainActor
private final class NativeDialogToggle: NSObject {
    let button: NSButton
    let action: () -> Void
    init(toggle: SteamNativeDialog.Toggle, action: @escaping () -> Void) {
        button = NSButton(checkboxWithTitle: SteamNativeDialog.displayTitle(toggle.title), target: nil, action: nil)
        if toggle.radio { button.setButtonType(.radio) }
        button.state = toggle.checked ? .on : .off
        button.isEnabled = toggle.enabled
        self.action = action
        super.init()
        button.target = self
        button.action = #selector(clicked)
    }
    @objc private func clicked() { action() }
}
