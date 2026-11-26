import AppKit
import Carbon
import ClipShelfCore
import SwiftUI

private final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
public final class ShelfPanelController {
    private let store: ClipboardStore
    private let panel: ShelfPanel
    private let shelfHeight: CGFloat = 310

    private var previousApp: NSRunningApplication?
    private var localKeyMonitor: Any?
    private var globalClickMonitor: Any?
    private var suppressInitialSelectAll = false

    private let onOpenSettings: () -> Void
    private let onOpenAbout: () -> Void
    private let onOpenHelp: () -> Void
    private let onQuit: () -> Void

    public var isVisible: Bool { panel.isVisible }

    public init(
        store: ClipboardStore,
        onOpenSettings: @escaping () -> Void,
        onOpenAbout: @escaping () -> Void,
        onOpenHelp: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.store = store
        self.onOpenSettings = onOpenSettings
        self.onOpenAbout = onOpenAbout
        self.onOpenHelp = onOpenHelp
        self.onQuit = onQuit

        let initialRect = NSRect(x: 0, y: 0, width: 1200, height: shelfHeight)
        self.panel = ShelfPanel(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false

        let rootView = ShelfView(
            store: store,
            onPaste: { [weak self] item, plainOnly in
                self?.pasteItem(item, plainTextOnly: plainOnly)
            },
            onCopyOnly: { [weak self] item in
                self?.copyOnly(item)
            },
            onQuickLook: { [weak self] item in
                guard let self else { return }
                QuickLookHelper.shared.preview(item: item, storage: self.store.storage)
            },
            onOpenSettings: { [weak self] in
                self?.hide()
                self?.onOpenSettings()
            },
            onOpenAbout: { [weak self] in
                self?.hide()
                self?.onOpenAbout()
            },
            onOpenHelp: { [weak self] in
                self?.hide()
                self?.onOpenHelp()
            },
            onQuit: onQuit
        )

        panel.contentView = NSHostingView(rootView: rootView)
    }

    public func toggle() {
        if panel.isVisible {
            hide(immediately: false, restoreFocus: true)
        } else {
            show()
        }
    }

    public func show() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }

        if store.selectedItemID == nil {
            store.selectedItemID = store.filteredItems.first?.id
        }

        let screen = activeScreen()
        let visibleFrame = screen.frame
        let finalFrame = NSRect(
            x: visibleFrame.minX,
            y: visibleFrame.minY,
            width: visibleFrame.width,
            height: shelfHeight
        )

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            panel.setFrame(finalFrame, display: true)
            panel.alphaValue = 1
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            let startFrame = NSRect(
                x: finalFrame.minX,
                y: finalFrame.minY - 36,
                width: finalFrame.width,
                height: finalFrame.height
            )
            panel.setFrame(startFrame, display: true)
            panel.alphaValue = 0
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(finalFrame, display: true)
                panel.animator().alphaValue = 1
            }
        }

        installMonitors()
    }

    public func hide(immediately: Bool = false, restoreFocus: Bool = false) {
        removeMonitors()
        QuickLookHelper.shared.closeIfVisible()
        store.isSearching = false
        store.searchQuery = ""

        guard panel.isVisible else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if immediately || reduceMotion {
            panel.orderOut(nil)
            if restoreFocus {
                previousApp?.activate(options: [])
            }
            return
        }

        var endFrame = panel.frame
        endFrame.origin.y -= 24
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(endFrame, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.panel.orderOut(nil)
                if restoreFocus {
                    self?.previousApp?.activate(options: [])
                }
            }
        })
    }

    private func pasteItem(_ item: ClipboardItem, plainTextOnly: Bool) {
        AutoPasteService.shared.paste(
            item,
            storage: store.storage,
            targetApp: previousApp,
            plainTextOnly: plainTextOnly,
            soundEnabled: store.settings.soundEffectsEnabled,
            dismissShelf: { [weak self] in self?.hide(immediately: true, restoreFocus: false) }
        )
    }

    private func copyOnly(_ item: ClipboardItem) {
        AutoPasteService.shared.copyToPasteboard(item, storage: store.storage, plainTextOnly: false, markInternal: true)
        SoundEffectPlayer.shared.playCopy(enabled: store.settings.soundEffectsEnabled)
        hide()
    }

    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func installMonitors() {
        removeMonitors()

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            return self.handleKeyDown(event) ? nil : event
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel.isVisible else { return }
                let mouse = NSEvent.mouseLocation
                if !self.panel.frame.contains(mouse) {
                    self.hide()
                }
            }
        }
    }

    private func removeMonitors() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = Int(event.keyCode)

        // Escape
        if keyCode == kVK_Escape {
            if store.isSearching {
                store.isSearching = false
                return true
            }
            hide(immediately: false, restoreFocus: true)
            return true
        }

        // ⌘F -> Expand & focus search
        if flags == .command && event.charactersIgnoringModifiers?.lowercased() == "f" {
            store.isSearching = true
            return true
        }

        // ⌘, -> Settings
        if flags == .command && event.charactersIgnoringModifiers == "," {
            hide()
            onOpenSettings()
            return true
        }

        // ⌘1 .. ⌘9 -> Instant paste slot 1..9
        if flags == .command, let ch = event.charactersIgnoringModifiers, let digit = Int(ch), (1...9).contains(digit) {
            if let item = store.selectItem(atIndex: digit - 1) {
                pasteItem(item, plainTextOnly: false)
                return true
            }
        }

        // ⌘⌫ -> Delete selected card (when not editing search text)
        if flags == .command && keyCode == kVK_Delete && !store.isSearching {
            if let item = store.selectedItem {
                store.deleteItem(item)
                return true
            }
        }

        // Arrow navigation (always works unless user is editing search text with arrows)
        if keyCode == kVK_LeftArrow && !store.isSearching {
            store.moveSelection(delta: -1)
            return true
        }
        if keyCode == kVK_RightArrow && !store.isSearching {
            store.moveSelection(delta: 1)
            return true
        }

        // Return / Shift+Return -> Paste selected item
        if keyCode == kVK_Return || keyCode == kVK_ANSI_KeypadEnter {
            if let item = store.selectedItem {
                pasteItem(item, plainTextOnly: flags.contains(.shift))
                return true
            }
        }

        // Space -> Quick Look (when not typing in search)
        if keyCode == kVK_Space && !store.isSearching {
            if let item = store.selectedItem {
                QuickLookHelper.shared.preview(item: item, storage: store.storage)
                return true
            }
        }

        // Instant type-to-search: any printable character starts searching immediately,
        // and buffers fast keystrokes until the TextField's field editor is first responder.
        if !flags.contains(.command),
           !flags.contains(.control),
           !flags.contains(.function),
           let chars = event.characters,
           !chars.isEmpty,
           chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            let isFieldEditorActive = (panel.firstResponder is NSTextView)
            if !store.isSearching {
                if !chars.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
                    store.searchQuery = chars
                    suppressInitialSelectAll = true
                    store.isSearching = true
                    return true
                }
            } else if !isFieldEditorActive {
                store.searchQuery += chars
                suppressInitialSelectAll = true
                return true
            } else if suppressInitialSelectAll, let editor = panel.firstResponder as? NSTextView {
                // Guard against AppKit's automatic select-all right after mounting the TextField
                suppressInitialSelectAll = false
                let totalLen = (editor.string as NSString).length
                editor.setSelectedRange(NSRange(location: totalLen, length: 0))
            }
        }

        return false
    }
}
