import Foundation
import Testing
@testable import Sevoflurane

/// The game overlay's classification: the popup names Steam gives it, and the
/// window policy that role carries.
@MainActor
struct GameOverlayRoleTests {
    @Test
    func `desktop and gamepad overlays classify as the game overlay`() {
        #expect(SteamWindowRole(popupName: "desktopoverlay_uid1688") == .gameOverlay)
        #expect(SteamWindowRole(popupName: "gamepadoverlay_uid42") == .gameOverlay)
        // The base name alone (no uid suffix) classifies too.
        #expect(SteamWindowRole(popupName: "desktopoverlay") == .gameOverlay)
    }

    @Test
    func `the overlay role's window policy`() {
        let role = SteamWindowRole.gameOverlay
        // Never promotes the app or takes key on Steam's behalf…
        #expect(role.isPanel)
        // …renders while covered (it sits over another app's window and would
        // otherwise read as occluded and stop)…
        #expect(!role.allowsOcclusionDetection)
        // …may be shown, and carries no chrome of its own.
        #expect(!role.isShowable) // The original game renderer shows it.
        #expect(!role.hasPopupChrome)
    }

    @Test
    func `the overlay names do not disturb the other roles`() {
        // The overlay prefixes must leave every prior popup-name mapping
        // intact.
        #expect(SteamWindowRole(popupName: "SP Desktop_uid1") == .desktop)
        #expect(SteamWindowRole(popupName: "SP BPM_uid1") == .bigPicture)
        #expect(SteamWindowRole(popupName: "contextmenu_3") == .menu)
        #expect(SteamWindowRole(popupName: "friendslist_uid9") == .friends)
        #expect(SteamWindowRole(popupName: "chat_1") == .chat)
        #expect(SteamWindowRole(popupName: "notificationtoasts_1_desktop") == .toast)
        #expect(SteamWindowRole(popupName: "something_unknown") == .auxiliary)
    }
}

/// Which on-screen window is a game's, by the resolved Windows program name.
struct GameProgramTests {
    @Test
    func `a game exe is one, the client's own infrastructure is not`() {
        #expect(WineWindowWatch.isGameProgram("subnautica2-win64-shipping.exe"))
        #expect(WineWindowWatch.isGameProgram("game.exe"))
        for infrastructure in [
            "steam.exe", "steamwebhelper.exe", "steamservice.exe",
            "explorer.exe", "conhost.exe", "gameoverlayui64.exe",
        ] {
            #expect(!WineWindowWatch.isGameProgram(infrastructure))
        }
        // Not an executable window at all.
        #expect(!WineWindowWatch.isGameProgram("steam_osx"))
        #expect(!WineWindowWatch.isGameProgram(""))
    }
}
