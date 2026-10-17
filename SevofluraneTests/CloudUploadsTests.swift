import Foundation
import Observation
import Synchronization
import Testing
@testable import Sevoflurane

@MainActor
struct CloudUploadsTests {
    @Test
    func progressOnlyCompletesWhenSteamConfirmsIt() {
        let state = CloudUploads()
        state.consume("[2026-10-17 14:32:25] [AppID 730] Starting sync (up,AC Exit,)")
        #expect(state.entries.first?.phase == .uploading)
        state.consume("[2026-10-17 14:32:26] [AppID 730] HTTP upload for file 'save.dat' - success.")
        #expect(state.entries.first?.phase == .uploading)
        state.consume("[2026-10-17 14:32:27] [AppID 730] Upload complete, result OK")
        #expect(state.entries.first?.phase == .uploaded)
    }

    @Test
    func failureRetryAndParallelGamesRemainSeparate() {
        let state = CloudUploads()
        state.consume("[AppID 730] Upload complete, result Failure")
        state.consume("[AppID 241100] Upload complete in build list")
        #expect(state.entries.first?.id == 730)
        #expect(state.entries.first?.phase == .failed)
        state.consume("[AppID 730] Starting sync (up,AC Exit,)")
        #expect(state.entries.first?.phase == .uploading)
        #expect(state.entries.count == 2)
    }

    @Test
    func gameRowReadsReceiveCloudStateChanges() {
        let state = CloudUploads()
        let changed = Mutex(false)
        withObservationTracking {
            _ = state.phase(for: 730)
        } onChange: {
            changed.withLock { $0 = true }
        }
        state.consume("[AppID 730] Starting sync (up,AC Exit,)")
        #expect(changed.withLock { $0 })
        #expect(state.phase(for: 730) == .uploading)
        #expect(state.phase(for: 42) == nil)
        state.consume("[AppID 730] Upload complete, result OK")
        #expect(state.phase(for: 730) == .uploaded)
    }

    @Test
    func incrementalLogReadsHandlePartialLinesAndRotation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cloud_log.txt")
        try Data("[AppID 730] Starting sync (up,".utf8).write(to: url)
        let state = CloudUploads()
        state.refresh(at: url)
        #expect(state.entries.isEmpty)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("AC Exit,)\n".utf8))
        try handle.close()
        state.refresh(at: url)
        #expect(state.entries.first?.phase == .uploading)
        try Data("[AppID 42] Upload complete, result OK\n".utf8).write(to: url, options: .atomic)
        state.refresh(at: url)
        #expect(state.entries.map(\.id) == [42])
    }
}
