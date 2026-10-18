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
    /// Controls are in the original client coordinate space and enumeration
    /// order. IDs/handles always refer to the still-running Steam window.
    struct Control: Decodable, Equatable, Sendable {
        var handle: UInt64
        var id: UInt32
        var className: String
        var text: String
        var style: UInt32
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var enabled: Bool
        var tabStop: Bool
        var password: Bool
        var isDefault: Bool
        var checkState: Int
        var value: Double? = nil
        var minimum: Double? = nil
        var maximum: Double? = nil
        var iconBGRA: String? = nil
        private enum CodingKeys: String, CodingKey {
            case handle, id, className, text, style, x, y, width, height, enabled, tabStop, password
            case checkState, value, minimum, maximum, iconBGRA
            case isDefault = "default"
        }
    }
    var handle: UInt64
    var pid: UInt32
    var title: String
    var body: String
    var buttons: [Button]
    var toggles: [Toggle]? = nil
    var canClose: Bool? = nil
    var clientWidth: Double? = nil
    var clientHeight: Double? = nil
    var controls: [Control]? = nil
    var identity: String { "\(pid):\(handle)" }

    static func decode(_ output: String) -> [SteamNativeDialog] { snapshot(output) ?? [] }

    static func snapshot(_ output: String) -> [SteamNativeDialog]? {
        struct Scan: Decodable { var dialogs: [SteamNativeDialog] }
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("{\"dialogs\":") }),
              let data = String(line).data(using: .utf8),
              let scan = try? JSONDecoder().decode(Scan.self, from: data) else { return nil }
        return scan.dialogs
    }
}

/// Mirrors Win32 error prompts instead of merely hiding their Wine windows.
/// All scans and responses go through the daemon, which remains the only bottle owner.
@MainActor
final class NativeSteamDialogs {
    private var monitor: Task<Void, Never>?
    private var windows: [String: NativeSteamDialogWindow] = [:]
    private var revision = 0

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
                let beforeScan = self.revision
                if shouldScan(), let result = await Self.run(helper, arguments: []), result.status == 0, beforeScan == self.revision {
                    if let dialogs = SteamNativeDialog.snapshot(result.output) {
                        self.synchronize(dialogs, helper: helper)
                    }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func synchronize(_ dialogs: [SteamNativeDialog], helper: URL) {
        let current = Set(dialogs.map(\.identity))
        for identity in Array(windows.keys) where !current.contains(identity) {
            windows.removeValue(forKey: identity)?.originalDidClose()
        }
        for dialog in dialogs {
            if let existing = windows[dialog.identity] { existing.update(dialog) }
            else if let window = NativeSteamDialogWindow(dialog: dialog, send: { [weak self] arguments in
                self?.forward(arguments, helper: helper)
            }) {
                windows[dialog.identity] = window
                EventLog.shared.log(.client, "original Steam dialog hosted with AppKit controls: \(dialog.title)")
                window.showOriginal()
            }
        }
    }

    private var actionTask: Task<Void, Never>?
    private func forward(_ arguments: [String], helper: URL) {
        revision += 1
        let currentRevision = revision
        let preceding = actionTask
        actionTask = Task { [weak self] in
            await preceding?.value
            var forwarded = arguments
            var inputFile: URL?
            if arguments.count == 6, arguments[0] == "control", arguments[4] == "text" {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("sevo-native-input-\(UUID().uuidString).txt")
                guard let data = arguments[5].data(using: .utf16LittleEndian),
                      FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
                inputFile = file
                forwarded[4] = "text-file"
                forwarded[5] = SteamBottle.windowsPath(for: file)
            }
            defer { if let inputFile { try? FileManager.default.removeItem(at: inputFile) } }
            _ = await Self.run(helper, arguments: forwarded)
            if self?.revision == currentRevision, let result = await Self.run(helper, arguments: []), result.status == 0,
               let dialogs = SteamNativeDialog.snapshot(result.output), self?.revision == currentRevision {
                self?.synchronize(dialogs, helper: helper)
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

}

extension SteamNativeDialog {
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
