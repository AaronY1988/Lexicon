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

struct KeyCombo {
    let keyCode: UInt32       // Carbon virtual key code
    let modifiers: UInt32     // Carbon modifier flag mask

    /// ⌃⌘D — the system "look up in dictionary" shortcut, repurposed.
    static let controlCommandD = KeyCombo(
        keyCode: UInt32(kVK_ANSI_D),
        modifiers: UInt32(controlKey | cmdKey)
    )
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
