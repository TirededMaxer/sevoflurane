import AppKit

/// Native macOS menus dispatch the original Steam webpage commands.
enum SevofluraneMainMenu {
    static func install(mirror: SteamMenuMirror) {
        NSApp.mainMenu = makeMenu(mirror: mirror)
        NSApp.windowsMenu = NSApp.mainMenu?.item(withTitle: "Window")?.submenu
        NSApp.helpMenu = mirror.menu(for: "Help")
    }

    static func makeMenu(mirror: SteamMenuMirror) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu(), title: "Sevoflurane"))
        for title in SteamMenuMirror.rootTitles where title != "Help" {
            main.addItem(submenu(mirror.menu(for: title), title: title))
        }
        main.addItem(submenu(editMenu(), title: "Edit"))
        let windows = NSMenu()
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windows.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(windows, title: "Window"))
        main.addItem(submenu(mirror.menu(for: "Help"), title: "Help"))
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
