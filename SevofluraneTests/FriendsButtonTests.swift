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
    @Test
    func onlineCountUsesTheOriginalSteamCounterAndWaitsForItsList() throws {
        let context = try #require(JSContext())
        context.evaluateScript("var window=this, reads=0;window.friendStore={friends_list_ready:false,GetOnlineFriendCount:()=>{reads++;return 4}};")
        #expect(context.evaluateScript(SteamWebHost.onlineFriendCountScript)?.isNull == true)
        #expect(context.evaluateScript("reads")?.toInt32() == 0)
        context.evaluateScript("friendStore.friends_list_ready=true")
        #expect(context.evaluateScript(SteamWebHost.onlineFriendCountScript)?.toString() == "4")
        context.evaluateScript("friendStore.GetOnlineFriendCount=()=>0")
        #expect(context.evaluateScript(SteamWebHost.onlineFriendCountScript)?.toString() == "0")
        #expect(context.exception == nil)
    }

}
