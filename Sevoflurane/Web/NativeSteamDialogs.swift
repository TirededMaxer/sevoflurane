import AppKit
import Foundation

/// A conventional Steam Win32 dialog, read in the same bottle as the client.
struct SteamNativeDialog: Codable, Equatable, Sendable {
    /// Controls are in the original client coordinate space and enumeration
    /// order. IDs/handles always refer to the still-running Steam window.
    struct Font: Codable, Equatable, Sendable {
        var family: String
        var pixelHeight: Double
        var weight: Int
        var italic: Bool
        var underline: Bool
    }
    struct Control: Codable, Equatable, Sendable {
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
        var font: Font? = nil
        var textColor: [Int]? = nil
        var backgroundColor: [Int]? = nil
        private enum CodingKeys: String, CodingKey {
            case handle, id, className, text, style, x, y, width, height, enabled, tabStop, password
            case checkState, value, minimum, maximum, iconBGRA, font, textColor, backgroundColor
            case isDefault = "default"
        }
    }
    var handle: UInt64
    var pid: UInt32
    var title: String
    var canClose: Bool? = nil
    var clientWidth: Double? = nil
    var clientHeight: Double? = nil
    var controls: [Control]? = nil
    var windowClass: String? = nil
    var owner: UInt64? = nil
    var ownerEnabled: Bool? = nil
    var font: Font? = nil
    var frameLeft: Double = 0
    var frameTop: Double = 0
    var frameRight: Double = 0
    var frameBottom: Double = 0
    var face: [Int]? = nil
    var buttonText: [Int]? = nil
    var window: [Int]? = nil
    var windowText: [Int]? = nil
    var highlight: [Int]? = nil
    var highlightText: [Int]? = nil
    var shadow: [Int]? = nil
    var light: [Int]? = nil
    var grayText: [Int]? = nil
    var caption: [Int]? = nil
    var captionText: [Int]? = nil

    /// Explicitly bound this adapter to readable standard Win32 controls.
    /// A custom VGUI canvas is not a standard control merely because its title is readable.
    var unsupportedControlKinds: Set<String> {
        guard let controls, !controls.isEmpty else { return [windowClass ?? "unknown Win32 window"] }
        return Set(controls.compactMap { control in
            let kind = control.className.lowercased()
            let type = control.style & 15
            let supported: Bool
            switch kind {
            case "button": supported = [0, 1, 2, 3, 4, 5, 6, 7, 9].contains(type)
            case "static": supported = [0, 1, 2, 3, 12].contains(control.style & 31)
            case "edit", "msctls_progress32": supported = true
            default: supported = false
            }
            return supported ? nil : "\(control.className):\(control.style)"
        })
    }
    var canPresent: Bool {
        guard let width = clientWidth, let height = clientHeight,
              width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 16_384, height <= 16_384,
              [frameLeft, frameTop, frameRight, frameBottom].allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1024 }),
              let controls, !controls.isEmpty, unsupportedControlKinds.isEmpty else { return false }
        return controls.allSatisfy { c in
            [c.x, c.y, c.width, c.height].allSatisfy(\.isFinite)
                && c.width >= 0 && c.height >= 0 && c.width <= 16_384 && c.height <= 16_384
        }
    }
    var identity: String { "\(pid):\(handle)" }

    static func decode(_ output: String) -> [SteamNativeDialog] { snapshot(output) ?? [] }

    static func snapshot(_ output: String) -> [SteamNativeDialog]? {
        struct Scan: Decodable { var dialogs: [SteamNativeDialog]; var version: Int }
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("{\"dialogs\":") }),
              let data = String(line).data(using: .utf8),
              let scan = try? JSONDecoder().decode(Scan.self, from: data), scan.version == 2 else { return nil }
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
    private var unsupported: [String: Set<String>] = [:]
    /// The original owner is disabled only while its Win32 modal is active.
    /// The app wires this to presentation-only input blocking on its Steam host.
    var modalityDidChange: ((Bool) -> Void)?
    private var isModal = false

    static var helperURL: URL? {
        Bundle.main.url(forResource: "sevo-steam-ui", withExtension: "exe", subdirectory: "SteamUI")
            ?? Bundle.main.url(forResource: "sevo-steam-ui", withExtension: "exe")
    }

    func start(shouldScan: @escaping @MainActor () -> Bool) {
        guard monitor == nil else { return }
        guard let helper = Self.helperURL else {
            EventLog.shared.log(.app, "Steam original-dialog helper is missing from the app bundle")
            return
        }
        monitor = Task(name: "Host original Steam Win32 dialogs") { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let beforeScan = self.revision
                if !shouldScan() { self.synchronize([], helper: helper) }
                else if let result = await Self.run(helper, arguments: []), result.status == 0, beforeScan == self.revision {
                    if let dialogs = SteamNativeDialog.snapshot(result.output) {
                        self.synchronize(dialogs, helper: helper)
                    }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func synchronize(_ dialogs: [SteamNativeDialog], helper: URL) {
        let modal = dialogs.contains { $0.canPresent && ($0.owner ?? 0) != 0 && $0.ownerEnabled == false }
        if modal != isModal { isModal = modal; modalityDidChange?(modal) }
        let current = Set(dialogs.map(\.identity))
        for identity in Array(windows.keys) where !current.contains(identity) {
            windows.removeValue(forKey: identity)?.originalDidClose()
        }
        for dialog in dialogs {
            guard dialog.canPresent else {
                let kinds = dialog.unsupportedControlKinds
                if unsupported[dialog.identity] != kinds {
                    unsupported[dialog.identity] = kinds
                    EventLog.shared.log(.client, "Steam original dialog requires unsupported control renderer: \(kinds.sorted().joined(separator: ","))")
                }
                windows.removeValue(forKey: dialog.identity)?.originalDidClose()
                continue
            }
            unsupported.removeValue(forKey: dialog.identity)
            if let existing = windows[dialog.identity] { existing.update(dialog) }
            else if let window = NativeSteamDialogWindow(dialog: dialog, send: { [weak self] arguments in
                self?.forward(arguments, helper: helper)
            }) {
                windows[dialog.identity] = window
                EventLog.shared.log(.client, "original Steam Win32 dialog hosted by WebKit")
                window.showOriginal()
            }
        }
    }

    /// No original Win32 HWND is closed or terminated during host teardown.
    /// The current driver suppression policy is owned by the daemon/engine.
    func stop() {
        monitor?.cancel()
        monitor = nil
        actionTask?.cancel()
        actionTask = nil
        revision += 1
        for window in windows.values { window.originalDidClose() }
        windows.removeAll()
        unsupported.removeAll()
        if isModal { isModal = false; modalityDidChange?(false) }
    }

    private var actionTask: Task<Void, Never>?
    private func forward(_ arguments: [String], helper: URL) {
        revision += 1
        let currentRevision = revision
        let preceding = actionTask
        actionTask = Task { [weak self] in
            await preceding?.value
            guard !Task.isCancelled else { return }
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
        let root = SteamBottle.windowsPath(for: SteamBottle.steamRoot)
        guard let request = ClientLifecycle.daemonRunRequest(
            [helper.path, "--steam-root", root] + arguments, timeout: .seconds(10)
        ) else { return nil }
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
