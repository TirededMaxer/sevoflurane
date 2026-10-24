import AppKit
import WebKit

@MainActor
enum SteamFilePicker {
    static func present(
        for webView: WKWebView, parameters: WKOpenPanelParameters,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void,
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = !parameters.allowsDirectories
        let finish: @MainActor @Sendable (NSApplication.ModalResponse) -> Void = { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
        if let window = webView.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}
