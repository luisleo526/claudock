import AppKit

/// Accessory apps still need standard responder-chain editing commands. Without
/// an Edit menu, Command-V can be unavailable in native text/secure fields.
@MainActor enum ApplicationMenu {
    static func install() {
        let main = NSMenu()
        let application = NSMenuItem()
        let applicationMenu = NSMenu(title: "Claudock")
        let quit = applicationMenu.addItem(withTitle: "Quit Claudock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        application.submenu = applicationMenu
        main.addItem(application)

        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editing = NSMenu(title: "Edit")
        editing.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editing.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editing.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editing.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editing
        main.addItem(edit)
        NSApp.mainMenu = main
    }
}
