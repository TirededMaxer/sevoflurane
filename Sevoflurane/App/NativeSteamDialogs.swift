import AppKit
import Foundation

/// A conventional Steam Win32 dialog, read in the same bottle as the client.
struct SteamNativeDialog: Decodable, Equatable, Sendable {
    struct Button: Decodable, Equatable, Sendable {
        var id: UInt32
        var title: String
    }
    var handle: UInt64
    var pid: UInt32
    var title: String
    var body: String
    var buttons: [Button]
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
                    for dialog in dialogs where !self.seen.contains(dialog.identity) {
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

    private func presentNext(_ helper: URL) {
        guard !presenting, !queued.isEmpty else { return }
        let dialog = queued.removeFirst()
        guard seen.contains(dialog.identity) else { presentNext(helper); return }
        presenting = true
        ModalAlerts.present { [weak self] in
            let alert = NSAlert()
            alert.messageText = dialog.title
            alert.informativeText = dialog.body
            let buttons = dialog.buttons.isEmpty ? [SteamNativeDialog.Button(id: 0, title: String(localized: "Close"))] : dialog.buttons
            for button in buttons { alert.addButton(withTitle: button.title.replacingOccurrences(of: "&", with: "")) }
            let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
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
