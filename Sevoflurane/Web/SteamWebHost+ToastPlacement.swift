import AppKit
import WebKit

extension SteamWebHost {
    /// The original toast code selects the OS work area on the desktop and
    /// the complete game canvas in an overlay (sp.js modules 25625/15148).
    /// WebKit owns the one general queue in both cases, so its platform
    /// monitor binding follows that presentation target without changing
    /// notification content, timing, animation or Steam's overlay state.
    func installToastPlacementObservers() {
        guard !toastPlacementObserversInstalled else { return }
        toastPlacementObserversInstalled = true
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.refreshToastViewport() }
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main,
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.refreshToastViewport() }
        }
        refreshToastViewport()
    }

    /// Also refreshed before a toast is realized: a windowed game can move
    /// or resize without activating another application. No frame polling.
    func refreshToastViewport() {
        let viewport = GameWindow.frontmostGameFrame().map {
            CGRect(x: $0.minX, y: SteamScreenSpace.flipLine - $0.maxY, width: $0.width, height: $0.height)
        }
        guard viewport != toastViewport else { return }
        toastViewport = viewport
        // Steam already listens for this platform display-change message,
        // re-queries its monitor binding and repositions any active stack.
        context?.webView.evaluateJavaScript("window.postMessage('display_changed', '*')", completionHandler: nil)
    }
}
