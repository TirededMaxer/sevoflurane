import CryptoKit
import Foundation
import Synchronization

/// The client's own origin, `https://steamloopback.host`, as this page has to
/// address it.
///
/// CEF serves Steam's UI from that origin and answers a handful of synthetic
/// paths under it — window icons, overlay thumbnails, game recordings. WebKit
/// resolves none of it: the host does not exist outside the client, and a
/// `postMessage` whose `targetOrigin` does not match the receiver is a silent
/// no-op, which is how the friends and chat channel goes quiet with nothing in
/// any log. So the origin is rewritten out of the bundle as it is served.
///
/// Two rewrites, told apart by the character after the literal. A literal that
/// ends its string is an origin the bundle compares or posts to, and becomes
/// this server's own. Anything else is the head of a URL, and moves under
/// ``pathPrefix`` where the bridge can answer it.
nonisolated enum LoopbackAssets {
    /// The origin CEF gives the client's UI.
    static let clientOrigin = "https://steamloopback.host"

    /// The path everything the client used to serve is reachable under.
    static let pathPrefix = "/__loopback"

    /// The endpoints the client synthesizes rather than reads from disk. They
    /// exist only inside CEF, so the bridge asks the client for them.
    static let clientSynthesized = [
        "/windows/icon", "/overlays/thumbnail", "/gamerecordings/",
    ]

    static var pageOrigin: String { "http://127.0.0.1:\(BridgePorts.steamUI)" }

    /// The Steam install's directories that hold the account rather than the
    /// client: sign-in tokens and the account list, per-user data, logs, and
    /// crash dumps with process memory in them.
    static let privateDirectories: Set<String> = ["config", "userdata", "logs", "dumps"]

    /// Whether a path under ``pathPrefix`` may be read from the Steam install.
    /// Files at the install's root (`ssfn*`, `*.vdf`, the binaries) and the
    /// ``privateDirectories`` are withheld; the UI's own assets live in
    /// subdirectories. Judged on the decoded, normalized path, and without
    /// case, as the file system resolves it.
    static func isServable(_ path: String) -> Bool {
        guard let decoded = path.removingPercentEncoding else { return false }
        let components = URL(fileURLWithPath: "/" + decoded).standardizedFileURL.pathComponents.dropFirst()
        guard components.count >= 2, let top = components.first?.lowercased() else { return false }
        return !privateDirectories.contains(top)
    }

    /// Rewrites every occurrence of the client's origin in a text asset.
    static func rewritten(_ text: String) -> String {
        let asOrigin = pageOrigin
        let asURL = pageOrigin + pathPrefix
        var out = ""
        out.reserveCapacity(text.utf8.count + 4096)
        var rest = Substring(text)
        while let hit = rest.range(of: clientOrigin, options: .literal) {
            out += rest[rest.startIndex ..< hit.lowerBound]
            let next = hit.upperBound < rest.endIndex ? rest[hit.upperBound] : "\u{0}"
            out += (next == "\"" || next == "'" || next == "`") ? asOrigin : asURL
            rest = rest[hit.upperBound...]
        }
        out += rest
        return out
    }

    /// Refresh unmounts Library Home after WebKit has cleared its React refs.
    /// Keep the Window used to register the drag listeners so cleanup can
    /// still remove them. Match only Steam's showcase tracker in sp.js.
    static func repairShowcaseListenerCleanup(_ text: String) -> String {
        let start = #"StartGlobalMouseTracking\(\)\{const ([\w$]+)=(\(0,[\w$]+\.[\w$]+\)\(this\.m_refOuter\.current\));\1\.addEventListener\("mouseup",this\.OnGlobalMouseUp\),\1\.addEventListener\("mousemove",this\.OnGlobalMouseMove\),"#
        let stop = #"StopGlobalMouseTracking\(\)\{const ([\w$]+)=\(0,[\w$]+\.[\w$]+\)\(this\.m_refOuter\.current\);\1\.removeEventListener\("mouseup",this\.OnGlobalMouseUp\),\1\.removeEventListener\("mousemove",this\.OnGlobalMouseMove\),this\.props\.scrollElement\.removeEventListener\("scroll",this\.OnScrollParentScroll\),this\.m_resizeObserver\?\.unobserve\(this\.m_refSortableContainer\.current\)\}"#
        guard text.range(of: start, options: .regularExpression) != nil,
              text.range(of: stop, options: .regularExpression) != nil else { return text }
        return text.replacingOccurrences(
            of: start,
            with: #"StartGlobalMouseTracking(){const $1=$2;this.__sevoTrackingWindow=$1,$1.addEventListener("mouseup",this.OnGlobalMouseUp),$1.addEventListener("mousemove",this.OnGlobalMouseMove),"#,
            options: .regularExpression,
        ).replacingOccurrences(
            of: stop,
            with: #"StopGlobalMouseTracking(){const win=this.__sevoTrackingWindow;this.__sevoTrackingWindow=void 0;win?.removeEventListener("mouseup",this.OnGlobalMouseUp);win?.removeEventListener("mousemove",this.OnGlobalMouseMove);this.props.scrollElement?.removeEventListener("scroll",this.OnScrollParentScroll);const target=this.m_refSortableContainer.current;if(target)this.m_resizeObserver?.unobserve(target)}"#,
            options: .regularExpression,
        )
    }

    /// The bytes to serve for `target` when it addresses the client's origin,
    /// or nil when the file is to be served as it sits on disk.
    ///
    /// Few files need this and some are large, so the rewritten copy is cached
    /// under the app's caches directory and the source is read only when the
    /// cache misses. A file found not to need it is remembered by revision
    /// and not read again. Everything else keeps the mapped path
    /// ``SteamBridge`` serves assets by.
    static func rewrittenBytes(for target: URL) -> Data? {
        let ext = target.pathExtension.lowercased()
        guard ext == "js" || ext == "css" else { return nil }
        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: target.path),
            let size = attributes[.size] as? Int,
            let modified = attributes[.modificationDate] as? Date else { return nil }
        let key = cacheKey(path: target.path, size: size, modified: modified)
        if untouched.withLock({ $0.contains(key.name) }) { return nil }
        let cached = cacheDirectory.appendingPathComponent(key.name)
        if let copy = try? Data(contentsOf: cached, options: [.mappedIfSafe]) { return copy }
        guard let data = try? Data(contentsOf: target, options: [.mappedIfSafe]) else { return nil }
        let hasClientOrigin = data.range(of: Data(clientOrigin.utf8)) != nil
        let isSharedSteamUI = target.lastPathComponent == "sp.js"
        guard hasClientOrigin || isSharedSteamUI,
              let text = String(data: data, encoding: .utf8) else {
            untouched.withLock { _ = $0.insert(key.name) }
            return nil
        }
        let compatible = isSharedSteamUI ? repairShowcaseListenerCleanup(text) : text
        let copy = Data((hasClientOrigin ? rewritten(compatible) : compatible).utf8)
        store(copy, at: cached, replacing: key.family)
        return copy
    }

    /// The revisions of files that hold no client origin, by cache name.
    private static let untouched = Mutex<Set<String>>([])

    private static var cacheDirectory: URL {
        AppIdentity.cachesFolder
            .appendingPathComponent("LoopbackRewrite")
    }

    /// The cache entry for one revision of one file. `family` names the file
    /// by its full path, so two bundles' `main.js` never share an entry, and
    /// `name` adds everything the rewritten bytes depend on: the revision and
    /// the port the rewrite points at.
    static func cacheKey(path: String, size: Int, modified: Date) -> (family: String, name: String) {
        let url = URL(fileURLWithPath: path)
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let family = "\(url.deletingPathExtension().lastPathComponent)-\(digest)-"
        let stamp = Int(modified.timeIntervalSince1970)
        let compatibilityRevision = url.lastPathComponent == "sp.js" ? "-1" : ""
        return (family, "\(family)\(size)-\(stamp)-\(BridgePorts.steamUI)\(compatibilityRevision).\(url.pathExtension)")
    }

    /// Writes the rewritten copy and drops the ones a Steam update replaced,
    /// so the cache holds one entry per asset rather than one per revision.
    private static func store(_ copy: Data, at url: URL, replacing family: String) {
        let manager = FileManager.default
        try? manager.createDirectory(
            at: cacheDirectory, withIntermediateDirectories: true,
        )
        guard (try? copy.write(to: url, options: [.atomic])) != nil else { return }
        let siblings = (try? manager.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: nil,
        )) ?? []
        for sibling in siblings
            where sibling.lastPathComponent != url.lastPathComponent
            && sibling.lastPathComponent.hasPrefix(family) {
            try? manager.removeItem(at: sibling)
        }
    }
}
