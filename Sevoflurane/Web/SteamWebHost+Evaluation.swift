import AppKit
import WebKit

extension SteamWebHost {
    /// Evaluates a script in the hidden context page and returns its result,
    /// which the script must produce as a string — structured results cross
    /// as JSON. The completion-handler API is wrapped by hand because the
    /// async overlay traps when the script's value is `null`; here a stray
    /// null answers `nil` instead of crashing.
    func evaluateInContext(_ script: String) async -> String? {
        guard let webView = context?.webView else { return nil }
        return await evaluateInWebView(script, webView: webView)
    }

    /// Evaluates a script in any of this host's web views, through ``evaluator``.
    func evaluateInWebView(
        _ script: String, webView: WKWebView, timeout: Duration = .seconds(20),
    ) async -> String? {
        await evaluator.evaluateInWebView(script, webView: webView, timeout: timeout)
    }

    /// A desktop link must navigate the visible WebKit instance, rather
    /// than the hidden Windows client's desktop. Steam still chooses its
    /// store/community route through the original NavigateToSteamWeb method.
    func openClientURL(_ url: URL, externally: Bool) {
        if url.scheme?.lowercased() == "steam" {
            executeSteamURL(url)
            return
        }
        guard url.scheme == "http" || url.scheme == "https" else { return }
        if externally {
            NSWorkspace.shared.open(url)
            return
        }
        showSteam()
        Task(name: "Open Steam web link") { [weak self] in
            guard let self else { return }
            // showSteam may rebuild a closed desktop and route its initial
            // library. Navigate only after that route, so it cannot erase
            // the link the user selected.
            for _ in 0 ..< 40 {
                if desktop != nil, hasRoutedDesktop, !isRoutingDesktop {
                    let result = await evaluateInContext("""
                    (function () {
                      if (!window.__sevoIsReady || !__sevoIsReady()) return 'unavailable';
                      var instance = window.SteamUIStore && SteamUIStore.WindowStore
                        && SteamUIStore.WindowStore.MainWindowInstance;
                      if (!instance || typeof instance.NavigateToSteamWeb !== 'function') return 'unavailable';
                      instance.NavigateToSteamWeb(\(JSLiteral.string(url.absoluteString)));
                      return 'opened';
                    })()
                    """)
                    if result == "opened" { return }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            EventLog.shared.log(.window, "Steam web link could not find its ready desktop navigator")
        }
    }

    /// Runs a `steam://` URL against the handlers this page registered — the
    /// dispatch CEF's scheme interception ends in, without the client round
    /// trip. `ExecuteSteamURL` broadcasts to every UI including the bottle
    /// client's own, which then raises a real (visible) Wine window for
    /// dialogs like About; the local path keeps it in this process. The round
    /// trip remains as fallback for URLs only the client resolves.
    ///
    /// A page that is still booting answers `-1`: the URL is queued on the
    /// readiness promise and will run in this process, so the fallback that
    /// would raise a Wine window stays down.
    func executeSteamURL(_ url: URL) {
        let literal = JSLiteral.string(url.absoluteString)
        Task(name: "Run \(url.absoluteString)") {
            let handled = await evaluateInContext(
                "String(window.__sevoRunSteamURL ? __sevoRunSteamURL(\(literal)) : 0)",
            )
            if handled == nil || handled == "0" {
                _ = await evaluateInContext(
                    "SteamClient.URL.ExecuteSteamURL(\(literal)), \"sent\"",
                )
            }
        }
    }
}
