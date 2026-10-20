import Foundation

/// What a sweep of the client's own popup windows is allowed to put away.
enum PopupSweepScope: String, Sendable {
    /// Every visible popup the client has. The stop path and the supervisor's
    /// cycle ask for this: the client is coming down, or every window it has
    /// on the Wine desktop is one this app already renders natively.
    case everything
    /// Only the client's copies of what this app puts on screen itself
    /// (``SteamWindowRole/twinRoles``), leaving unrelated install dialogs
    /// and game popups alone.
    case twins
}

/// One sweep's result: what it hid, and what it was allowed to hide, so a
/// caller can say which in its log rather than guess from the names.
struct PopupSweep: Sendable {
    let scope: PopupSweepScope
    let names: [String]
}

/// Coalesces lifecycle sweeps so concurrent stop and supervisor requests
/// share one CDP evaluation. Notification presentation has no sweep schedule.
actor PopupSweeper {
    static let shared = PopupSweeper()

    /// Sweeps happen no closer together than this, whoever asks.
    static let minimumInterval: Duration = .seconds(1)

    private let interval: Duration
    private let hide: @Sendable (PopupSweepScope) async -> [String]
    private var lastSweep: ContinuousClock.Instant?
    private var inFlight: Task<PopupSweep, Never>?

    /// `hide` reads the hook at each sweep rather than capturing it, because
    /// the app installs the bridge's sweep after the shared sweeper exists.
    init(
        minimumInterval: Duration = PopupSweeper.minimumInterval,
        hide: @escaping @Sendable (PopupSweepScope) async -> [String] = { scope in
            await ClientLifecycle.hidePopupsOverBridge(scope)
        },
    ) {
        interval = minimumInterval
        self.hide = hide
    }

    /// Hides what the client has on screen now, joining a sweep already in
    /// flight and otherwise waiting out the minimum interval first.
    ///
    /// Answers what was hidden and what the sweep that hid it was allowed to
    /// hide, so a caller can name them in the log, the supervisor can spot the
    /// sign-in window among them, and a narrow ask that joined a wider sweep
    /// already in flight says so rather than claiming those windows.
    @discardableResult
    func sweep(_ scope: PopupSweepScope = .everything) async -> PopupSweep {
        if let inFlight { return await inFlight.value }
        let since = lastSweep?.duration(to: .now)
        let sweep = Task(name: "Hide the client's popups") { [interval, hide] () -> PopupSweep in
            if let since, since < interval {
                try? await Task.sleep(for: interval - since)
            }
            return await PopupSweep(scope: scope, names: hide(scope))
        }
        inFlight = sweep
        let hidden = await sweep.value
        lastSweep = .now
        inFlight = nil
        return hidden
    }
}
