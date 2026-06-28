//
//  AppDelegate.swift
//  Lexicon
//

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBar: MenuBarController!
    private var panel: PanelController!
    private var hotKey: HotKeyManager!
    private var didPromptAccessibility = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure we never accidentally show a dock icon (also enforced by Info.plist LSUIElement).
        NSApp.setActivationPolicy(.accessory)

        panel   = PanelController()
        menuBar = MenuBarController(onOpen: { [weak self] in self?.togglePanel() },
                                    onQuit: { NSApp.terminate(nil) })

        hotKey  = HotKeyManager { [weak self] in
            self?.togglePanel(usingSelection: true)
        }
        // Register the user's saved hotkey, and re-register whenever it changes
        // in Settings.
        let settings = AppSettings.shared
        settings.hotKeyChanged = { [weak self] combo in self?.hotKey.register(combo) }
        hotKey.register(settings.hotKey)
    }

    func togglePanel(usingSelection: Bool = false) {
        if panel.isVisible {
            panel.hide()
        } else {
            var seed: String? = nil
            if usingSelection {
                if SelectionService.isTrusted {
                    seed = SelectionService.copyCurrentSelection()
                } else if !didPromptAccessibility {
                    // First time the selection hotkey is used without permission:
                    // guide the user to grant Accessibility (just this once).
                    didPromptAccessibility = true
                    SelectionService.requestAccessibilityPermission()
                }
            }
            panel.show(prefill: seed)
        }
    }
}
