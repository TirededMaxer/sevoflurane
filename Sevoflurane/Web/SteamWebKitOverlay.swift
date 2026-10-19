import AppKit
import CryptoKit
import WebKit

private final class NativeOverlaySourceWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosts Steam's existing overlay documents in WK; the game's original Steam
/// renderer still owns composition, visibility, focus, cursor and hotkeys.
@MainActor
final class SteamWebKitOverlay {
    private weak var host: SteamWebHost?
    private var task: Task<Void, Never>?
    private var root: CDPClient?
    private var rootSocket: String?
    private var mirrors: [String: Mirror] = [:]
    private var lastInfo = ""
    private var attached = false
    private var preparing = false
    private let directory = SteamBottle.root.appendingPathComponent("drive_c/sevo-webkit-overlay")
    private let inputScript = Bundle.main.url(forResource: "native_overlay_input", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    private final class Mirror {
        let client: CDPClient
        let popup: SteamWindow
        var renderer: SevoNativeWebRenderer?
        let cefID: UInt32
        let localBrowserID: UInt32
        let viewport: [Double]
        var receivedFrame = false
        init(client: CDPClient, popup: SteamWindow, cefID: UInt32, localBrowserID: UInt32, viewport: [Double]) {
            self.client = client; self.popup = popup; self.cefID = cefID; self.viewport = viewport
            self.localBrowserID = localBrowserID
        }
    }

    init(host: SteamWebHost) { self.host = host }

    func start() {
        guard task == nil else { return }
        // This directory contains only this adapter's transient frame files.
        // Clear leftovers from an interrupted previous app session.
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if file.pathExtension == "live" || file.pathExtension == "path" {
                try? FileManager.default.removeItem(at: file)
            }
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                if self == nil { return }
                await self?.refresh()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func refresh() async {
        guard let host, !host.clientIsStopping else { return }
        do {
            let targets = try await CDPClient.discoverTargets(port: 8765)
            guard let shared = targets.first(where: { $0["title"] as? String == "SharedJSContext" }),
                  let socket = shared["webSocketDebuggerUrl"] as? String, let url = URL(string: socket) else { return }
            if socket != rootSocket {
                await reset(); rootSocket = socket
                let client = CDPClient(onPush: { _ in })
                try await client.connect(socketURL: url, consumingBindings: false); root = client
            }
            guard let root else { return }
            let info = try await root.evaluate("""
            (async()=>JSON.stringify({browsers:await SteamClient.Overlay.GetOverlayBrowserInfo(),
              chats:await SteamClient.WebChat.GetOverlayChatBrowserInfo(),
              app:window.FocusedAppWindowStore?.GetFocusedOverlayAppID()||0,
              pid:window.FocusedAppWindowStore?.GetFocusedOverlayPID()||0}))()
            """) ?? "{}"
            if info != lastInfo {
                _ = await host.evaluateInContext("window.__sevoUpdateNativeOverlay?.(\(info));'mirrored'")
                lastInfo = info
            }
            let record = try JSONSerialization.jsonObject(with: Data(info.utf8)) as? [String: Any]
            let browsers = record?["browsers"] as? [[String: Any]] ?? []
            let gamePIDs = Set(browsers.compactMap { ($0["unPID"] as? NSNumber)?.intValue })
            let gameTargets = targets.filter { target in
                guard let text = target["url"] as? String,
                      let query = URLComponents(string: text)?.queryItems,
                      let pid = query.first(where: { $0.name == "pid" })?.value.flatMap(Int.init) else { return false }
                return pid > 0
            }
            let live = Set(gameTargets.compactMap { $0["id"] as? String })
            for id in mirrors.keys where !live.contains(id) {
                if let old = mirrors.removeValue(forKey: id) {
                    old.renderer?.stop(); NativeOverlayInput.reset(old.popup.webView)
                    old.popup.close(); await old.client.disconnect()
                }
            }
            for target in gameTargets {
                guard let id = target["id"] as? String else { continue }
                if let mirror = mirrors[id] {
                    let size = try await mirror.client.evaluate("JSON.stringify([innerWidth,innerHeight,devicePixelRatio])") ?? "[]"
                    let dimensions = (try? JSONSerialization.jsonObject(with: Data(size.utf8)) as? [NSNumber])?.map { $0.doubleValue }
                    if dimensions != mirror.viewport {
                        mirror.renderer?.stop(); NativeOverlayInput.reset(mirror.popup.webView); await mirror.client.disconnect(); mirrors.removeValue(forKey: id)
                        try await adopt(target, id: id)
                        continue
                    }
                    if mirror.renderer == nil,
                       try await mirror.popup.webView.evaluateJavaScript(Self.contentReadyScript) as? Bool == true {
                        try startRendering(mirror)
                    }
                    guard let renderer = mirror.renderer else { continue }
                    if attached, renderer.frames > 0 {
                        if !mirror.receivedFrame, renderer.consumedFrames > 0 {
                            mirror.receivedFrame = true
                            EventLog.shared.log(.window, "Steam consumed WebKit overlay frames: \(mirror.popup.name)")
                        }
                        // Installation is idempotent. Recreate the local bridge
                        // if its watchdog cleaned it up during a stalled refresh.
                        let enabled = renderer.consumedFrames > 0 ? "true" : "false"
                        _ = try await mirror.client.evaluate(inputScript + ";if(window.__sevoOverlayInput){__sevoOverlayInput.enabled=\(enabled)};'ready'")
                    }
                } else { try await adopt(target, id: id) }
            }
            try await synchronizePopupWindows(gamePIDs: gamePIDs, root: root)
            if mirrors.values.contains(where: { $0.renderer != nil }), !attached, !preparing { try await attach() }
        } catch {
            // Loss of the renderer stops its heartbeat; the original Steam
            // document and pixels resume automatically on the Windows side.
            if root != nil { await reset() }
        }
    }

    private func adopt(_ target: [String: Any], id: String) async throws {
        guard let host, let socket = target["webSocketDebuggerUrl"] as? String, let url = URL(string: socket) else { return }
        let scoped = CDPClient(onPush: { [weak self] raw in await self?.receive(raw, id: id) })
        try await scoped.connectInputMirror(socketURL: url)
        let raw = try await scoped.evaluate("JSON.stringify({name:window.name,id:SteamClient.Browser.GetBrowserID(),w:innerWidth,h:innerHeight,scale:devicePixelRatio})") ?? "{}"
        guard let values = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let name = values["name"] as? String,
              let popup = host.popups.values.first(where: { $0.name == name && $0.usesOriginalGameOverlay }),
              let cefID = values["id"] as? UInt32,
              let width = values["w"] as? Int, let height = values["h"] as? Int,
              width > 0, height > 0 else { await scoped.disconnect(); return }
        let scale = (values["scale"] as? NSNumber)?.doubleValue ?? 1
        guard scale.isFinite, scale > 0, Double(width)*scale <= 8192, Double(height)*scale <= 8192 else {
            await scoped.disconnect(); return
        }
        let view = popup.webView
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.wantsLayer = true
        SteamWebHost.setOcclusionDetection(false, on: view)
        prepareSource(for: popup)
        popup.window?.setContentSize(view.frame.size)
        let localID = (try await view.evaluateJavaScript("window.__sevoBrowserID || 0") as? NSNumber)?.uint32Value ?? 0
        // Window queries are part of Steam's page initialization. Publish
        // this binding before waiting for that page to render any content.
        mirrors[id] = Mirror(client: scoped, popup: popup, cefID: cefID, localBrowserID: localID,
                             viewport: [Double(width), Double(height), scale])
        EventLog.shared.log(.window, "Steam overlay window bound: \(name), \(width)×\(height)")
    }

    /// Steam's page opens secondary windows locally after a WebKit click.
    /// Give each one its original CEF window surface, using the exact native
    /// creation query and features supplied by Steam's own popup manager.
    private func synchronizePopupWindows(gamePIDs: Set<Int>, root: CDPClient) async throws {
        guard let host else { return }
        var windows: [[String: Any]] = []
        for popup in Array(host.popups.values) where popup.usesOriginalGameOverlay {
            let pid = SteamWindowRole.instanceUID(ofPopupNamed: popup.name)
            guard pid > 0 else { continue }
            guard gamePIDs.contains(pid) else { popup.close(); continue }
            guard popup.role != .gameOverlay, popup.role != .toast,
                  !popup.originalPopupQuery.isEmpty else { continue }
            windows.append(["name": popup.name, "query": popup.originalPopupQuery,
                            "features": popup.originalPopupFeatures,
                            "bound": mirrors.values.contains(where: { $0.popup === popup })])
        }
        var ids: [String: UInt32] = [:]
        for mirror in mirrors.values where mirror.localBrowserID > 0 {
            ids[String(mirror.localBrowserID)] = mirror.cefID
        }
        let data = try JSONSerialization.data(withJSONObject: ["windows": windows, "ids": ids])
        let json = String(decoding: data, as: UTF8.self)
        _ = try await root.evaluate("(\(Self.popupWindowsScript))(\(json))")
    }

    static let popupWindowsScript = """
    function (request) {
      var peers = window.__sevoOverlayWindows || (window.__sevoOverlayWindows = new Map());
      var live = new Set(request.windows.map(function (item) { return item.name; }));
      peers.forEach(function (peer, name) {
        if (!live.has(name)) {
          if (peer.owned && !peer.win.closed) peer.win.close();
          peers.delete(name);
        }
      });
      request.windows.forEach(function (item) {
        var peer = peers.get(item.name);
        if (peer && !peer.win.closed) return;
        if (item.bound) return;
        var existing = window.g_PopupManager && g_PopupManager.GetExistingPopup(item.name);
        if (existing && existing.m_popup && !existing.m_popup.closed) {
          peers.set(item.name, {win:existing.m_popup,owned:false}); return;
        }
        var query = new URLSearchParams(item.query), waiting = false;
        ['openerid','parentcontainerpopupid','centerOnBrowserID'].forEach(function (key) {
          var id = query.get(key);
          if (id && Number(id)>0) {
            if (request.ids[id] === undefined) waiting = true;
            else query.set(key,String(request.ids[id]));
          }
        });
        if (waiting) return;
        var win = window.open('about:blank?'+query.toString(),item.name,item.features);
        if (!win) throw new Error('Steam overlay popup could not be created: '+item.name);
        win.document.documentElement.style.background = 'transparent';
        win.document.body.style.cssText = 'margin:0;background:transparent';
        peers.set(item.name,{win:win,owned:true});
      });
      return 'ready';
    }
    """

    /// A blank host cannot replace visible Steam pixels or take its input.
    /// Check generic rendered content, without branching on Steam's UI state.
    static let contentReadyScript = """
    (function () {
      if (!document.body) return false;
      return Array.from(document.body.querySelectorAll('button,a,input,textarea,img,svg,canvas,div,p,span')).some(function (node) {
        if (/^(DIV|P|SPAN)$/.test(node.tagName) && (node.children.length || !node.textContent.trim())) return false;
        var rect=node.getBoundingClientRect(), style=getComputedStyle(node);
        return rect.width>0 && rect.height>0 && style.display!=='none' && style.visibility!=='hidden';
      });
    })()
    """

    private func startRendering(_ mirror: Mirror) throws {
        let width = UInt32((mirror.viewport[0]*mirror.viewport[2]).rounded())
        let height = UInt32((mirror.viewport[1]*mirror.viewport[2]).rounded())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let frame = directory.appendingPathComponent("\(UUID().uuidString)-\(mirror.cefID)-\(width)x\(height).live")
        guard let renderer = SevoNativeWebRenderer(webView: mirror.popup.webView, width: width, height: height,
                                                 framePath: frame.path, cefID: mirror.cefID) else {
            try? FileManager.default.removeItem(at: frame)
            throw CocoaError(.executableLoad)
        }
        mirror.renderer = renderer
        try Data(SteamBottle.windowsPath(for: frame).utf8)
            .write(to: directory.appendingPathComponent("stream-\(mirror.cefID)-\(width)x\(height).path"), options: .atomic)
        EventLog.shared.log(.window, "WebKit overlay content ready: \(mirror.popup.name)")
    }

    /// Make the invisible backing available before Steam creates embedded
    /// BrowserViews. Its normal popup-created event may run before discovery.
    func prepareSource(for popup: SteamWindow) {
        guard popup.window == nil else { return }
        let view = popup.webView
        if view.frame.width < 1 || view.frame.height < 1 {
            view.frame = NSRect(origin: .zero, size: popup.requestedSize)
        }
        let window = NativeOverlaySourceWindow(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.alphaValue = 0; window.isOpaque = false; window.backgroundColor = .clear
        window.ignoresMouseEvents = true; window.hidesOnDeactivate = false
        window.collectionBehavior = [.stationary, .ignoresCycle]
        SteamWebHost.setOcclusionDetection(false, on: view)
        window.contentView = view; window.orderBack(nil); popup.window = window
    }

    private func attach() async throws {
        preparing = true; defer { preparing = false }
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("NativeOverlay") else { return }
        let manifest = try Data(contentsOf: resources.appendingPathComponent("manifest.json"))
        let record = try JSONSerialization.jsonObject(with: manifest) as? [String: Any]
        let cef = SteamBottle.steamRoot.appendingPathComponent("bin/cef/cef.win64")
        for (name, key) in [("steamwebhelper.exe", "helper_sha256"), ("libcef.dll", "cef_sha256")] {
            let digest = SHA256.hash(data: try Data(contentsOf: cef.appendingPathComponent(name), options: .alwaysMapped))
                .map { String(format: "%02x", $0) }.joined()
            guard digest == record?[key] as? String else { throw CocoaError(.fileReadCorruptFile) }
        }
        for name in ["sevo-overlay-webkit.dll", "sevo-overlay-attach.exe"] {
            let destination = directory.appendingPathComponent(name)
            let bytes = try Data(contentsOf: resources.appendingPathComponent(name))
            if (try? Data(contentsOf: destination)) != bytes { try bytes.write(to: destination, options: .atomic) }
        }
        try Data((SteamBottle.windowsPath(for: directory)+"\n").utf8)
            .write(to: directory.appendingPathComponent("overlay.cfg"), options: .atomic)
        let result = directory.appendingPathComponent("attach-result.json")
        try? FileManager.default.removeItem(at: result)
        let invocation = Engine.active.wineInvocation(bottle: SteamBottle.name, wait: .none, program: [
            directory.appendingPathComponent("sevo-overlay-attach.exe").path,
            SteamBottle.windowsPath(for: cef.appendingPathComponent("steamwebhelper.exe")),
            SteamBottle.windowsPath(for: directory.appendingPathComponent("sevo-overlay-webkit.dll")),
            SteamBottle.windowsPath(for: result),
        ])
        _ = await Subprocess.run(invocation.executable.path, invocation.arguments, environment: invocation.environment, capture: .none, timeout: .seconds(10))
        for _ in 0..<40 {
            if let data = try? Data(contentsOf: result),
               let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let matched = report["matched"] as? Int, matched > 0,
               report["loaded"] as? Int == matched, report["error"] as? Int == 0 {
                let processes = report["results"] as? [[String: Any]] ?? []
                if processes.contains(where: { process in
                    guard let pid = process["pid"] as? Int else { return false }
                    return (try? String(contentsOf: directory.appendingPathComponent("ready-\(pid).status"), encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines)) == "0"
                }) {
                    attached = true; return
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CocoaError(.executableLoad)
    }

    func windowCall(_ function: String, args: [Any], popup: SteamWindow) async throws -> Any? {
        guard function.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }),
              let data = try? JSONSerialization.data(withJSONObject: args),
              let json = String(data: data, encoding: .utf8) else { throw CocoaError(.coderInvalidValue) }
        // Keep early initialization calls pending until the corresponding
        // original CEF window has been discovered; nil is not its answer.
        for _ in 0..<50 {
            try Task.checkCancellation()
            if let mirror = mirrors.values.first(where: { $0.popup === popup }) {
                let value = try await mirror.client.evaluate("(async()=>JSON.stringify(await SteamClient.Window.\(function)(...\(json))))()")
                return value.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed) }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CDPClient.Failure.unreachable("Steam overlay window binding is not ready")
    }

    private func receive(_ raw: String, id: String) {
        guard let event = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              event["type"] as? String == "overlay-input", let popup = mirrors[id]?.popup else { return }
        NativeOverlayInput.deliver(event, to: popup)
    }

    private func reset() async {
        _ = try? await root?.evaluate("(\(Self.popupWindowsScript))({windows:[],ids:{}})")
        for mirror in mirrors.values {
            mirror.renderer?.stop(); NativeOverlayInput.reset(mirror.popup.webView)
            _ = try? await mirror.client.evaluate("window.__sevoOverlayInput?.stop();'stopped'")
            await mirror.client.disconnect()
        }
        mirrors.removeAll(); await root?.disconnect(); root = nil; rootSocket = nil; lastInfo = ""; attached = false
    }

    func invalidate() {
        Task { await reset() }
    }
}
