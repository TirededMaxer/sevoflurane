import AppKit
import ObjectiveC

/// Manual diagnostics and cancellation for AppKit's menu tracking session.
/// The native menu mirror uses these explicit recovery actions; it does not
/// install the retired automatic watchdog.
@MainActor
enum MenuTrackingRecovery {
    /// The private dismissal repair applies only to the macOS 27 menu-bar implementation.
    static var privateLeverEngages: Bool {
        if #available(macOS 27, *) { true } else { false }
    }

    /// The result of reaching for a private tracking session, for the log.
    struct StopOutcome: Equatable {
        /// Where a session was found, or `nil` when none was.
        var sessionSource: String?
        /// The levers the session accepted, in order, or `nil` when a session
        /// was found but none applied.
        var enderSent: String?

        /// The log line describing what the lever reached, shared by every
        /// caller so a report reads the same words wherever it fired.
        var summary: String {
            switch (sessionSource, enderSent) {
            case let (source?, ender?):
                "found the tracking session via \(source), sent \(ender)"
            case let (source?, nil):
                "found the tracking session via \(source) but it responded to no ender"
            case (nil, _):
                "no tracking session found on the main menu or the open menus"
            }
        }
    }

    /// Ends every menu-bar tracking session, synchronously. The submenu a
    /// title owns is not the session's root — cancelling it leaves a menu-bar
    /// session running — so the main menu is the one that has to be told.
    /// The animated `cancelTracking()` is never used here: its completion
    /// arrives through the run loop the stuck session is parked in.
    static func cancelMenuBarTracking() {
        NSApp.mainMenu?.cancelTrackingWithoutAnimation()
    }

    /// Posts the kind of event the session's own dismissal posts to wake its
    /// `nextEventMatchingMask:`: an AppKit-defined event, which the loop's
    /// mask takes and its handler ignores. The loop exits on the flag the
    /// lever already cleared, not on this event.
    private static func postWakeup() {
        guard let wake = NSEvent.otherEvent(
            with: .appKitDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0,
        ) else { return }
        NSApp.postEvent(wake, atStart: true)
    }

    // MARK: - The private levers

    /// What the private levers can do to a session. Each is a private
    /// `NSMenuTrackingSession` surface reached by `responds(to:)`/`perform`,
    /// so a selector renamed on a future macOS is a logged no-op rather than
    /// a crash — this is a workaround for the macOS 27 out-of-process menu
    /// bar, and the private surface is not a contract Apple keeps stable.
    enum Lever: String, CaseIterable {
        /// `dismissAnimated:NO` — the synchronous end, and what the public
        /// `cancelTrackingWithoutAnimation()` sends.
        case dismiss = "dismissAnimated:NO"
        /// What a stalled animated dismissal's completion would have done:
        /// the pre-dispatch actions (which clear the loop's flag and post the
        /// wake-up), then `_isDismissing` cleared so the session is not stuck
        /// refusing every later dismissal.
        case repair = "_performPreDispatchDismissalActions + isDismissing=NO"
        /// `stopMonitoringEvents` — clears the loop's flag with no restore of
        /// key window or input context, then a posted wake-up.
        case stop = "stopMonitoringEvents + wake"
    }

    /// Manual recovery on the main actor, including a live nested menu loop.
    /// The control endpoint and Settings action call this directly; there is
    /// no timer or automatic input synthesis.
    @discardableResult
    static func stopPrivateSession(
        candidateMenus: [NSMenu], levers: [Lever] = Lever.allCases,
    ) -> StopOutcome {
        guard let (source, session) = trackingSessions(candidateMenus: candidateMenus).first else {
            return StopOutcome(sessionSource: nil, enderSent: nil)
        }
        var sent: [String] = []
        for lever in levers where pull(lever, on: session) {
            sent.append(lever.rawValue)
        }
        return StopOutcome(sessionSource: source, enderSent: sent.isEmpty ? nil : sent.joined(separator: ", "))
    }

    /// Sends one lever, answering whether the session took it. `repair` is
    /// only for a session stuck mid-dismissal; on any other it would end a
    /// session that is ending on its own.
    private static func pull(_ lever: Lever, on session: NSObject) -> Bool {
        switch lever {
        case .dismiss:
            guard isDismissing(session) != true else { return false }
            return send(session, "dismissAnimated:", flag: false)
        case .repair:
            guard isDismissing(session) == true else { return false }
            guard send(session, "_performPreDispatchDismissalActions") else { return false }
            setDismissing(session, false)
            return true
        case .stop:
            guard send(session, "stopMonitoringEvents") else { return false }
            postWakeup()
            return true
        }
    }

    // MARK: Reading the session

    /// The session's class and the two flags the levers turn on, for the log
    /// and for `GET /menu/session`.
    static func sessionDescription() -> String {
        guard let session = currentTrackingSession() else { return "no current tracking session" }
        let dismissing = isDismissing(session).map { "\($0)" } ?? "?"
        let running = isRunningEventLoop(session).map { "\($0)" } ?? "?"
        return "\(NSStringFromClass(type(of: session))) isDismissing=\(dismissing) isRunningEventLoop=\(running)"
    }

    /// The menu-bar impl in use and the current session's flags, for the
    /// control port. `outOfProcess` is whether the main menu is mirrored into
    /// the macOS 27 menu-bar agent, which is what the Info.plist key
    /// `NSMenuDisableOutOfProcessMenusDueToIncompatibility` turns off.
    static func diagnostics() -> [String: Any] {
        var result: [String: Any] = [:]
        if let menu = NSApp.mainMenu, let impl = menuImpl(of: menu) {
            let name = NSStringFromClass(type(of: impl))
            result["mainMenuImpl"] = name
            result["outOfProcess"] = name.contains("Remote")
        }
        if let session = currentTrackingSession() {
            result["session"] = [
                "class": NSStringFromClass(type(of: session)),
                "isDismissing": isDismissing(session) as Any,
                "isRunningEventLoop": isRunningEventLoop(session) as Any,
            ] as [String: Any]
        } else {
            result["session"] = NSNull()
        }
        return result
    }

    private static func isDismissing(_ session: NSObject) -> Bool? {
        flag(session, ivar: "_isDismissing", key: "isDismissing")
    }

    private static func isRunningEventLoop(_ session: NSObject) -> Bool? {
        flag(session, ivar: "_isRunningEventLoop", key: "isRunningEventLoop")
    }

    private static func setDismissing(_ session: NSObject, _ value: Bool) {
        guard class_getInstanceVariable(type(of: session), "_isDismissing") != nil else { return }
        session.setValue(value, forKey: "isDismissing")
    }

    /// A BOOL ivar read through key-value coding, only when the ivar exists:
    /// an undefined key raises an Objective-C exception nothing here could
    /// catch.
    private static func flag(_ session: NSObject, ivar: String, key: String) -> Bool? {
        guard class_getInstanceVariable(type(of: session), ivar) != nil else { return nil }
        return (session.value(forKey: key) as? NSNumber)?.boolValue
    }

    // MARK: Finding the session

    /// Every tracking session reachable now, newest source first: the class's
    /// current session, then each candidate menu's impl's session.
    private static func trackingSessions(candidateMenus: [NSMenu]) -> [(String, NSObject)] {
        var found: [(String, NSObject)] = []
        if let current = currentTrackingSession() {
            found.append(("currentSession", current))
        }
        for menu in candidateMenus {
            guard let session = trackingSession(of: menu) else { continue }
            found.append(("menu ‘\(menu.title)’", session))
        }
        return found
    }

    /// `+[NSMenuTrackingSession currentSession]`, reached reflectively.
    private static func currentTrackingSession() -> NSObject? {
        guard let cls = NSClassFromString("NSMenuTrackingSession") else { return nil }
        return perform(cls as AnyObject, "currentSession")
    }

    /// A menu's private impl. `_menuImplIfExists` comes first because it
    /// never creates one; where AppKit lacks it, `_menuImpl` and
    /// `_menuImplForCallbacks` answer instead, and those may create an impl
    /// for a menu that had none.
    private static func menuImpl(of menu: NSMenu) -> NSObject? {
        for accessor in ["_menuImplIfExists", "_menuImpl", "_menuImplForCallbacks"] {
            if let impl = perform(menu, accessor) { return impl }
        }
        return nil
    }

    private static func trackingSession(of menu: NSMenu) -> NSObject? {
        guard let impl = menuImpl(of: menu) else { return nil }
        return perform(impl, "trackingSession")
    }

    /// Sends a selector the session responds to, with a `BOOL` argument when
    /// `flag` is given. The return value is discarded without dereferencing,
    /// so a selector that returns `void` or `BOOL` is safe to send.
    private static func send(_ session: NSObject, _ name: String, flag: Bool? = nil) -> Bool {
        let selector = NSSelectorFromString(name)
        guard session.responds(to: selector) else { return false }
        if let flag {
            // `perform(_:with:)` delivers its object argument as the raw
            // pointer, which the callee reads as its BOOL: nil is NO.
            _ = session.perform(selector, with: flag ? session : nil)
        } else {
            _ = session.perform(selector)
        }
        return true
    }

    /// Sends a zero-argument getter and returns its object result, or `nil`
    /// when the target does not respond or the getter returned `nil`. The
    /// getters used here (`currentSession`, `_menuImpl*`, `trackingSession`)
    /// are `+0` returns, so the value is taken unretained.
    private static func perform(_ target: AnyObject, _ name: String) -> NSObject? {
        let selector = NSSelectorFromString(name)
        guard target.responds(to: selector) else { return nil }
        let result: Unmanaged<AnyObject>? = target.perform(selector)
        return result?.takeUnretainedValue() as? NSObject
    }

}
