//
//  SelectionService.swift
//  Lexicon
//
//  Grabs whatever text is currently selected in the frontmost application.
//  Strategy: synthesize a ⌘C, then peek the pasteboard. We back-up and restore
//  the original clipboard so we never clobber the user's copy/paste.
//
//  Requires Accessibility permission. If not granted, returns nil silently.
//

import AppKit
import ApplicationServices

enum SelectionService {

    /// Returns the selected text from the currently-frontmost app, or nil if
    /// the selection couldn't be captured (no permission, nothing selected, …).
    static func copyCurrentSelection() -> String? {
        guard hasAccessibilityPermission() else { return nil }

        let pasteboard = NSPasteboard.general

        // Snapshot the current pasteboard so we can restore it.
        let backup: [(type: NSPasteboard.PasteboardType, data: Data)] =
            (pasteboard.pasteboardItems ?? []).flatMap { item in
                item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                }
            }
        let originalChangeCount = pasteboard.changeCount

        // Issue ⌘C as a synthetic keystroke aimed at the frontmost app.
        let src = CGEventSource(stateID: .combinedSessionState)
        let cKey: CGKeyCode = 0x08 // kVK_ANSI_C
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: true)
        let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags   = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        // Give the app a beat to write to the pasteboard.
        let deadline = Date().addingTimeInterval(0.18)
        while pasteboard.changeCount == originalChangeCount, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        let captured = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Restore the original pasteboard contents.
        pasteboard.clearContents()
        if !backup.isEmpty {
            for (type, data) in backup {
                pasteboard.setData(data, forType: type)
            }
        }

        // Heuristics: a selection longer than ~80 chars probably isn't a single word.
        guard let captured, !captured.isEmpty, captured.count <= 80 else { return nil }
        return captured
    }

    private static func hasAccessibilityPermission() -> Bool {
        // `kAXTrustedCheckOptionPrompt` is imported as `Unmanaged<CFString>` in
        // the current ApplicationServices SDK — we have to unwrap it before
        // bridging to String.
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
