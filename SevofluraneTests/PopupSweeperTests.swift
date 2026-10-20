import Foundation
import Testing
@testable import Sevoflurane

/// What keeps the app off the bottled client's one DevTools thread: sweeps
/// that join instead of racing.
struct PopupSweeperTests {
    /// A counter the sweep hook increments, so a test can say how many
    /// sweeps actually reached the client.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func bump() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    @Test
    func `concurrent asks share one sweep`() async {
        let sweeps = Counter()
        let sweeper = PopupSweeper(minimumInterval: .seconds(30)) { _ in
            // Long enough that every caller below is waiting on this one.
            try? await Task.sleep(for: .milliseconds(200))
            return ["popup \(sweeps.bump())"]
        }
        let names = await withTaskGroup(of: [String].self) { group in
            for _ in 0 ..< 8 {
                group.addTask { await sweeper.sweep().names }
            }
            return await group.reduce(into: [[String]]()) { $0.append($1) }
        }
        #expect(sweeps.count == 1)
        #expect(names.allSatisfy { $0 == ["popup 1"] })
    }

    @Test
    func `a second sweep waits out the minimum interval`() async {
        let sweeps = Counter()
        let sweeper = PopupSweeper(minimumInterval: .milliseconds(300)) { _ in
            ["popup \(sweeps.bump())"]
        }
        let clock = ContinuousClock()
        let began = clock.now
        _ = await sweeper.sweep()
        _ = await sweeper.sweep()
        #expect(sweeps.count == 2)
        #expect(began.duration(to: clock.now) >= .milliseconds(280))
    }

    @Test
    func `a sweep says what it was allowed to hide`() async {
        let sweeper = PopupSweeper(minimumInterval: .zero) { _ in ["SP Desktop_uid0"] }
        #expect(await sweeper.sweep().scope == .everything)
        #expect(await sweeper.sweep(.twins).names == ["SP Desktop_uid0"])
    }


}

/// Which of the client's own windows a narrow lifecycle sweep may put away: the
/// copies of what this app draws itself, and nothing the client alone has.
struct PopupSweepClassificationTests {
    private func allowed(_ name: String) -> Bool {
        let base = SteamWindowRole.base(ofPopupNamed: name)
        return SteamWindowRole.twinNames.contains { $0.matches(base: base) }
    }

    @Test
    func `the windows this app draws itself are twins`() {
        #expect(allowed("notificationtoasts_1_desktop"))
        #expect(allowed("SP Desktop_uid0"))
        #expect(allowed("chat_76561198000000000_uid0"))
        #expect(allowed("friendslist_uid0"))
    }

    @Test
    func `the windows only the client has are left alone`() {
        // The retest's three: the install and EULA modal, a game's own popup,
        // and the sign-in window a base prefix would otherwise swallow.
        #expect(!allowed("PopupWindow_InstallModal_«rg»"))
        #expect(!allowed("Megabonk_uid0"))
        #expect(!allowed("SP DesktopLoginWindow_uid0"))
        #expect(!allowed("contextmenu_10_uid0"))
        #expect(!allowed("SP Keyboard_uid0"))
        #expect(!allowed("desktopoverlay_uid2220"))
    }

    @Test
    func `every twin name belongs to a twin role`() {
        for name in ["notificationtoasts_1_desktop", "SP Desktop_uid0", "chat_1_uid0"] {
            #expect(SteamWindowRole.twinRoles.contains(SteamWindowRole(popupName: name)))
        }
        for name in ["PopupWindow_InstallModal_«rg»", "Megabonk_uid0", "SP DesktopLoginWindow"] {
            #expect(!SteamWindowRole.twinRoles.contains(SteamWindowRole(popupName: name)))
        }
    }
}

/// Which of the client's popups a sweep leaves alone while a launch is
/// waiting on one of them.
struct PopupSparingTests {
    @Test
    func `the launch's own popup is spared by name`() {
        let sparing = PopupSparing(exactBases: ["Black Myth: Wukong Benchmark Tool"])
        #expect(sparing.spares(popupNamed: "Black Myth: Wukong Benchmark Tool_uid0"))
        #expect(!sparing.spares(popupNamed: "Megabonk_uid0"))
    }

    @Test
    func `a desktop popup the role table cannot name is spared when asked`() {
        let sparing = PopupSparing(unclassifiedDesktopPopups: true)
        #expect(sparing.spares(popupNamed: "Megabonk_uid0"))
        #expect(!sparing.spares(popupNamed: "notificationtoasts_1_desktop"))
        #expect(!sparing.spares(popupNamed: "SP Desktop_uid0"))
        #expect(!sparing.spares(popupNamed: "PopupWindow_InstallModal_«rg»"))
        // A game overlay's popup carries the game's pid and is never a launch dialog.
        #expect(!sparing.spares(popupNamed: "friendslist_uid2220"))
    }

    @Test
    func `nothing is spared by default`() {
        for name in ["Black Myth: Wukong Benchmark Tool_uid0", "Megabonk_uid0", "SP Desktop_uid0"] {
            #expect(!PopupSparing.none.spares(popupNamed: name))
        }
    }

    @Test
    func `the sweep script carries the spared name`() {
        let script = SteamBridge.popupHideScript(
            .everything, sparing: PopupSparing(exactBases: ["Black Myth: Wukong Benchmark Tool"], unclassifiedDesktopPopups: true),
        )
        #expect(script.contains("\"Black Myth: Wukong Benchmark Tool\""))
        #expect(script.contains("true"))
        #expect(SteamBridge.popupHideScript(.everything).contains("[], false"))
    }
}
