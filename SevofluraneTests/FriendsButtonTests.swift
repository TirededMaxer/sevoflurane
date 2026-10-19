import JavaScriptCore
import Testing
@testable import Sevoflurane

@MainActor
struct FriendsButtonTests {
    @Test
    func `friends opens the list even when unread activation is unavailable`() throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var window = this, calls = [];
        window.g_FriendsUIApp = {
          GetDefaultBrowserContext: function () { return {m_unPID: 0, m_nBrowserID: -1}; },
          m_DesktopApp: { ShowChatUnreadMessages: function () { throw Error("unread entry point must not run"); } },
          ShowPopupFriendsList: function (context, hidden, focus) { calls.push([context.m_unPID, hidden, focus]); }
        };
        """)
        #expect(context.evaluateScript(SteamWebHost.friendsScript)?.toString() == "showing friends list")
        #expect(context.exception == nil)
        #expect(context.evaluateScript("JSON.stringify(calls)")?.toString() == "[[0,false,true]]")
    }
}
