import Foundation
import Observation

struct CloudUpload: Identifiable, Equatable, Sendable {
    enum Phase: Equatable, Sendable { case uploading, uploaded, failed }
    let id: Int
    var phase: Phase
    var sequence: Int
}

/// Reads the local Steam cloud log; the fork never handles or uploads save files.
@MainActor
@Observable
final class CloudUploads {
    private(set) var entries: [CloudUpload] = []
    @ObservationIgnored private var byApp: [Int: CloudUpload] = [:]
    @ObservationIgnored private var offset: UInt64 = 0
    @ObservationIgnored private var fileID: UInt64?
    @ObservationIgnored private var fragment = ""
    @ObservationIgnored private var sequence = 0

    func phase(for appID: Int) -> CloudUpload.Phase? { entries.first { $0.id == appID }?.phase }

    func refresh(at url: URL = SteamBottle.steamRoot.appendingPathComponent("logs/cloud_log.txt")) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let identity = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        if fileID != identity || size < offset {
            byApp = [:]
            entries = []
            fragment = ""
            offset = size > 262144 ? size - 262144 : 0
            fileID = identity
        }
        guard size > offset else { return }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: 262144) ?? Data()
            offset += UInt64(data.count)
            let text = fragment + String(decoding: data, as: UTF8.self)
            let lines = text.components(separatedBy: "\n")
            fragment = lines.last ?? ""
            for line in lines.dropLast() { consume(line) }
        } catch {
            EventLog.shared.log(.app, "cloud status: could not read Steam's local log: \(error.localizedDescription)")
        }
    }

    func consume(_ line: String) {
        guard let match = line.firstMatch(of: /\[AppID (\d+)\] (.*)/), let id = Int(match.1) else { return }
        let message = String(match.2)
        let lower = message.lowercased()
        let phase: CloudUpload.Phase
        if message.contains("Upload complete, result OK") || message.contains("Upload complete in build list") {
            phase = .uploaded
        } else if (message.contains("Upload complete, result") && !message.contains("result OK"))
                    || (lower.contains("upload") && (lower.contains("failed") || lower.contains("failure"))) {
            phase = .failed
        } else if message.contains("Starting sync (up,") || message.contains("Need to upload file") || message.contains("Upload batch initiated") {
            phase = .uploading
        } else { return }
        sequence += 1
        byApp[id] = CloudUpload(id: id, phase: phase, sequence: sequence)
        entries = byApp.values.sorted {
            let left = $0.phase == .uploading ? 0 : $0.phase == .failed ? 1 : 2
            let right = $1.phase == .uploading ? 0 : $1.phase == .failed ? 1 : 2
            return left == right ? $0.sequence > $1.sequence : left < right
        }
    }
}
