import Testing
@testable import Sevoflurane

@MainActor
struct DesktopSpacePlacementTests {
    private let spaces: [[String: Any]] = [
        ["ManagedSpaceID": 1, "type": 0],
        ["ManagedSpaceID": 9, "type": 4],
        ["ManagedSpaceID": 2, "type": 0],
        ["ManagedSpaceID": 10, "type": 4],
    ]

    @Test
    func keepsAnExistingDesktopWhenAnotherApplicationIsFullscreen() {
        #expect(DesktopSpacePlacement.destination(in: spaces, current: 10, memberships: [1]) == 1)
    }

    @Test
    func choosesANormalDesktopForAWindowCreatedInFullscreen() {
        #expect(DesktopSpacePlacement.destination(in: spaces, current: 10, memberships: [10]) == 2)
        #expect(DesktopSpacePlacement.destination(in: spaces, current: 2, memberships: []) == 2)
    }

    @Test
    func fullscreenOnlyInventoryCannotBecomeADesktopTarget() {
        #expect(DesktopSpacePlacement.destination(in: [["ManagedSpaceID": 9, "type": 4]], current: 9, memberships: [9]) == nil)
    }
}
