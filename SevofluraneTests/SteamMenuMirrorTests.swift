import AppKit
import Testing
@testable import Sevoflurane

@MainActor
struct SteamMenuMirrorTests {
    @Test
    func `a menu click runs only while the item still carries its label`() {
        let script = SteamMenuMirror.clickScript(rootTitle: "Games", childIndex: 3, label: #"Say "hi""#)
        #expect(script.contains(#"item.textContent.trim() !== "Say \"hi\"") return "moved";"#))
        #expect(script.contains(#"v.m_strTitle === "Games Root Menu""#))
        #expect(script.contains("el.children[3]"))
    }
}

@MainActor
struct SevofluraneMainMenuTests {
    @Test
    func steamMenusAndNativeEditingShortcutsShareTheMenuBar() async throws {
        let menu = SevofluraneMainMenu.makeMenu(mirror: SteamMenuMirror(host: SteamWebHost()))
        #expect(menu.items.filter { !$0.isHidden }.map(\.title) == ["Sevoflurane", "Steam", "View", "Friends", "Games", "Edit", "Window", "Help"])
        let application = try #require(menu.item(withTitle: "Edit")?.submenu)
        application.autoenablesItems = false
        let recorder = ShortcutRecorder()
        let shortcuts: [(String, UInt16)] = [("x", 7), ("c", 8), ("v", 9), ("a", 0), ("z", 6)]
        // Install a fully configured fixture. Publishing the menu first lets
        // AppKit validate/cache the initial Cut command against the real responder.
        for (key, _) in shortcuts {
            let item = try #require(application.items.first { $0.keyEquivalent == key })
            #expect(!item.isHidden)
            item.target = recorder
            item.action = #selector(ShortcutRecorder.command(_:))
            item.isEnabled = true
        }
        let previous = NSApp.mainMenu
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = previous }
        for (key, code) in shortcuts {
            menu.update()
            application.update()
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            #expect(menu.performKeyEquivalent(with: event))
            for _ in 0..<80 {
                if recorder.keys.last == key { break }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        #expect(recorder.keys == ["x", "c", "v", "a", "z"])
    }
}

@MainActor
private final class ShortcutRecorder: NSObject {
    var keys: [String] = []
    @objc func command(_ item: NSMenuItem) { keys.append(item.keyEquivalent) }
}
