import AppKit
import WebKit

/// The browser engine owns the transfer and cookies; AppKit asks where to save.
@MainActor
final class SteamDownloads: NSObject, WKDownloadDelegate {
    static let shared = SteamDownloads()
    private var active: [ObjectIdentifier: WKDownload] = [:]

    func start(_ value: String, in webView: WKWebView) {
        let route = value.replacingOccurrences(of: LoopbackAssets.clientOrigin,
                                                with: LoopbackAssets.pageOrigin + LoopbackAssets.pathPrefix)
        guard let url = URL(string: route),
              ["http", "https", "blob", "data", "file"].contains(url.scheme ?? "") else { return }
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            self?.adopt(download)
        }
    }

    func adopt(_ download: WKDownload) {
        active[ObjectIdentifier(download)] = download
        download.delegate = self
    }

    func download(
        _ download: WKDownload, decideDestinationUsing _: URLResponse,
        suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void,
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            let destination = response == .OK ? panel.url : nil
            if destination == nil { self?.active.removeValue(forKey: ObjectIdentifier(download)) }
            completionHandler(destination)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        active.removeValue(forKey: ObjectIdentifier(download))
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData _: Data?) {
        active.removeValue(forKey: ObjectIdentifier(download))
        EventLog.shared.log(.page, "WebKit download failed: \(error.localizedDescription)")
    }
}
