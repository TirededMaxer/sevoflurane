import Foundation

/// Which of the crash reports macOS wrote belong to this copy of Sevoflurane.
///
/// A Debug build and the installed app run under the same process names, and
/// macOS writes `procPath` with the home folder and other volumes masked
/// (`/Users/USER/*/…`), so the path cannot tell them apart. The header line
/// can: the app's crash names its bundle identifier, which differs between
/// the two, and every crash names the UUID of the image that crashed.
nonisolated enum OwnCrashReports {
    /// The app and the background helper inside it. Wine and game
    /// processes are the games', never these.
    static let processNames = ["Sevoflurane", "SevofluraneDaemon"]

    /// `bug_type` of a crash. A hang or a spin is written under other types.
    static let crashBugType = "309"

    /// What this copy's crashes carry in their header line.
    struct Identity: Equatable {
        /// The app's bundle identifier: a crash of the app names it, whichever
        /// build of this installation crashed.
        var bundleID: String?
        /// The Mach-O UUIDs of the app and its helper, uppercase: the helper is
        /// a tool, and its crashes are this build's when the UUID matches.
        var imageUUIDs: Set<String>

        static var running: Identity {
            let helper = Bundle.main.bundleURL.appending(path: "Contents/Library/LaunchAgents/SevofluraneDaemon")
            return Identity(
                bundleID: Bundle.main.bundleIdentifier,
                imageUUIDs: Set([MachOIdentity.ofThisProcess, MachOIdentity.ofFile(helper)].compactMap(\.self)),
            )
        }
    }

    /// The crashes among `reports` that are this copy's.
    static func ours(_ reports: [URL], identity: Identity) -> [URL] {
        reports.filter { url in
            guard let data = try? Data(contentsOf: url) else { return false }
            return isCrash(data, of: identity)
        }
    }

    /// Whether an `.ips` file (a JSON header line, then the JSON body) is a
    /// crash of the app or the helper `identity` describes.
    static func isCrash(_ ips: Data, of identity: Identity) -> Bool {
        let line = ips.prefix { $0 != UInt8(ascii: "\n") }
        guard let header = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              header["bug_type"] as? String == crashBugType
        else { return false }
        if let bundleID = identity.bundleID, header["bundleID"] as? String == bundleID { return true }
        guard let uuid = header["slice_uuid"] as? String else { return false }
        return identity.imageUUIDs.contains(uuid.uppercased())
    }
}

