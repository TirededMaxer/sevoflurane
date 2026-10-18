import AppKit

/// Steam keeps its own menu strip inside its original document. Only the
/// Sevoflurane application menu belongs in the macOS menu bar.
enum SevofluraneMainMenu {
    static func install() {
        NSApp.mainMenu = makeMenu()
        NSApp.windowsMenu = nil
        NSApp.helpMenu = nil
    }

    static func makeMenu() -> NSMenu {
        let main = NSMenu()
        let application = appMenu()
        // WebKit uses AppKit's responder-chain commands for macOS editing
        // shortcuts. Hidden items keep that routing without a visible Edit menu.
        let editing = editMenu()
        for item in editing.items where !item.isSeparatorItem {
            editing.removeItem(item)
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
            application.addItem(item)
        }
        for (title, action, key) in [
            ("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            ("Close", #selector(NSWindow.performClose(_:)), "w"),
        ] {
            let item = application.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
        }
        main.addItem(submenu(application, title: "Sevoflurane"))
        return main
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(
            withTitle: "About Sevoflurane",
            action: #selector(AppDelegate.showAbout(_:)),
            keyEquivalent: "",
        )
        menu.addItem(.separator())
        // No ⌘, here: in this app that shortcut belongs to Steam ▸ Settings,
        // which is the settings window a user of a Steam client means.
        menu.addItem(
            withTitle: "Sevoflurane Settings…",
            action: #selector(AppDelegate.showSettings(_:)),
            keyEquivalent: "",
        )
        // Checked by `AppDelegate.validateMenuItem(_:)`, so it reads the
        // switch however it was last flipped.
        menu.addItem(
            withTitle: InterfaceCopy.localized("Streamer Mode"),
            action: #selector(AppDelegate.toggleStreamerMode(_:)),
            keyEquivalent: "",
        )
        menu.addItem(.separator())

        let services = NSMenu()
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services
        menu.addItem(.separator())

        menu.addItem(
            withTitle: "Hide Sevoflurane",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h",
        )
        let hideOthers = menu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h",
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "",
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Sevoflurane",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q",
        )
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(
            withTitle: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "z",
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x",
        )
        menu.addItem(
            withTitle: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c",
        )
        menu.addItem(
            withTitle: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v",
        )
        menu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a",
        )
        return menu
    }

}
