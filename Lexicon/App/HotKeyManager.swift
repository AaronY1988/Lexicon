//
//  HotKeyManager.swift
//  Lexicon
//
//  Carbon-based global hotkey registration. We use Carbon (not NSEvent global
//  monitors) because Carbon hotkeys are *system-wide* and work even when other
//  apps are frontmost without requiring Accessibility permission.
//

import Carbon.HIToolbox
import AppKit

struct KeyCombo: Codable, Equatable {
    let keyCode: UInt32       // Carbon virtual key code
    let modifiers: UInt32     // Carbon modifier flag mask
    var keyLabel: String      // human-readable key, e.g. "D", "Space", "F1"

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    /// ⌃⌘D — the system "look up in dictionary" shortcut, repurposed (default).
    static let controlCommandD = KeyCombo(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(controlKey | cmdKey),
        keyLabel: "D"
    )

    /// Symbol tokens for keycap rendering, e.g. ["⌃", "⌘", "D"].
    var capTokens: [String] {
        var t: [String] = []
        if modifiers & UInt32(controlKey) != 0 { t.append("⌃") }
        if modifiers & UInt32(optionKey)  != 0 { t.append("⌥") }
        if modifiers & UInt32(shiftKey)   != 0 { t.append("⇧") }
        if modifiers & UInt32(cmdKey)     != 0 { t.append("⌘") }
        t.append(keyLabel)
        return t
    }

    /// Compact one-string form, e.g. "⌃⌘D".
    var displayString: String { capTokens.joined() }

    /// Build from a key-down event. Requires at least one of ⌘ / ⌃ / ⌥ so the
    /// shortcut is safe as a system-wide hotkey. Returns nil for unusable events
    /// (no primary modifier, or a key we can't label).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasPrimary = flags.contains(.command) || flags.contains(.control) || flags.contains(.option)
        guard hasPrimary else { return nil }
        guard let label = KeyCombo.label(for: event) else { return nil }

        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }

        self.keyCode = UInt32(event.keyCode)
        self.modifiers = carbon
        self.keyLabel = label
    }

    private static func label(for event: NSEvent) -> String? {
        if let special = specialKeyLabels[Int(event.keyCode)] { return special }
        if let ch = event.charactersIgnoringModifiers?.first {
            if ch.isLetter || ch.isNumber || "`-=[]\\;',./".contains(ch) {
                return String(ch).uppercased()
            }
        }
        return nil
    }

    private static let specialKeyLabels: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    ]
}

final class HotKeyManager {

    // `@MainActor` on the callback because everything we end up doing in
    // response to the hotkey (showing the panel, capturing the selection)
    // is main-actor isolated. We hop to main with `DispatchQueue.main.async`
    // before invoking it, so this annotation is always honored at runtime.
    private let onTrigger: @MainActor () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    init(onTrigger: @escaping @MainActor () -> Void) {
        self.onTrigger = onTrigger
    }

    deinit { unregister() }

    func register(_ combo: KeyCombo) {
        unregister()

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: OSType(kEventHotKeyPressed))

        // Install the global handler — fires for every registered hotkey in the app.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, userData) -> OSStatus in
                guard let userData = userData, let eventRef = eventRef else { return noErr }
                var hkID = EventHotKeyID()
                let status = GetEventParameter(eventRef,
                                               EventParamName(kEventParamDirectObject),
                                               EventParamType(typeEventHotKeyID),
                                               nil,
                                               MemoryLayout<EventHotKeyID>.size,
                                               nil,
                                               &hkID)
                if status == noErr {
                    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                    // Hop to the main actor before invoking the @MainActor callback.
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { manager.onTrigger() }
                    }
                }
                return noErr
            },
            1,
            &eventSpec,
            selfPtr,
            &eventHandler
        )

        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x4C455849 /* 'LEXI' */), id: 1)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            self.hotKeyRef = ref
        } else {
            NSLog("Lexicon: failed to register global hotkey (status \(status)). " +
                  "Another app may already own ⌃⌘D.")
        }
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let h   = eventHandler { RemoveEventHandler(h); eventHandler = nil }
    }
}

// MARK: - Hotkey recorder view
//
// A small AppKit control: click to start recording, then press a combination.
// Lives here (not in the SwiftUI file) because it needs the Carbon `kVK_*`
// constants. The SwiftUI `HotKeyRecorder` wrapper bridges it into Preferences.

final class HotKeyRecorderView: NSView {

    private var combo: KeyCombo
    var onChange: ((KeyCombo) -> Void)?
    private var recording = false { didSet { needsDisplay = true } }
    private var monitor: Any?

    init(combo: KeyCombo) {
        self.combo = combo
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }

    /// Refresh from SwiftUI without clobbering an in-progress recording.
    func update(combo: KeyCombo, onChange: @escaping (KeyCombo) -> Void) {
        if !recording { self.combo = combo; needsDisplay = true }
        self.onChange = onChange
    }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 30) }

    override func mouseDown(with event: NSEvent) {
        if recording { stop() } else { start() }
    }

    private func start() {
        guard monitor == nil else { return }
        recording = true
        window?.makeFirstResponder(self)
        // A local key-down monitor is far more reliable than relying on
        // first-responder routing through the SwiftUI host: it catches every
        // key press (including ⌘-combinations) while we're recording.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] ev in
            guard let self, self.recording else { return ev }
            if ev.keyCode == UInt16(kVK_Escape) { self.stop(); return nil }
            if let c = KeyCombo(event: ev) {
                self.combo = c
                self.onChange?(c)
                self.stop()
            }
            return nil   // swallow keys while recording so nothing else fires
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        window?.makeFirstResponder(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.75, dy: 0.75)
        let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        let accent = Theme.accentNSColor
        if recording {
            accent.withAlphaComponent(0.12).setFill(); path.fill()
            accent.setStroke(); path.lineWidth = 1.5; path.stroke()
        } else {
            NSColor(white: 0, alpha: 0.05).setFill(); path.fill()
            NSColor.separatorColor.setStroke(); path.lineWidth = 1; path.stroke()
        }
        let text = recording ? "Press shortcut…" : combo.displayString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: recording ? accent : Theme.inkNS,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let pt = NSPoint(x: (bounds.width - size.width) / 2,
                         y: (bounds.height - size.height) / 2)
        (text as NSString).draw(at: pt, withAttributes: attrs)
    }
}
