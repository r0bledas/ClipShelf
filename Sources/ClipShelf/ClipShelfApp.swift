import AppKit
import ClipShelfCore
import SwiftUI

@main
@MainActor
final class ClipShelfAppDelegate: NSObject, NSApplicationDelegate {
    private var storage: SQLiteStorage!
    private var store: ClipboardStore!
    private var watcher: ClipboardWatcher!
    private var shelfController: ShelfPanelController!
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    static func main() {
        let app = NSApplication.shared
        let delegate = ClipShelfAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            storage = try SQLiteStorage()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        store = ClipboardStore(storage: storage)

        watcher = ClipboardWatcher(
            storage: storage,
            settingsProvider: { [weak self] in self?.store.settings ?? AppSettings() },
            onCapture: { [weak self] item in self?.store.handleCapturedItem(item) },
            onLinkPreviewUpdated: { [weak self] id, title, img in
                self?.store.handleLinkPreviewUpdated(itemID: id, title: title, imageFilename: img)
            }
        )

        shelfController = ShelfPanelController(
            store: store,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onOpenAbout: { [weak self] in self?.openAbout() },
            onOpenHelp: { [weak self] in self?.openHelp() },
            onQuit: { NSApp.terminate(nil) }
        )

        store.onSettingsChanged = { [weak self] old, new in
            guard let self else { return }
            if old.showInMenuBar != new.showInMenuBar {
                self.updateStatusItemVisibility()
            }
            if old.isPaused != new.isPaused {
                self.rebuildStatusMenu()
            }
            if old.openAtLogin != new.openAtLogin {
                self.store.applyOpenAtLogin(new.openAtLogin)
            }
            if old.activateShortcut != new.activateShortcut {
                self.registerGlobalShortcut()
            }
            if old.historyRetention != new.historyRetention {
                self.store.pruneIfNeeded()
            }
        }

        updateStatusItemVisibility()
        installMainMenu()
        registerGlobalShortcut()
        watcher.start()
        SoundEffectPlayer.shared.reload()
    }

    /// Installs a standard Edit menu on NSApp.mainMenu so ⌘A, ⌘X, ⌘C, ⌘V, ⌘Z, ⇧⌘Z
    /// route natively to the active text field (search bar, popovers, Settings).
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit ClipShelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher?.stop()
        GlobalHotkeyManager.shared.unregister()
    }

    // MARK: - Global Shortcut

    private func registerGlobalShortcut() {
        GlobalHotkeyManager.shared.register(shortcut: store.settings.activateShortcut) { [weak self] in
            self?.shelfController.toggle()
        }
    }

    // MARK: - Menu Bar Status Item

    private func updateStatusItemVisibility() {
        if store.settings.showInMenuBar {
            if statusItem == nil {
                statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                if let button = statusItem?.button {
                    button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipShelf")
                    button.image?.isTemplate = true
                }
            }
            rebuildStatusMenu()
        } else if let existing = statusItem {
            NSStatusBar.system.removeStatusItem(existing)
            statusItem = nil
        }
    }

    private func rebuildStatusMenu() {
        guard let statusItem else { return }
        if let button = statusItem.button {
            let symbolName = store.settings.isPaused ? "doc.on.clipboard.fill" : "doc.on.clipboard"
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ClipShelf")
            button.image?.isTemplate = true
            button.alphaValue = store.settings.isPaused ? 0.5 : 1.0
        }

        let menu = NSMenu()
        let showItem = NSMenuItem(title: "Show ClipShelf (\(store.settings.activateShortcut.displayString))", action: #selector(menuToggleShelf), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(.separator())

        let pauseTitle = store.settings.isPaused ? "Resume ClipShelf" : "Pause ClipShelf"
        let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(menuTogglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(menuOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(title: "About ClipShelf", action: #selector(menuOpenAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit ClipShelf", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func menuToggleShelf() { shelfController.toggle() }
    @objc private func menuTogglePause() { store.settings.isPaused.toggle() }
    @objc private func menuOpenSettings() { openSettings() }
    @objc private func menuOpenAbout() { openAbout() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: - Windows

    private func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(store: store))
            let win = NSWindow(contentViewController: hosting)
            win.title = "ClipShelf Settings"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            win.center()
            settingsWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func openAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "ClipShelf"
        alert.informativeText = "Open-source native macOS clipboard shelf.\n\nPress \(store.settings.activateShortcut.displayString) from any app to open your clipboard history."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func openHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "ClipShelf Shortcuts & Tips"
        alert.informativeText = """
        • \(store.settings.activateShortcut.displayString): Toggle the bottom clipboard shelf
        • ⌘F: Expand search
        • ← / →: Select cards
        • ↩ or Double-click: Paste into active app
        • ⇧↩: Paste as plain text
        • ⌘1 – ⌘9: Quick-paste first 9 cards
        • Space: Quick Look preview
        • ⌘⌫: Delete selected card
        • + button: Create color-coded Pinboards
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Got It")
        alert.runModal()
    }
}
