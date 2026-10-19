import AppKit
import CryptoKit
import WebKit

private final class NativeOverlaySourceWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Window-system adapter for Steam's unmodified WebKit pages. Each original
/// window.open request gets one native Steam surface; no second popup manager
/// or copy of Steam's overlay state is maintained here.
@MainActor
final class SteamWebKitOverlay {
    private weak var host: SteamWebHost?
    private var task: Task<Void, Never>?
    private var rootTask: Task<CDPClient, any Error>?
    private var creating: [ObjectIdentifier: Task<Void, any Error>] = [:]
    private var mirrors: [String: Mirror] = [:]
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
        var viewport: [Double]
        var receivedFrame = false
        init(client: CDPClient, popup: SteamWindow, cefID: UInt32, localBrowserID: UInt32, viewport: [Double]) {
            self.client = client; self.popup = popup; self.cefID = cefID; self.viewport = viewport
            self.localBrowserID = localBrowserID
        }
    }

    init(host: SteamWebHost) { self.host = host }

    private func start() {
        guard task == nil else { return }
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if file.pathExtension == "live" || file.pathExtension == "path" {
                try? FileManager.default.removeItem(at: file)
            }
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await refresh()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func nativeContext() async throws -> CDPClient {
        if let rootTask { return try await rootTask.value }
        let connection = Task {
            let targets = try await CDPClient.discoverTargets(port: 8765)
            guard let target = targets.first(where: { $0["title"] as? String == "SharedJSContext" }),
                  let socket = target["webSocketDebuggerUrl"] as? String, let url = URL(string: socket) else {
                throw CDPClient.Failure.unreachable("Steam context is not ready")
            }
            let client = CDPClient(onPush: { _ in })
            try await client.connect(socketURL: url, consumingBindings: false)
            return client
        }
        rootTask = connection
        do { return try await connection.value }
        catch { rootTask = nil; throw error }
    }

    /// Called by the same WebKit window.open adoption used by desktop pages.
    /// Rendering starts only after the native window acknowledges this request.
    func adopt(_ popup: SteamWindow, parameters: String, features: String) async throws {
        guard popup.usesOriginalGameOverlay else { return }
        let key = ObjectIdentifier(popup.webView)
        if let pending = creating[key] { return try await pending.value }
        if mirrors.values.contains(where: { $0.popup === popup }) { return }
        let pending = Task { try await self.createSurface(for: popup, parameters: parameters, features: features) }
        creating[key] = pending
        defer { creating.removeValue(forKey: key) }
        try await pending.value
        start()
    }

    private func createSurface(for popup: SteamWindow, parameters: String, features: String) async throws {
        let root = try await nativeContext()
        var ids: [String: UInt32] = [:]
        if let id = try await root.evaluate("SteamClient.Browser.GetBrowserID()").flatMap(UInt32.init) { ids["1"] = id }
        for mirror in mirrors.values { ids[String(mirror.localBrowserID)] = mirror.cefID }
        let request: [String: Any] = ["name": popup.name, "query": parameters, "features": features, "ids": ids]
        let data = try JSONSerialization.data(withJSONObject: request)
        let json = String(decoding: data, as: UTF8.self)
        guard try await root.evaluate("(\(Self.createWindowScript))(\(json))") == popup.name else {
            throw CDPClient.Failure.badReply("Steam did not create the requested window")
        }
        // Target discovery supplies the rendering endpoint, not window policy.
        for _ in 0..<40 {
            try Task.checkCancellation()
            let targets = try await CDPClient.discoverTargets(port: 8765)
            for target in targets {
                guard let id = target["id"] as? String,
                      let text = target["url"] as? String,
                      text.hasPrefix("about:blank"),
                      let socket = target["webSocketDebuggerUrl"] as? String, let url = URL(string: socket) else { continue }
                let scoped = CDPClient(onPush: { [weak self] raw in await self?.receive(raw, id: id) })
                try await scoped.connectInputMirror(socketURL: url)
                let nameJSON = String(decoding: try JSONSerialization.data(withJSONObject: popup.name, options: .fragmentsAllowed), as: UTF8.self)
                let raw: String?
                do {
                    raw = try await scoped.evaluate("(\(Self.surfaceDetailsScript))(\(nameJSON),[\(popup.requestedSize.width),\(popup.requestedSize.height)])")
                } catch {
                    await scoped.disconnect()
                    throw error
                }
                guard let raw, let details = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                      let cefID = (details["id"] as? NSNumber)?.uint32Value,
                      let numbers = details["size"] as? [NSNumber] else {
                    await scoped.disconnect()
                    continue
                }
                let localID = (try await popup.webView.evaluateJavaScript("window.__sevoBrowserID || 0") as? NSNumber)?.uint32Value ?? 0
                let size = try Self.validatedDimensions(numbers)
                let mirror = Mirror(client: scoped, popup: popup, cefID: cefID, localBrowserID: localID, viewport: size)
                mirrors[id] = mirror
                resizeSource(mirror)
                EventLog.shared.log(.window, "Steam window request bound to WebKit: \(popup.name), CEF \(cefID)")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CDPClient.Failure.unreachable("Steam window rendering endpoint is not ready")
    }

    /// Native window creation only. The supplied name, flags, size and parent
    /// come from Steam's own request; its popup manager and stores are untouched.
    static let createWindowScript = """
    function (request) {
      var query = new URLSearchParams(request.query);
      ['openerid','parentcontainerpopupid','centerOnBrowserID'].forEach(function (key) {
        var id = query.get(key);
        if (id && Number(id)>0) {
          if (request.ids[id] === undefined) throw new Error('Native parent window is not ready: '+id);
          query.set(key,String(request.ids[id]));
        }
      });
      var existing = window.g_PopupManager && g_PopupManager.GetExistingPopup(request.name);
      var win = existing && existing.m_popup && !existing.m_popup.closed ? existing.m_popup
        : window.open('about:blank?'+query.toString(),request.name,request.features);
      if (!win) throw new Error('Steam refused window.open: '+request.name);
      return request.name;
    }
    """

    /// CEF can expose the popup before its native bindings or viewport exist.
    /// Match its identity first; popup-created waits for this readiness check.
    static let surfaceDetailsScript = """
    function (name, requestedSize) {
      if (window.name !== name || !window.SteamClient || !SteamClient.Browser ||
          typeof SteamClient.Browser.GetBrowserID !== 'function' || innerWidth <= 0 || innerHeight <= 0)
        return null;
      // Off-screen CEF starts at 1x1 even when window.open supplied a size.
      // Apply the original Steam request before accepting this display surface.
      if (innerWidth < 64 || innerHeight < 64) {
        SteamClient.Window.ResizeTo(requestedSize[0],requestedSize[1],true);
        return null;
      }
      return JSON.stringify({id:SteamClient.Browser.GetBrowserID(),size:[innerWidth,innerHeight,devicePixelRatio]});
    }
    """

    private func dimensions(_ client: CDPClient) async throws -> [Double] {
        let raw = try await client.evaluate("JSON.stringify([innerWidth,innerHeight,devicePixelRatio])") ?? "[]"
        guard let values = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [NSNumber] else {
            throw CDPClient.Failure.badReply("Steam window dimensions are unavailable")
        }
        return try Self.validatedDimensions(values)
    }

    private static func validatedDimensions(_ values: [NSNumber]) throws -> [Double] {
        guard values.count == 3 else {
            throw CDPClient.Failure.badReply("Steam window dimensions are unavailable")
        }
        let size = values.map { $0.doubleValue }
        guard size.allSatisfy({ $0.isFinite && $0 > 0 }), size[0] >= 64, size[1] >= 64, size[0]*size[2] <= 8192, size[1]*size[2] <= 8192 else {
            throw CDPClient.Failure.badReply("Steam window dimensions are invalid")
        }
        return size
    }

    private func resizeSource(_ mirror: Mirror) {
        let view = mirror.popup.webView
        view.frame = NSRect(x: 0, y: 0, width: mirror.viewport[0], height: mirror.viewport[1])
        view.wantsLayer = true
        prepareSource(for: mirror.popup)
        mirror.popup.window?.setContentSize(view.frame.size)
    }

    private func refresh() async {
        guard let host, !host.clientIsStopping, !mirrors.isEmpty else { return }
        do {
            let targets = try await CDPClient.discoverTargets(port: 8765)
            let live = Set(targets.compactMap { $0["id"] as? String })
            for id in Array(mirrors.keys) where !live.contains(id) {
                if let old = mirrors.removeValue(forKey: id) {
                    old.renderer?.stop(); NativeOverlayInput.reset(old.popup.webView)
                    old.popup.close(); await old.client.disconnect()
                }
            }
            for mirror in Array(mirrors.values) {
                let size = try await dimensions(mirror.client)
                if size != mirror.viewport {
                    mirror.renderer?.stop(); mirror.renderer = nil; mirror.viewport = size
                    mirror.receivedFrame = false; resizeSource(mirror)
                }
                if mirror.renderer == nil,
                   try await mirror.popup.webView.evaluateJavaScript(Self.contentReadyScript) as? Bool == true {
                    try startRendering(mirror)
                }
                guard let renderer = mirror.renderer, attached, renderer.frames > 0 else { continue }
                if !mirror.receivedFrame, renderer.consumedFrames > 0 {
                    mirror.receivedFrame = true
                    EventLog.shared.log(.window, "Steam consumed WebKit overlay frames: \(mirror.popup.name)")
                }
                let enabled = renderer.consumedFrames > 0 ? "true" : "false"
                _ = try await mirror.client.evaluate(inputScript + ";if(window.__sevoOverlayInput){__sevoOverlayInput.enabled=\(enabled)};'ready'")
            }
            if mirrors.values.contains(where: { $0.renderer != nil }), !attached, !preparing { try await attach() }
        } catch {
            EventLog.shared.log(.window, "WebKit window adapter disconnected: \(error)")
            await reset()
        }
    }

    /// Closing a WebKit browsing context releases its native display surface,
    /// just as the desktop adapter releases its NSWindow.
    func release(_ popup: SteamWindow) {
        guard let entry = mirrors.first(where: { $0.value.popup === popup }) else { return }
        let mirror = entry.value
        mirrors.removeValue(forKey: entry.key)
        mirror.renderer?.stop(); NativeOverlayInput.reset(popup.webView)
        Task {
            _ = try? await mirror.client.evaluate("SteamClient.Window.Close();'closed'")
            await mirror.client.disconnect()
        }
    }

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
        if let pending = creating[ObjectIdentifier(popup.webView)] { try await pending.value }
        guard let mirror = mirrors.values.first(where: { $0.popup === popup }) else {
            throw CDPClient.Failure.unreachable("Steam window is not bound")
        }
        let value = try await mirror.client.evaluate("(async()=>JSON.stringify(await SteamClient.Window.\(function)(...\(json))))()")
        return value.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed) }
    }

    private func receive(_ raw: String, id: String) {
        guard let event = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              event["type"] as? String == "overlay-input", let popup = mirrors[id]?.popup else { return }
        NativeOverlayInput.deliver(event, to: popup)
    }

    private func reset() async {
        let old = Array(mirrors.values)
        mirrors.removeAll()
        for mirror in old {
            mirror.renderer?.stop(); NativeOverlayInput.reset(mirror.popup.webView)
            _ = try? await mirror.client.evaluate("window.__sevoOverlayInput?.stop();'stopped'")
            await mirror.client.disconnect()
        }
        if let rootTask { if let client = try? await rootTask.value { await client.disconnect() } }
        rootTask = nil; attached = false
    }

    func invalidate() {
        task?.cancel(); task = nil
        for pending in creating.values { pending.cancel() }
        Task { await reset() }
    }
}
