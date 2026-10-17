import Foundation
import Testing
@testable import Sevoflurane

/// What happens when a message arrives, decided without a bottle.
///
/// Everything Steam does for an incoming message is refused in the page by
/// ``SteamChatAutoOpen``; what is left on this side is two decisions, and
/// both are values here. ``UnaskedChatPolicy`` says whether a chat window
/// Steam is showing was asked for, and ``SteamNotifications/Presentation``
/// says what a notification reads as and where its click goes. The clock is
/// an argument, so no test waits for anything.
///
/// The live half of the same scenarios is `Tools/chat-scenarios.sh`.
struct UnaskedChatPolicyTests {
    /// The moment every scenario starts from. Named so the offsets below read
    /// as "n seconds later".
    private let start = ContinuousClock.now

    @Test
    func `a message arrives with nobody touching the app`() {
        let policy = UnaskedChatPolicy(startingAt: start)
        // Steam shows the chat a moment after the message lands. No press, no
        // request: the window is Steam's idea, and it stays off screen.
        #expect(policy.showIsUnasked(at: start + .milliseconds(120)))
    }

    @Test
    func `a second message while the first is still held is also unasked`() {
        let policy = UnaskedChatPolicy(startingAt: start)
        #expect(policy.showIsUnasked(at: start + .seconds(30)))
        #expect(policy.showIsUnasked(at: start + .seconds(3600)))
    }

    @Test
    func `a chat the user opened from the friends list is shown`() {
        var policy = UnaskedChatPolicy(startingAt: start)
        policy.noteChatRequest(at: start)
        // `ShowFriendChatDialogWhenReady` waits for the friends UI, so the
        // show can arrive seconds after the click that caused it.
        #expect(!policy.showIsUnasked(at: start))
        #expect(!policy.showIsUnasked(at: start + .seconds(7)))
    }

    @Test
    func `a notification click opens the chat it came from`() {
        var policy = UnaskedChatPolicy(startingAt: start)
        // The click routes through the same request path as the menu bar.
        policy.noteChatRequest(at: start + .seconds(600))
        #expect(!policy.showIsUnasked(at: start + .seconds(600.5)))
    }

    @Test
    func `a press in one of the app's windows counts for three seconds`() {
        var policy = UnaskedChatPolicy(startingAt: start)
        policy.noteUserInteraction(at: start)
        #expect(!policy.showIsUnasked(at: start + .seconds(1)))
        #expect(!policy.showIsUnasked(at: start + .seconds(2.9)))
        #expect(policy.showIsUnasked(at: start + .seconds(3.1)))
    }

    @Test
    func `a request counts for eight seconds`() {
        var policy = UnaskedChatPolicy(startingAt: start)
        policy.noteChatRequest(at: start)
        #expect(!policy.showIsUnasked(at: start + .seconds(7.9)))
        #expect(policy.showIsUnasked(at: start + .seconds(8.1)))
    }

    @Test
    func `either reason on its own is enough`() {
        var pressed = UnaskedChatPolicy(startingAt: start)
        pressed.noteUserInteraction(at: start + .seconds(5))
        #expect(!pressed.showIsUnasked(at: start + .seconds(6)))

        var requested = UnaskedChatPolicy(startingAt: start)
        requested.noteChatRequest(at: start + .seconds(5))
        #expect(!requested.showIsUnasked(at: start + .seconds(6)))
    }

    @Test
    func `the graces are the ones the host documents`() {
        #expect(UnaskedChatPolicy.interactionGrace == .seconds(3))
        #expect(UnaskedChatPolicy.requestGrace == .seconds(8))
    }
}

/// The window Steam names for a chat is classified as one, and a toast is
/// never showable — the two role facts the arrival path turns on.
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

/// The refusals themselves: two scripts, each installed in both copies of the
/// friends UI, whose answers the retry loops compare against.
struct SteamChatAutoOpenTests {
    @Test
    func `the sound refusal names the three sounds a message makes`() {
        let script = SteamMessageSound.refusalScript
        #expect(script.contains("PlayAudioURL"))
        for file in SteamMessageSound.refusedFiles {
            #expect(script.contains(file))
        }
        // The friend-join and friend-online chimes go through the same
        // method and are not ours to take over.
        #expect(!script.contains("ui_steam_smoother_friend_join"))
    }

    @Test
    func `both refusals settle on the same two answers`() {
        #expect(SteamMessageSound.settled == SteamChatAutoOpen.settled)
    }

    @Test
    func `the refusal names the one method that gates the auto-open`() {
        #expect(SteamChatAutoOpen.refusalScript.contains("BShowIncomingChatMessages"))
        #expect(SteamChatAutoOpen.refusalScript.contains("g_FriendsUIApp"))
    }

    @Test
    func `a second install is recognized rather than repeated`() {
        #expect(SteamChatAutoOpen.settled.contains("refused"))
        #expect(SteamChatAutoOpen.settled.contains("already refused"))
        // "unavailable" is Steam's globals not being up yet, which is what
        // the retry loops are for.
        #expect(!SteamChatAutoOpen.settled.contains("unavailable"))
    }
}
