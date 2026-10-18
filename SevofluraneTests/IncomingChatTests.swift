import Testing
@testable import Sevoflurane

@MainActor
struct ChatWindowRoleTests {
    @Test
    func `Steam's chat popup names classify as chats`() {
        #expect(SteamWindowRole(popupName: "chat_ChatWindow_0_uid0") == .chat)
        #expect(SteamWindowRole(popupName: "chat_ChatWindow_12_uid4231") == .chat)
        #expect(SteamWindowRole(popupName: "friendslist_uid0") == .friends)
        #expect(SteamWindowRole(popupName: "notificationtoasts_1_desktop") == .toast)
    }

    @Test
    func `chat and Steam toasts may be shown`() {
        #expect(SteamWindowRole.chat.isShowable)
        #expect(SteamWindowRole.toast.isShowable)
    }
}
