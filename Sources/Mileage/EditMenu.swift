import AppKit

/// Restores ⌘X / ⌘C / ⌘V / ⌘Z inside mileage's own text fields.
///
/// macOS does not implement the editing shortcuts in the text field itself — it dispatches them
/// from the main menu's key equivalents down the responder chain. A menu bar app never builds a
/// main menu, so `NSApp.mainMenu` is nil and every one of those shortcuts silently does nothing.
///
/// The menu is never visible: an `.accessory` app has no menu bar to show it in. It exists only
/// to carry the key equivalents. Without it the Claude sign-in cannot be completed at all, since
/// that flow asks the user to paste a code that they have no way to paste.
enum EditMenu {
    static func install() {
        let mainMenu = NSMenu()

        // macOS always treats the first item of the main menu as the application menu, whatever
        // it is called. Without this placeholder the Edit menu is silently swallowed into that
        // role and no Edit menu exists at all.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "Quit mileage",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)

        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu

        // Selectors are resolved on the first responder at runtime, which is why the standard
        // text-editing ones work here without mileage implementing any of them.
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]

        editMenu.addItem(.separator())

        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )

        // ⌘W closes the Accounts window; without it the window can only be closed by mouse.
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )

        NSApp.mainMenu = mainMenu
    }
}
