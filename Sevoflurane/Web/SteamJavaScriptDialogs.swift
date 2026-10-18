import AppKit
import WebKit

/// Browser dialogs keep their JavaScript contract. The host supplies only the
/// native panel and returns the exact acknowledgement, Boolean or text value.
extension SteamWebCoordinator {
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        ModalAlerts.present {
            let alert = Self.javaScriptAlert(message: message, cancel: false)
            _ = alert.runModal()
            completionHandler()
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        ModalAlerts.present {
            let alert = Self.javaScriptAlert(message: message, cancel: true)
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        ModalAlerts.present {
            let alert = Self.javaScriptAlert(message: prompt, cancel: true)
            let field = NSTextField(string: defaultText ?? "")
            field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    static func javaScriptAlert(message: String, cancel: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: String(localized: "OK"))
        if cancel { alert.addButton(withTitle: String(localized: "Cancel")) }
        return alert
    }
}
