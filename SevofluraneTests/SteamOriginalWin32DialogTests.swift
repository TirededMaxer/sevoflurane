import AppKit
import Testing
import WebKit
@testable import Sevoflurane

@Suite(.serialized)
@MainActor
struct SteamOriginalWin32DialogTests {
    @Test
    func originalGeometryUnicodeFontsAndDisabledStateAreRenderedByWebKit() async throws {
        let dialog = fixture()
        let host = try #require(NativeSteamDialogWindow(dialog: dialog, send: { _ in }))
        defer { host.originalDidClose() }
        host.window.orderFront(nil)
        try await settle(host)
        let text = try await host.webView.evaluateJavaScript("document.getElementById('title').textContent") as? String
        #expect(text == dialog.title)
        let dimensions = try await host.webView.evaluateJavaScript("(()=>{const e=document.querySelector('[data-handle=\"101\"]'),s=getComputedStyle(e);return [s.left,s.top,s.width,s.height,s.fontSize,s.fontWeight,e.textContent]})()") as? [String]
        #expect(dimensions == ["16px", "14px", "300px", "40px", "15px", "400", "连接失败：原始内容 <script> & Unicode"])
        #expect(try await host.webView.evaluateJavaScript("document.querySelector('[data-handle=\"104\"]').disabled") as? Bool == true)
        #expect(host.window.contentView === host.webView)
        #expect(host.webView.acceptsFirstMouse(for: nil))
        #expect(host.window.canBecomeKey)
        #expect(host.window.styleMask.isEmpty)
        var literal = dialog
        literal.controls?[0].style = 0x80 // SS_NOPREFIX preserves literal ampersands.
        literal.controls?[0].text = "A&B"
        host.update(literal)
        try await wait { (try? await host.webView.evaluateJavaScript("document.querySelector('[data-handle=\"101\"]').textContent")) as? String == "A&B" }
        _ = try await host.webView.evaluateJavaScript("document.querySelector('[data-handle=\"102\"]').focus();document.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true}))")
        #expect(try await host.webView.evaluateJavaScript("document.activeElement.dataset.handle") as? String == "103")
        _ = try await host.webView.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',shiftKey:true,bubbles:true}))")
        #expect(try await host.webView.evaluateJavaScript("document.activeElement.dataset.handle") as? String == "102")
    }

    @Test
    func defaultCancelAndClickPreserveOriginalHWNDAndDoNotCloseAdapter() async throws {
        var requests: [[String]] = []
        let host = try #require(NativeSteamDialogWindow(dialog: fixture(), send: { requests.append($0) }))
        defer { host.originalDidClose() }
        host.window.orderFront(nil)
        try await settle(host)
        _ = try await host.webView.evaluateJavaScript("document.activeElement.blur();document.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}));document.querySelector('[data-handle=\"102\"]').click();document.querySelector('[data-handle=\"104\"]').click()")
        try await wait { requests.filter { $0.last == "click" }.count == 3 }
        #expect(requests.filter { $0.last == "click" } == [
            ["control", "500", "60", "103", "click"],
            ["control", "500", "60", "103", "click"],
            ["control", "500", "60", "102", "click"],
        ])
        #expect(host.window.isVisible)
        #expect(!host.windowShouldClose(host.window))
        #expect(requests.last == ["answer", "500", "60", "0"])
        #expect(host.window.isVisible)
        host.originalDidClose()
        #expect(!host.window.isVisible)
    }

    @Test
    func inputAndToggleStateRemainOwnedByOriginalAndLiveIMEIsNotReplaced() async throws {
        var requests: [[String]] = []
        var snapshot = fixture()
        snapshot.controls?.append(control(105, id: 21, kind: "Button", text: "保留原始选项", style: 3, tabStop: true))
        snapshot.controls?.append(control(106, id: 22, kind: "Edit", text: "old", style: 0, tabStop: true))
        snapshot.controls?.append(control(107, id: 23, kind: "Edit", text: "", style: 0x20, password: true, tabStop: true))
        let host = try #require(NativeSteamDialogWindow(dialog: snapshot, send: { requests.append($0) }))
        defer { host.originalDidClose() }
        host.window.orderFront(nil)
        try await settle(host)
        _ = try await host.webView.evaluateJavaScript("(()=>{document.querySelector('[data-handle=\"105\"] input').click();const e=document.querySelector('[data-handle=\"106\"]');e.focus();e.value='中文 abc';e.dispatchEvent(new InputEvent('input',{bubbles:true,isComposing:true}));e.dispatchEvent(new CompositionEvent('compositionend',{bubbles:true}))})()")
        try await wait { requests.contains(["control", "500", "60", "106", "text", "中文 abc"]) }
        #expect(requests.contains(["control", "500", "60", "106", "focus"]))
        #expect(requests.contains(["control", "500", "60", "105", "click"]))
        #expect(try await host.webView.evaluateJavaScript("document.querySelector('[data-handle=\"105\"] input').checked") as? Bool == false)
        snapshot.controls?[4].checkState = 1
        host.update(snapshot)
        try await wait { (try? await host.webView.evaluateJavaScript("document.querySelector('[data-handle=\"105\"] input').checked")) as? Bool == true }
        #expect(try await host.webView.evaluateJavaScript("document.querySelector('[data-handle=\"106\"]').value") as? String == "中文 abc")
        #expect(try await host.webView.evaluateJavaScript("document.querySelector('[data-handle=\"107\"]').type") as? String == "password")
        let order = try await host.webView.evaluateJavaScript("Array.from(document.querySelectorAll('#client [tabindex=\"0\"]')).map(e=>e.dataset.handle||e.parentElement.dataset.handle)") as? [String]
        #expect(order == ["102", "103", "105", "106", "107"])
    }

    @Test
    func unsupportedCustomControlsAndInvalidGeometryAreExplicitlyRejected() {
        var snapshot = fixture()
        #expect(snapshot.canPresent)
        snapshot.controls?.append(control(120, id: 30, kind: "VGuiSurface", text: ""))
        #expect(!snapshot.canPresent)
        #expect(snapshot.unsupportedControlKinds == ["VGuiSurface:0"])
        #expect(NativeSteamDialogWindow(dialog: snapshot, send: { _ in }) == nil)
        snapshot = fixture()
        snapshot.controls?[0].width = .infinity
        #expect(!snapshot.canPresent)
        snapshot = fixture()
        snapshot.frameTop = -1
        #expect(!snapshot.canPresent)
    }

    @Test
    func fontSchemeRejectsTraversalAndSymlinksOutsideBottleFonts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fonts = directory.appendingPathComponent("Fonts")
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        let accepted = fonts.appendingPathComponent("font.ttf")
        let outside = directory.appendingPathComponent("outside.ttf")
        try Data([0, 1, 2, 3]).write(to: accepted)
        try Data([0, 1, 2, 3]).write(to: outside)
        #expect(OriginalDialogFonts.admittedFont(accepted, root: fonts) == accepted.resolvingSymlinksInPath())
        #expect(OriginalDialogFonts.admittedFont(outside, root: fonts) == nil)
        let link = fonts.appendingPathComponent("link.ttf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(OriginalDialogFonts.admittedFont(link, root: fonts) == nil)
    }

    private func fixture() -> SteamNativeDialog {
        SteamNativeDialog(
            handle: 500, pid: 60, title: "Steam 原始错误", canClose: true,
            clientWidth: 400, clientHeight: 150,
            controls: [
                control(101, id: 0, kind: "Static", text: "连接失败：原始内容 <script> && Unicode"),
                control(102, id: 1, kind: "Button", text: "确定", tabStop: true),
                control(103, id: 2, kind: "Button", text: "取消", style: 1, isDefault: true, tabStop: true),
                control(104, id: 4, kind: "Button", text: "重试", enabled: false, tabStop: true),
            ], windowClass: "#32770", owner: 400, ownerEnabled: false,
            font: SteamNativeDialog.Font(family: "Arial", pixelHeight: 15, weight: 400, italic: false, underline: false),
            frameLeft: 4, frameTop: 24, frameRight: 4, frameBottom: 4,
            face: [236, 233, 216], buttonText: [0, 0, 0], window: [255, 255, 255], windowText: [0, 0, 0],
            highlight: [0, 120, 215], highlightText: [255, 255, 255], shadow: [128, 128, 128], light: [255, 255, 255],
            grayText: [128, 128, 128], caption: [0, 84, 227], captionText: [255, 255, 255]
        )
    }

    private func control(_ handle: UInt64, id: UInt32, kind: String, text: String, style: UInt32 = 0,
                         enabled: Bool = true, isDefault: Bool = false, password: Bool = false,
                         tabStop: Bool = false) -> SteamNativeDialog.Control {
        SteamNativeDialog.Control(handle: handle, id: id, className: kind, text: text, style: style,
            x: 16, y: 14, width: 300, height: 40, enabled: enabled, tabStop: tabStop,
            password: password, isDefault: isDefault, checkState: 0,
            font: SteamNativeDialog.Font(family: "Arial", pixelHeight: 15, weight: 400, italic: false, underline: false))
    }

    private func settle(_ host: NativeSteamDialogWindow) async throws {
        try await wait { (try? await host.webView.evaluateJavaScript("document.querySelectorAll('#client>.control').length")) as? Int == host.dialog.controls?.count }
    }

    private func wait(_ predicate: @MainActor () async throws -> Bool) async throws {
        for _ in 0..<120 {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(try await predicate())
    }
}
