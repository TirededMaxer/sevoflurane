/// A persisted "updated to X" notice describes the running app only while X is the version
/// that is running.
nonisolated enum PostUpdateNotice {
    /// Returns the recorded version when it names the running bundle's version, so the host
    /// can show it until the user acknowledges it. Versions compare through ``AppVersion``,
    /// because the updater records the release tag's full form (`1.5.0`) while the bundle may
    /// carry the short one (`1.5`). A notice that outlived its version (Homebrew, a dragged-in
    /// DMG or a downgrade replaced the app without the updater) is acknowledged through
    /// `acknowledge` instead, so it stays cleared on later launches.
    static func reconcile(
        recordedVersion: String?,
        runningVersion: String?,
        acknowledge: () -> Void,
    ) -> String? {
        guard let recordedVersion else { return nil }
        guard !recordedVersion.isEmpty, let runningVersion, !runningVersion.isEmpty,
              !AppVersion.isOlder(recordedVersion, than: runningVersion),
              !AppVersion.isOlder(runningVersion, than: recordedVersion)
        else {
            acknowledge()
            return nil
        }
        return recordedVersion
    }
}
