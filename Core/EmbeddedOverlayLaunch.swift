import Foundation

/// The renderer loads after CrossOver's system Perl wrapper has crossed SIP.
/// It only installs hooks in cs2.exe; Steam infrastructure keeps its existing policy.
nonisolated enum EmbeddedOverlayLaunch {
    static var surface: URL { AppIdentity.supportFolder.appendingPathComponent("Overlay/cs2.surface") }
    static var library: URL? { BundledResources.url("EmbeddedOverlay/SevoEmbeddedOverlay.dylib") }

    static var environment: [String: String] {
        guard let library else { return [:] }
        return ["DYLD_INSERT_LIBRARIES": library.path, "SEVO_OVERLAY_BRIDGE": surface.path]
    }

    static func wrapperEnvironment(_ values: [String: String]) -> String {
        values.keys.sorted().map { key in
            let value = values[key]!.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\(key)=\"\(value)\""
        }.joined(separator: " ")
    }
}
