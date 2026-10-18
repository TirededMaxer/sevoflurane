import AppKit

extension SteamWebHost {
    /// Whether the in-game overlay is up. A popup Steam opens while it is (the
    /// overlay's Settings, its dialogs) is built as a non-activating panel and
    /// shown without activating the app, so clicking it never pulls focus off
    /// the game — the drop that puts the Dock between the game and the overlay
    /// and breaks Shift+Tab.
    var isOverlayActive: Bool { overlayActive }

    /// The level such a popup sits at: above the overlay (the game's level + 1),
    /// so it is not hidden behind it. `nil` when no overlay is up.
    var overlayChildLevel: Int? { overlayGame.map { $0.layer + 2 } }

    /// Keep menu-bar diagnostics in step with Steam without driving its UI.
    func noteOverlayActivated(active: Bool, appID: String) {
        // A read-only observation: do not synthesize focus, input, opacity,
        // cursor restoration or child-window teardown around Steam's renderer.
        overlayActive = active
        overlayAppID = appID
        EventLog.shared.log(.window, "original Steam overlay \(active ? "active" : "inactive") for \(appID)")
    }

    /// Closes the overlay the way its own "Back to Game" does — through Steam,
    /// so the client's overlay state stays in step with ours. It answers with
    /// `RegisterForOverlayActivated(false)`, which drives the hide and returns
    /// focus to the game.
    func closeOverlay() {
        guard overlayActive, !overlayAppID.isEmpty else { return }
        let appID = overlayAppID
        Task(name: "Close Steam overlay") {
            _ = await evaluateInContext("SteamClient.Overlay.SetOverlayState(\(JSLiteral.string(appID)), 0)")
        }
    }

    /// While the overlay is up it holds key (so its chat and search take the
    /// keyboard), which means Shift+Tab — the toggle that would close it —
    /// lands in the overlay panel instead of the game's hook. This swallows
    /// that one chord and closes the overlay through Steam.
    private func installOverlayKeyMonitor() {
        removeOverlayKeyMonitor()
        overlayKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.overlayActive,
                      event.keyCode == 48, event.modifierFlags.contains(.shift)
                else { return false }
                self.closeOverlay()
                return true
            }
            return swallow ? nil : event
        }
    }

    private func removeOverlayKeyMonitor() {
        if let overlayKeyMonitor {
            NSEvent.removeMonitor(overlayKeyMonitor)
            self.overlayKeyMonitor = nil
        }
    }

    /// Whether the overlay group belongs on screen: only while active and while
    /// the game — or this app, once the overlay has taken key — is the
    /// frontmost application. Any other app in front (one the user switched to,
    /// or a window that raised itself) takes the overlay off screen with it.
    nonisolated static func overlayShouldShow(
        active: Bool, front: pid_t?, gamePID: pid_t?, ourPID: pid_t,
    ) -> Bool {
        // `let front` first: with no frontmost app, and none reported, a bare
        // `front == gamePID` would be nil == nil == true and show a stuck
        // overlay over the desktop when no game was even found.
        guard active, let front else { return false }
        return front == gamePID || front == ourPID
    }

    /// Shows the overlay at the game's frame and level only while the game — or
    /// this app, once the overlay has key — is frontmost; hides it whenever a
    /// third application is, so the overlay travels with the game and never
    /// covers anything else.
    private func applyOverlayPresence(_ overlay: SteamWindow) {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ours = ProcessInfo.processInfo.processIdentifier
        let shown = Self.overlayShouldShow(
            active: overlayActive, front: front, gamePID: overlayGame?.pid, ourPID: ours,
        )
        if shown {
            let frame: NSRect? = overlayGame.map { window in
                NSRect(
                    origin: SteamScreenSpace.appKitOrigin(
                        steamX: window.bounds.minX,
                        steamY: window.bounds.minY,
                        size: window.bounds.size,
                    ),
                    size: window.bounds.size,
                )
            }
            if overlayAppID == "730", embeddedFailureGamePID != overlayGame?.pid,
               embeddedOverlay.nativeFrameFits, let frame {
                embeddedOverlay.show(root: overlay, frame: frame)
            } else {
                overlay.showOverlay(frame: frame, level: overlayGame.map { $0.layer + 1 })
            }
        } else {
            embeddedOverlay.hide()
            overlay.setEmbeddedPresentation(false)
            overlay.hideOverlay()
        }
        // The children ride with the overlay: hidden when it is, shown when it
        // returns (a closed one's window is gone, so this no-ops for it).
        for child in overlayChildren {
            if embeddedOverlay.presenting {
                child.setEmbeddedPresentation(shown)
            } else {
                child.setOrderedIn(shown)
            }
        }
    }

    /// A failed capture must return the already accepted native panel, rather
    /// than leave an invisible backing window and blocked game input behind.
    func fallBackFromEmbeddedOverlay(_ reason: String) {
        guard overlayActive, embeddedOverlay.presenting,
              let root = popups.values.first(where: { $0.role == .gameOverlay }) else { return }
        let frame = root.window?.frame
        embeddedFailureGamePID = overlayGame?.pid
        embeddedOverlay.hide()
        root.setEmbeddedPresentation(false)
        root.showOverlay(frame: frame, level: overlayGame.map { $0.layer + 1 })
        for child in overlayChildren {
            child.setEmbeddedPresentation(false)
            child.show(activating: false)
        }
        EventLog.shared.log(.window, "embedded overlay unavailable (\(reason)); restored native panel for this game process")
    }

    private func installOverlayFrontObserver(_ overlay: SteamWindow) {
        removeOverlayFrontObserver()
        overlayFrontObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main,
        ) { [weak self, weak overlay] _ in
            MainActor.assumeIsolated {
                guard let self, let overlay else { return }
                self.applyOverlayPresence(overlay)
            }
        }
    }

    private func removeOverlayFrontObserver() {
        if let overlayFrontObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(overlayFrontObserver)
            self.overlayFrontObserver = nil
        }
    }

    /// Subscribes the context page to the client's overlay activation. The
    /// callback is Steam's own `OnOverlayActivated(unPID, unAppID, bActive, …)`
    /// (its handler does `GetOverlayInstance(appid, pid)` then, for a desktop
    /// overlay, `SetIsOverlayActive(bActive)`): the second argument is the
    /// app id, the third the shown flag. Both come back through the popup
    /// message handler as `__overlayActivated`; the app id lets the host close
    /// the overlay the way "Back to Game" does, `SetOverlayState(appid, 0)`.
    /// Re-registered on reload.
    static let overlayScript = """
    (function () {
      if (window.__sevoOverlay) return "already registered";
      if (!window.SteamClient || !SteamClient.Overlay
          || !SteamClient.Overlay.RegisterForOverlayActivated) return "unavailable";
      window.__sevoOverlay = true;
      SteamClient.Overlay.RegisterForOverlayActivated(function (pid, appid, active) {
        try {
          window.webkit.messageHandlers.sevoWindow.postMessage(
            { fn: "__overlayActivated", args: [active ? 1 : 0, String(appid || "")] });
        } catch (e) {}
      });
      return "registered";
    })()
    """
}
