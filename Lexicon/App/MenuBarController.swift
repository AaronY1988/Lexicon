//
//  MenuBarController.swift
//  Lexicon
//

import AppKit
import ServiceManagement

/// Owns the NSStatusItem in the macOS menu bar.
@MainActor
final class MenuBarController {

    private let statusItem: NSStatusItem
    private let onOpen: () -> Void
    private let onQuit: () -> Void

    init(onOpen: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.onOpen = onOpen
        self.onQuit = onQuit
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // Prefer the custom serif-L template image shipped in the asset
            // catalog; fall back to an SF Symbol if the asset is missing so
            // the menu bar always shows *something*.
            let image: NSImage? = NSImage(named: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "book.closed.fill",
                           accessibilityDescription: "Lexicon")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Lexicon — Look up a word (⌃⌘D)"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        // Right-click or option-click → show menu. Left-click → open panel.
        if event?.type == .rightMouseUp || (event?.modifierFlags.contains(.option) ?? false) {
            statusItem.menu = buildMenu()
            statusItem.button?.performClick(nil)
            // Detach the menu after the user dismisses it so left-clicks still toggle the panel.
            DispatchQueue.main.async { [weak self] in self?.statusItem.menu = nil }
        } else {
            onOpen()
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Look up… (⌃⌘D)",
                     action: #selector(openFromMenu),
                     keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "About Lexicon",
                     action: #selector(showAbout),
                     keyEquivalent: "")
            .target = self

        // Launch at Login — a checkmarked toggle. The menu is rebuilt on every
        // open, so the checkmark always reflects the current system state.
        let launchItem = menu.addItem(withTitle: "Launch at Login",
                                      action: #selector(toggleLaunchAtLogin(_:)),
                                      keyEquivalent: "")
        launchItem.target = self
        launchItem.state = LoginItem.isEnabled ? .on : .off

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Lexicon",
                     action: #selector(quitFromMenu),
                     keyEquivalent: "q")
            .target = self
        return menu
    }

    @objc private func openFromMenu() { onOpen() }
    @objc private func quitFromMenu() { onQuit() }
    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let nowEnabled = LoginItem.setEnabled(!LoginItem.isEnabled)
        sender.state = nowEnabled ? .on : .off
    }
}

// MARK: - Launch at Login
//
// Wraps `SMAppService.mainApp` (macOS 13+), the modern replacement for the
// deprecated `SMLoginItemSetEnabled`. Registering adds Lexicon to the user's
// Login Items; unregistering removes it. No helper bundle or extra entitlement
// is required for the main-app service.

enum LoginItem {

    /// True when Lexicon is currently registered to launch at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the login item. Returns the resulting enabled
    /// state (so the caller can update its checkmark even if the change failed).
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            let service = SMAppService.mainApp
            if enabled {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
        } catch {
            NSLog("Lexicon: failed to update Launch at Login — \(error.localizedDescription)")
        }
        return isEnabled
    }
}
