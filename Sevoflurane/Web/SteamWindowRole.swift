import Foundation

/// What a popup Steam opened is for.
///
/// Steam names every popup it creates, and the name is the only thing that
/// distinguishes the desktop window from a context menu before either has any
/// content: both start as `about:blank` and are filled in by the opener. The
/// names are stable across releases because the popup manager builds them from
/// fixed bases (`SP Desktop`, `contextmenu_<n>`) plus a `_uid<pid>` suffix.
nonisolated enum SteamWindowRole {
    /// The hidden page that hosts Steam's JavaScript and opens everything else.
    case context
    /// The main desktop window — nav, library, store.
    case desktop
    /// Big Picture Mode, with Steam's own controls and fullscreen setting.
    case bigPicture
    /// The first-run login window.
    case login
    /// The on-screen keyboard: a floating panel that must not steal key focus
    /// from whatever is being typed into.
    case keyboard
    /// The controller configurator.
    case controllerConfig
    /// A context menu, root menu, or supernav flyout.
    case menu
    /// The friends list.
    case friends
    /// A chat window — one friend, a group, or several in tabs.
    case chat
    /// One of Steam's own notification toasts. Steam draws these into a
    /// borderless popup of their own, which under CEF is a Windows toast in
    /// the corner of the screen. The same Steam content is shown here in
    /// a non-activating panel anchored to the display’s bottom-right corner.
    case toast
    /// Steam's off-screen game page. CEF and GameOverlayRenderer own its
    /// browser, input and lifetime; the desktop host creates no mirror window.
    case gameOverlay
    /// Steam's generic modal dialog (`PopupWindow_…`): the "Shutting down
    /// Steam" notice, and the confirmations it raises over its main window.
    /// Centered on the desktop window and riding above it as its child, in a
    /// panel that never activates the app — Steam places these against its
    /// own screen model, which lands bottom-left here.
    case dialog
    /// Anything else Steam pops out: game notes, broadcasts, the overlay.
    case auxiliary

    init(popupName: String) {
        let base = Self.base(ofPopupNamed: popupName)
        self = Self.names.first { $0.match.matches(base: base) }?.role ?? .auxiliary
    }

    /// How Steam spells one popup's name.
    enum NameMatch: Equatable, Sendable {
        /// The whole base. Exact, or `SP DesktopLoginWindow` would classify
        /// as the desktop window.
        case exact(String)
        /// The start of a base Steam numbers or suffixes per instance
        /// (`contextmenu_10`, `notificationtoasts_1_desktop`).
        case prefix(String)

        func matches(base: String) -> Bool {
            switch self {
            case let .exact(name): base == name
            case let .prefix(start): base.hasPrefix(start)
            }
        }
    }

    /// Every name Steam gives a popup, and what that popup is for.
    ///
    /// One table: ``init(popupName:)`` reads it, and so does the sweep that
    /// has to tell the client's twins of this app's own windows from the
    /// windows only the client has. The fixed bases come first, so a family's
    /// prefix cannot take a name a fixed base already claims.
    static let names: [(match: NameMatch, role: SteamWindowRole)] = [
        (.exact("SP Desktop"), .desktop),
        (.exact("SP BPM"), .bigPicture),
        (.exact("SP DesktopLoginWindow"), .login),
        (.exact("SP Keyboard"), .keyboard),
        (.exact("SP Controller Configurator"), .controllerConfig),
        (.prefix("contextmenu_"), .menu),
        (.prefix("friendslist"), .friends),
        (.prefix("chat_"), .chat),
        (.prefix("notificationtoasts"), .toast),
        (.prefix("desktopoverlay"), .gameOverlay),
        (.prefix("gamepadoverlay"), .gameOverlay),
        (.prefix("PopupWindow_"), .dialog),
    ]

    /// The part of a popup's name that names its kind — everything before the
    /// `_uid<pid>` suffix Steam stamps on every one.
    static func base(ofPopupNamed popupName: String) -> String {
        guard let range = popupName.range(of: "_uid") else { return popupName }
        return String(popupName[..<range.lowerBound])
    }

    /// The kinds the bottled client keeps a second copy of: this app draws
    /// the desktop, friends, chat and corner toasts. The client's copy is
    /// a window nobody should see, and hiding it costs nothing.
    ///
    /// Every other kind is the client's alone — an install or EULA modal, the
    /// sign-in window, a menu, a game's own popup — and a sweep that hides
    /// one takes away a window the user was given for a reason.
    static let twinRoles: Set<SteamWindowRole> = [.toast, .desktop, .friends, .chat]

    /// The names those windows carry, for a sweep that may hide only them.
    static var twinNames: [NameMatch] {
        names.filter { twinRoles.contains($0.role) }.map(\.match)
    }

    /// Which UI instance opened a popup, from the `_uid<n>` suffix Steam
    /// gives every name: 0 is the desktop UI; a game's overlay UI stamps its
    /// popups with the game's pid (`friendslist_uid2220`), so a friends list
    /// or a game overview with a non-zero uid belongs to that overlay, not to
    /// the desktop, however ordinary its name looks.
    static func instanceUID(ofPopupNamed popupName: String) -> Int {
        guard let range = popupName.range(of: "_uid", options: .backwards) else { return 0 }
        // Steam toasts append the notification id after the game id:
        // notificationtoasts_uid730-123. Match the numeric instance prefix.
        return Int(popupName[range.upperBound...].prefix(while: { $0.isNumber })) ?? 0
    }

    /// Steam renders these pages inside the game. They must never acquire a
    /// second NSWindow or be hidden/closed by the desktop mirror.
    static func usesOriginalGameOverlay(popupName: String) -> Bool {
        let role = Self(popupName: popupName)
        if role == .gameOverlay { return true }
        if role == .toast && (popupName.contains("_gameoverlay") || popupName.contains("_overlay")) { return true }
        return instanceUID(ofPopupNamed: popupName) != 0
            && role != .desktop && role != .login && role != .bigPicture && role != .context
    }

    /// Panels never activate the app or take key focus from other apps. The
    /// game overlay is one: it takes key focus itself while active (for its
    /// own input) but must never promote the app to a regular one or steal
    /// focus on Steam's behalf.
    var isPanel: Bool {
        self == .menu || self == .keyboard || self == .gameOverlay || self == .dialog || self == .toast
    }

    /// Original popup headers declare their blank draggable regions. The
    /// document keeps its own title, controls, fonts and layout.
    var hasPopupChrome: Bool {
        switch self {
        case .auxiliary, .controllerConfig, .chat, .friends: true
        default: false
        }
    }

    /// The context page stays hidden; all user-facing Steam windows may show.
    var isShowable: Bool {
        self != .context && self != .gameOverlay
    }

    /// Whether a frame that lands on no display is a mistake.
    ///
    /// A window a person opens and then goes looking for has to be somewhere
    /// they can reach. The kinds left out are the ones
    /// Steam deliberately puts nowhere: a context menu is parked far
    /// off-screen between uses and re-placed against its parent on every
    /// show, a toast is anchored by this app, the keyboard is a panel Steam
    /// positions itself, and the overlay is placed over the game.
    var needsAReachableFrame: Bool {
        switch self {
        case .context, .menu, .keyboard, .toast, .gameOverlay: false
        case .desktop, .bigPicture, .login, .controllerConfig, .auxiliary, .friends, .chat, .dialog: true
        }
    }

    /// Whether WebKit may mark this window's page hidden when the occlusion
    /// service says it is covered — which stops animations, rAF, and the layer
    /// commits behind them.
    ///
    /// On for the windows that are genuinely on screen and can genuinely be
    /// covered: an obscured library should no more animate here than Steam's
    /// own client animates one on Windows. Off for the kinds whose pages
    /// would otherwise never run at all: the context page lives in a window
    /// with no size, a toast must keep running its
    /// dismissal timer to tick, and pop-up-level panels report as occluded
    /// even while visible — their pages then never run their fade-ins, and
    /// Steam's menu re-measure loop flickers the window.
    var allowsOcclusionDetection: Bool {
        switch self {
        case .context, .menu, .keyboard, .toast, .gameOverlay: false
        case .desktop, .bigPicture, .login, .controllerConfig, .auxiliary, .friends, .chat, .dialog: true
        }
    }
}
