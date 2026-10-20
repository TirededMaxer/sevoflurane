import AppKit

extension SteamWebHost {
    /// Opens Steam's friends list as its own window.
    ///
    /// The friends list and every chat are ordinary popups of the UI this app
    /// already hosts, so they need nothing from the desktop window — which is
    /// the point: a menu-bar Steam is a launcher and a friends list, and the
    /// library is the optional part. Measured against a live client with
    /// `SP Desktop` hidden throughout.
    ///
    /// The unread badge reports waiting conversations; this button always
    /// opens the friends list. Chat rows open individual conversations.
    func openFriends() {
        if let existing = popups.values.first(where: { $0.role == .friends && !$0.usesOriginalGameOverlay }) {
            existing.show(activating: true)
            return
        }
        runInContext(Self.friendsScript, describedAs: "friends list")
    }

    /// Opens one friend's chat window, by the 32-bit account id Steam's own
    /// chat calls take. Used by the explicit chat-open control endpoint.
    func openChat(accountID: String) {
        guard !accountID.isEmpty, let id = Int(accountID) else {
            openFriends()
            return
        }
        runInContext(Self.chatScript(accountID: id), describedAs: "chat with \(accountID)")
    }

    private func runInContext(_ script: String, describedAs what: String) {
        // The window comes forward with the app, the way any window opened
        // from a menu-bar item does. Cooperative activation declines a
        // request it cannot attribute to an event, so this happens now,
        // while the click is still the reason for it.
        NSApp.activate()
        Task(name: "Open \(what)") {
            let result = await evaluateInContext(script)
            EventLog.shared.log(.window, "\(what): \(result ?? "no answer")")
        }
    }

    /// Steam's unread-conversation entry point in the current client returns
    /// before opening a window. Use the explicit list entry point for Friends.
    static let friendsScript = """
    (function () {
      var app = window.g_FriendsUIApp;
      if (!app || typeof app.GetDefaultBrowserContext !== "function") return "unavailable";
      var context = app.GetDefaultBrowserContext();
      if (!context) return "no browser context";
      if (typeof app.ShowPopupFriendsList !== "function") return "unavailable";
      app.ShowPopupFriendsList(context, false, true);
      return "showing friends list";
    })()
    """

    private static func chatScript(accountID: Int) -> String {
        """
        (function () {
          var app = window.g_FriendsUIApp;
          if (!app || !app.UIStore
              || typeof app.UIStore.ShowFriendChatDialogWhenReady !== "function") {
            return "unavailable";
          }
          var context = app.GetDefaultBrowserContext();
          if (!context) return "no browser context";
          app.UIStore.ShowFriendChatDialogWhenReady(context, \(accountID), true, true);
          return "showing chat";
        })()
        """
    }

    /// Observe Steam state without changing its appearance. Notification content, sounds,
    /// chat creation and game input remain the original client's decisions.
    func installContextScripts() {
        install(Self.installWizardScript, describedAs: "Steam install window", settledAt: ["registered", "already registered"])
        install(Self.callFailureScript, describedAs: "Steam call diagnostics", settledAt: ["registered", "already registered"])
        // Original pages keep their original notification, sound and chat
        // decisions. No payload is reinterpreted or re-posted by the host.
        installInClient(SteamPresentation.originalClientScript,
                        describedAs: "restore original Steam page appearance",
                        settledAt: ["original"])
    }

    private func installInClient(
        _ script: String, describedAs what: String, settledAt outcomes: Set<String>,
    ) {
        Task(name: "Install \(what) in the client") {
            let result = await ClientLifecycle.installInClientUI(script, settledAt: outcomes)
            EventLog.shared.log(.client, "\(what) in the client: \(result)")
        }
    }

    /// Evaluates `script` in the context page until it answers one of
    /// `outcomes`, once a second for ten seconds: Steam's globals appear a
    /// moment after the page does. A result's words before a colon are its
    /// outcome; what follows is logged with it.
    func install(
        _ script: String, describedAs what: String, settledAt outcomes: Set<String>,
    ) {
        Task(name: "Install \(what)") {
            for _ in 1 ... 10 {
                if let result = await evaluateInContext(script),
                   outcomes.contains(String(result.prefix { $0 != ":" })) {
                    EventLog.shared.log(.app, "\(what): \(result)")
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            EventLog.shared.log(.app, "\(what): Steam's own globals never appeared")
        }
    }
}
