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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure we never accidentally show a dock icon (also enforced by Info.plist LSUIElement).
        NSApp.setActivationPolicy(.accessory)

        panel   = PanelController()
        menuBar = MenuBarController(onOpen: { [weak self] in self?.togglePanel() },
                                    onQuit: { NSApp.terminate(nil) })

        hotKey  = HotKeyManager { [weak self] in
            self?.togglePanel(usingSelection: true)
        }
        hotKey.register(.controlCommandD)
    }

    func togglePanel(usingSelection: Bool = false) {
        if panel.isVisible {
            panel.hide()
        } else {
            var seed: String? = nil
            if usingSelection {
                seed = SelectionService.copyCurrentSelection()
            }
            panel.show(prefill: seed)
        }
    }
}
