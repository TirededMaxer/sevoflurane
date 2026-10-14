import Testing
@testable import Sevoflurane

@Suite("Post-update notice")
struct PostUpdateNoticeTests {
    @Test
    func `an older notice is retired and stays gone after relaunch`() {
        var storedVersion: String? = "1.4.0"
        let notice = PostUpdateNotice.reconcile(
            recordedVersion: storedVersion,
            runningVersion: "1.5",
            acknowledge: { storedVersion = nil },
        )
        #expect(notice == nil)
        #expect(storedVersion == nil)

        let relaunchedNotice = PostUpdateNotice.reconcile(
            recordedVersion: storedVersion,
            runningVersion: "1.5",
            acknowledge: { Issue.record("An absent notice needs no acknowledgement") },
        )
        #expect(relaunchedNotice == nil)
    }

    @Test(arguments: [("1.5.0", "1.5"), ("1.5", "1.5.0"), ("1.6.0-beta.2", "1.6-beta.2")])
    func `a notice for the running version is kept, whichever form each side carries`(recorded: String, running: String) {
        let notice = PostUpdateNotice.reconcile(
            recordedVersion: recorded,
            runningVersion: running,
            acknowledge: { Issue.record("The current notice must remain unacknowledged") },
        )
        #expect(notice == recorded)
    }

    @Test(arguments: ["1.3", "1.5.0", "1.4-beta.1", "", nil] as [String?])
    func `a mismatched or missing running version cannot announce a successful update`(runningVersion: String?) {
        var acknowledged = false
        let notice = PostUpdateNotice.reconcile(
            recordedVersion: "1.4.0",
            runningVersion: runningVersion,
            acknowledge: { acknowledged = true },
        )
        #expect(notice == nil)
        #expect(acknowledged)
    }
}
