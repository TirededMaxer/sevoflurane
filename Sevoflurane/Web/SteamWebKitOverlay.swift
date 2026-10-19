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
        let renderer: SevoNativeWebRenderer
        var inputInstalled = false
        init(client: CDPClient, popup: SteamWindow, renderer: SevoNativeWebRenderer) {
            self.client = client; self.popup = popup; self.renderer = renderer
        }
    }

    init(host: SteamWebHost) { self.host = host }

    func start() {
        guard task == nil else { return }
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
            let gameTargets = targets.filter { target in
                guard let text = target["url"] as? String,
                      let query = URLComponents(string: text)?.queryItems,
                      let pid = query.first(where: { $0.name == "pid" })?.value.flatMap(Int.init) else { return false }
                return pid > 0
            }
            let live = Set(gameTargets.compactMap { $0["id"] as? String })
            for id in mirrors.keys where !live.contains(id) {
                if let old = mirrors.removeValue(forKey: id) { old.renderer.stop(); await old.client.disconnect() }
            }
            for target in gameTargets {
                guard let id = target["id"] as? String else { continue }
                if let mirror = mirrors[id] {
                    if attached, mirror.renderer.frames > 0 {
                        if !mirror.inputInstalled {
                            _ = try await mirror.client.evaluate(inputScript)
                            mirror.inputInstalled = true
                        } else {
                            let enabled = mirror.renderer.consumedFrames > 0 ? "true" : "false"
                            _ = try await mirror.client.evaluate("if(window.__sevoOverlayInput){__sevoOverlayInput.ping=Date.now();__sevoOverlayInput.enabled=\(enabled)};'ping'")
                        }
                    }
                } else { try await adopt(target, id: id) }
            }
            if !mirrors.isEmpty, !attached, !preparing { try await attach() }
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
              width >= 64, height >= 64 else { await scoped.disconnect(); return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let frame = directory.appendingPathComponent("\(UUID().uuidString)-\(cefID)-\(width)x\(height).live")
        let view = popup.webView
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.wantsLayer = true
        SteamWebHost.setOcclusionDetection(false, on: view)
        if popup.window == nil {
            let window = NativeOverlaySourceWindow(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.alphaValue = 0; window.isOpaque = false; window.backgroundColor = .clear
            window.ignoresMouseEvents = true; window.hidesOnDeactivate = false
            window.collectionBehavior = [.stationary, .ignoresCycle]
            window.contentView = view; window.orderBack(nil); popup.window = window
        }
        guard let renderer = SevoNativeWebRenderer(webView: view, width: UInt32(width), height: UInt32(height), framePath: frame.path, cefID: cefID)
        else { try? FileManager.default.removeItem(at: frame); await scoped.disconnect(); return }
        let path = SteamBottle.windowsPath(for: frame)
        try Data(path.utf8).write(to: directory.appendingPathComponent("stream-\(cefID)-\(width)x\(height).path"), options: .atomic)
        mirrors[id] = Mirror(client: scoped, popup: popup, renderer: renderer)
        EventLog.shared.log(.window, "WebKit overlay connected: \(name), \(width)×\(height)")
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

    func windowCall(_ function: String, args: [Any], popup: SteamWindow) async -> Any? {
        guard let mirror = mirrors.values.first(where: { $0.popup === popup }),
              function.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }),
              let data = try? JSONSerialization.data(withJSONObject: args), let json = String(data: data, encoding: .utf8) else { return nil }
        let value = try? await mirror.client.evaluate("(async()=>JSON.stringify(await SteamClient.Window.\(function)(...\(json))))()")
        return value.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed) }
    }

    private func receive(_ raw: String, id: String) {
        guard let event = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              event["type"] as? String == "overlay-input", let popup = mirrors[id]?.popup else { return }
        NativeOverlayInput.deliver(event, to: popup)
    }

    private func reset() async {
        for mirror in mirrors.values {
            mirror.renderer.stop()
            _ = try? await mirror.client.evaluate("window.__sevoOverlayInput?.stop();'stopped'")
            await mirror.client.disconnect()
        }
        mirrors.removeAll(); await root?.disconnect(); root = nil; rootSocket = nil; lastInfo = ""; attached = false
    }

    func invalidate() {
        Task { await reset() }
    }
}
