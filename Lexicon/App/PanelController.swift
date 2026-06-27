//
//  PanelController.swift
//  Lexicon
//
//  Owns the floating NSPanel that hosts the SwiftUI search UI.
//  Designed to feel like Spotlight: frosted glass, centered on screen,
//  appears/disappears with a subtle scale-and-fade.
//

import AppKit
import SwiftUI

/// Borderless `NSPanel` subclass that *will* become key/main. By default a
/// borderless panel refuses key status, which means our SwiftUI text field
/// would never receive keyboard events.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// `@MainActor` because: (1) we touch NSPanel / NSAnimationContext / NSApp,
// which are all main-actor types; (2) we construct `SearchViewModel`, which is
// itself `@MainActor` (so `init()` is implicitly main-actor isolated).
@MainActor
final class PanelController: NSObject, NSWindowDelegate {

    private let panel: KeyablePanel
    private let viewModel: SearchViewModel
    // Reading Room is a single warm column — no sidebar — so the panel is
    // narrower and a touch taller than the old two-pane layout.
    private let panelSize = NSSize(width: 640, height: 500)
    /// Set to `true` between `show()` and the moment the show animation finishes.
    /// Used to suppress the spurious `windowDidResignKey` that can fire during
    /// the `NSApp.activate(...)` ↔ `makeKeyAndOrderFront` handoff.
    private var isAnimatingIn: Bool = false

    var isVisible: Bool { panel.isVisible }

    override init() {
        let initialRect = NSRect(origin: .zero,
                                 size: NSSize(width: 640, height: 500))

        panel = KeyablePanel(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow

        viewModel = SearchViewModel()

        super.init()
        panel.delegate = self

        let root = SearchPanelView(viewModel: viewModel,
                                   onClose: { [weak self] in self?.hide() })

        let host = NSHostingView(rootView: root)
        host.frame = initialRect

        // Round the host's container so the frosted blur clips correctly.
        let container = NSView(frame: initialRect)
        container.wantsLayer = true
        container.layer?.cornerRadius = 18
        container.layer?.masksToBounds = true
        container.layer?.cornerCurve = .continuous
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)

        panel.contentView = container
    }

    func show(prefill: String? = nil) {
        positionPanel()
        if let prefill, !prefill.isEmpty {
            viewModel.queryFromExternalSeed(prefill)
        } else {
            viewModel.focusForNewLookup()
        }
        isAnimatingIn = true
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            self?.isAnimatingIn = false
        })
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
    }

    // MARK: - Layout

    private func positionPanel() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        // Slightly above true vertical center — feels balanced like Spotlight.
        let x = visible.midX - panelSize.width / 2
        let y = visible.midY - panelSize.height / 2 + visible.height * 0.10
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: panelSize),
                       display: true)
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Suppress the spurious resign that fires during the show animation
        // (NSApp.activate → makeKeyAndOrderFront can briefly bounce key state).
        if isAnimatingIn { return }
        // Dismiss when the user clicks elsewhere — Spotlight-style.
        hide()
    }
}
