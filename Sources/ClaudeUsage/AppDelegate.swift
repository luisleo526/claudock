import AppKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = MonitorStore()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var dashboard: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        PerfProbe.start()
        NSApp.setActivationPolicy(.accessory)
        ApplicationMenu.install()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "Claudock")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "Claudock"
        statusItem.button?.target = self; statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 510, height: 680)
        popover.contentViewController = NSHostingController(rootView: MonitorView(store: store))
        store.openDashboard = { [weak self] in self?.showDashboard() }
        store.appearanceChanged = { [weak self] name in self?.applyAppearance(name) }
        applyAppearance(store.appearance)
        store.statusChanged = { [weak self] in self?.updateStatus() }
        store.start()

        // An ordinary launch stays in the menu bar. Setup appears only until onboarding is complete.
        if store.isDemo {
            DispatchQueue.main.async { [weak self] in self?.showDashboard() }
        } else if !UserDefaults.standard.bool(forKey: "onboardingComplete") {
            DispatchQueue.main.async { [weak self] in self?.showPopover() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover(activate: true)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    private func showPopover(activate: Bool = false) {
        guard let button = statusItem.button else { return }
        let availableHeight = (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 704
        popover.contentSize = NSSize(width: 510, height: min(680, max(420, availableHeight - 24)))
        if activate { NSApp.activate(ignoringOtherApps: true) }
        if !popover.isShown { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        applyAppearance(store.appearance)
    }

    private func showDashboard() {
        popover.performClose(nil)
        if dashboard == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Claudock"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.minSize = NSSize(width: 460, height: 460)
            window.level = .normal
            window.backgroundColor = .windowBackgroundColor
            window.contentView = NSHostingView(rootView: MonitorView(store: store))
            window.setFrameAutosaveName("ClaudeUsageDashboard")
            if !window.setFrameUsingName("ClaudeUsageDashboard") { window.center() }
            dashboard = window
        }
        applyAppearance(store.appearance)
        NSApp.activate(ignoringOtherApps: true)
        dashboard?.deminiaturize(nil)
        dashboard?.makeKeyAndOrderFront(nil)
    }

    private func applyAppearance(_ name: String) {
        let appearance = name == "system" ? nil : NSAppearance(named: name == "light" ? .aqua : .darkAqua)
        popover.appearance = appearance
        popover.contentViewController?.view.appearance = appearance
        popover.contentViewController?.view.window?.appearance = appearance
        dashboard?.appearance = appearance
    }

    @objc private func togglePopover() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            guard let button = statusItem.button else { return }
            let menu = NSMenu()
            menu.addItem(withTitle: "Show usage", action: #selector(openPopover), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Open dashboard", action: #selector(openDashboard), keyEquivalent: "").target = self
            let refreshItem = menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "")
            refreshItem.target = self
            refreshItem.isEnabled = store.canRefresh
            menu.autoenablesItems = false
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Claudock", action: #selector(quit), keyEquivalent: "q").target = self
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 4), in: button)
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover(activate: true)
        }
    }

    @objc private func openPopover() { showPopover(activate: true) }
    @objc private func openDashboard() { showDashboard() }
    @objc private func refresh() { store.now = Date(); store.refresh(manual: true) }
    @objc private func quit() { NSApp.terminate(nil) }
    private func updateStatus() {
        let count = store.attentionCount
        statusItem.button?.title = count > 0 ? " \(count)" : ""
        statusItem.button?.toolTip = "Claudock · \(store.availableCount)/\(store.subscriptionCount) profiles updated\(count > 0 ? " · \(count) need attention or are near a limit" : "")"
    }
}
