import AppKit
import Testing
@testable import Sevoflurane

/// A modal the app raises by itself leaves the main queue and the main actor
/// running, which is what keeps the control endpoint and the helper's link
/// answering while a question waits.
@MainActor
struct ModalAlertsTests {
    /// A window nobody sees, run modal for a moment in place of an alert.
    private static func runBriefModal(until workRan: @escaping @MainActor () -> Bool) {
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 10, height: 10),
            styleMask: [.borderless], backing: .buffered, defer: false,
        )
        let deadline = ContinuousClock.now + .seconds(3)
        let timer = Timer(timeInterval: 0.01, repeats: true) { timer in
            MainActor.assumeIsolated {
                if workRan() || ContinuousClock.now >= deadline {
                    timer.invalidate()
                    NSApp.abortModal()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        NSApp.runModal(for: window)
    }

    @Test
    func `main-queue work and main-actor tasks run while the modal is up`() async {
        let ran: (queue: Bool, actor: Bool) = await withCheckedContinuation { continuation in
            ModalAlerts.present {
                var queue = false
                var actor = false
                DispatchQueue.main.async { queue = true }
                Task { @MainActor in actor = true }
                Self.runBriefModal { queue && actor }
                continuation.resume(returning: (queue, actor))
            }
        }
        #expect(ran.queue)
        #expect(ran.actor)
    }
}
