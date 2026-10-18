import Testing
@testable import Sevoflurane

@MainActor
struct MenuTrackingRecoveryTests {
    private typealias Recovery = MenuTrackingRecovery
    @Test
    func `the stop outcome reads the same wherever the lever fired`() {
        #expect(
            Recovery.StopOutcome(sessionSource: "currentSession", enderSent: "dismissAnimated:NO").summary
                == "found the tracking session via currentSession, sent dismissAnimated:NO",
        )
        #expect(
            Recovery.StopOutcome(sessionSource: "menu ‘Help’", enderSent: nil).summary
                == "found the tracking session via menu ‘Help’ but it responded to no ender",
        )
        #expect(
            Recovery.StopOutcome(sessionSource: nil, enderSent: nil).summary
                == "no tracking session found on the main menu or the open menus",
        )
    }
}
