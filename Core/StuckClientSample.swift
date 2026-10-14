import Foundation

/// A record of `steam.exe` at the moment the supervisor finds its main thread
/// parked: every thread's stack, sampled for a few seconds, beside the app's
/// own log. A stall is restarted away in seconds and leaves nothing to read
/// otherwise; this file is what names the wait the next time one happens.
nonisolated enum StuckClientSample {
    /// How long the sampler watches the process.
    static let seconds = 3

    /// Where the samples go: the folder the app's log lives in.
    static var folder: URL { AppIdentity.logFile(nil).deletingLastPathComponent() }

    /// The file a sample taken now is written to.
    static func file(at date: Date = .now) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        return folder.appending(path: "Sevoflurane-stuck-steam-\(formatter.string(from: date)).txt")
    }

    /// Samples the bottle's `steam.exe` and answers where the sample landed,
    /// or `nil` when there was no client to sample or the sampler failed.
    static func capture() async -> URL? {
        guard let pid = await ClientLifecycle.bottleProcessIDs(matching: "steam.exe").first else { return nil }
        let destination = file()
        let result = await Subprocess.run(
            "/usr/bin/sample", ["\(pid)", "\(seconds)", "-file", destination.path],
            capture: .none, timeout: .seconds(seconds * 10),
        )
        guard result.status == 0, FileManager.default.fileExists(atPath: destination.path) else { return nil }
        return destination
    }
}
