import AppKit
import WebKit

/// A web view whose first click counts.
///
/// The click that selects a Steam window also belongs to its original page.
/// Waiting for a second click makes desktop controls behave differently from
/// Steam, just as it does for a never-key menu panel.
final class SteamWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// Embedded pages use Steam's existing find bar. Cmd-F must notify that
/// bar instead of vanishing into the unimplemented CEF keyboard shortcut.
final class SteamBrowserWebView: WKWebView {
    var onFind: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "f", let onFind {
            onFind()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

extension WKWebView {
    /// These pages already reserve space for the traffic lights. Automatic
    /// native titlebar insets would add a second strip above their content.
    func usePageIntegratedTitlebar() {
        let selector = Selector(("_setAutomaticallyAdjustsContentInsets:"))
        if responds(to: selector) {
            typealias SetInsets = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
            let setInsets = unsafeBitCast(method(for: selector), to: SetInsets.self)
            setInsets(self, selector, false)
        }
        if #available(macOS 26.0, *) {
            obscuredContentInsets = NSEdgeInsetsZero
        }
    }
}

// MARK: - WebKit plumbing

/// The WebKit delegates, kept off ``SteamWebHost`` so the observable state is
/// not also an `NSObject` full of protocol conformances.
@MainActor
final class SteamWebCoordinator: NSObject {
    static let handlerName = "sevoWindow"

    private weak var host: SteamWebHost?

    init(host: SteamWebHost) {
        self.host = host
    }
}

extension SteamWebCoordinator: WKUIDelegate {
    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame _: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void,
    ) {
        Task { [weak self] in
            if let url = await self?.host?.window(for: webView)?.takePendingUpload() {
                completionHandler([url])
            } else {
                SteamFilePicker.present(for: webView, parameters: parameters, completionHandler: completionHandler)
            }
        }
    }

    func webView(
        _: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures,
    ) -> WKWebView? {
        // Steam's popup manager always opens about:blank and writes into it;
        // a popup opened straight onto http(s) is an external link, and those
        // belong in the user's browser, not in an orphan app window.
        if let url = navigationAction.request.url,
           url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            return nil
        }
        return host?.adoptPopup(configuration: configuration, features: windowFeatures)
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let popup = host?.window(for: webView) {
            popup.detach(reason: .steamClosedIt)
        }
    }

    /// WebKit's source of truth for `window.screenX/screenY/outer*` — without
    /// this (private) delegate method it answers a zero rect, which Steam's
    /// menu placement reads as "the window fills nothing at the bottom of the
    /// screen" and flips every flyout upward. The rect is the AppKit frame;
    /// WebKit flips it to CSS coordinates itself (`convertToUserSpace`).
    @objc(_webView:getWindowFrameWithCompletionHandler:)
    func _webView(
        _ webView: WKWebView,
        getWindowFrameWithCompletionHandler completionHandler: @escaping (CGRect) -> Void,
    ) {
        completionHandler(host?.window(for: webView)?.appKitFrame ?? .zero)
    }
}

/// The navigation policy shared by every web view hosting Steam content:
/// page traffic passes, `steam://` routes back into the client, and any
/// other scheme is cancelled — CEF intercepts unknown schemes, while
/// WKWebView would hand them to LaunchServices, launching the real Mac
/// Steam app.
@MainActor
func steamNavigationPolicy(for url: URL?, host: SteamWebHost?) -> WKNavigationActionPolicy {
    guard let url, let scheme = url.scheme?.lowercased() else { return .allow }
    switch scheme {
    case "http", "https", "about", "blob", "data":
        return .allow
    case "steam":
        host?.executeSteamURL(url)
        return .cancel
    default:
        return .cancel
    }
}

extension SteamWebCoordinator: WKNavigationDelegate {
    func webView(_: WKWebView, navigationAction _: WKNavigationAction, didBecome download: WKDownload) {
        SteamDownloads.shared.adopt(download)
    }

    func webView(_: WKWebView, navigationResponse _: WKNavigationResponse, didBecome download: WKDownload) {
        SteamDownloads.shared.adopt(download)
    }

    func webView(_: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        response.canShowMIMEType ? .allow : .download
    }

    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
    ) async
        -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload { return .download }
        return steamNavigationPolicy(for: navigationAction.request.url, host: host)
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        guard host?.window(for: webView)?.role == .context else { return }
        host?.setStatus("Steam UI booted — waiting for its window")
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: any Error) {
        host?.setStatus("load failed: \(error.localizedDescription)")
        EventLog.shared.log(.page, "page load failed: \(error.localizedDescription)")
    }

    func webView(
        _: WKWebView,
        didFailProvisionalNavigation _: WKNavigation!,
        withError error: any Error,
    ) {
        host?.setStatus("bridge unreachable: \(error.localizedDescription)")
        EventLog.shared.log(.bridge, "bridge unreachable: \(error.localizedDescription)")
    }

    /// The page's own process died. WebKit leaves the view blank and alive
    /// rather than taking the app with it, so this is recoverable — but only
    /// if someone recovers it: a dead web process is indistinguishable from a
    /// hung Steam UI from the outside.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        host?.webProcessDidTerminate(for: webView)
    }
}

extension SteamWebCoordinator: WKScriptMessageHandlerWithReply {
    /// Every `SteamClient.Window` call arrives here. `message.webView` is the
    /// window the call is about, which is why the shim posts through the
    /// popup's own handler rather than the opener's: it identifies the target
    /// without a handshake.
    func userContentController(
        _: WKUserContentController,
        didReceive message: WKScriptMessage,
    ) async -> (Any?, String?) {
        let origin = message.frameInfo.securityOrigin
        guard Self.admitsMessage(
            isMainFrame: message.frameInfo.isMainFrame,
            origin: (origin.protocol, origin.host, origin.port),
        ) else {
            return (nil, nil)
        }
        guard let body = message.body as? [String: Any],
              let function = body["fn"] as? String,
              let webView = message.webView,
              let window = host?.window(for: webView) else {
            return (nil, nil)
        }
        let args = body["args"] as? [Any] ?? []
        if function == "__clearWebData" {
            await WKWebsiteDataStore.default().removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast,
            )
            return (nil, nil)
        }
        let result = window.perform(function, args)
        return (result, nil)
    }

    /// Whether a message comes from Steam's UI: the top document of one of
    /// its windows, on the bridge's origin. Steam's popups open `about:blank`
    /// and inherit that origin from their opener; a frame the UI embeds, or a
    /// window that has navigated to a web site, carries another.
    nonisolated static func admitsMessage(
        isMainFrame: Bool,
        origin: (scheme: String, host: String, port: Int),
    ) -> Bool {
        isMainFrame && origin.scheme == "http" && origin.host == "127.0.0.1"
            && origin.port == Int(BridgePorts.steamUI)
    }
}
