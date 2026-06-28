//
//  Theme.swift
//  Lexicon
//

import SwiftUI
import AppKit

enum Theme {

    // MARK: - Reading Room palette
    //
    // Lexicon's redesign trades the cold violet glass for a warm, paper-calm
    // reading surface. Typography carries the design; a single restrained
    // violet accent survives for the few interactive marks (sense numbers, the
    // speaker, the active tab). Every token below is *adaptive* — it resolves
    // to a "Daylight" (light) or "Lamplight" (dark) value via the active
    // appearance, so the whole panel re-tints when the system mode flips.

    /// Build a Color that resolves differently in light vs dark appearance.
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        })
    }

    private static func hex(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    // MARK: Surfaces

    /// The panel's warm paper surface. Layered over the frosted blur at high
    /// opacity so it reads as paper with just a hint of translucency.
    static let paper        = adaptive(light: hex(0xFB, 0xF8, 0xF2), dark: hex(0x1B, 0x19, 0x1D))
    /// A slightly deeper paper — the ORIGIN block, recents pills, chip fills.
    static let paperRaised  = adaptive(light: hex(0xF2, 0xEC, 0xE1), dark: hex(0x26, 0x23, 0x2A))

    // MARK: Ink (text)

    /// Primary reading ink — warm near-black / warm cream.
    static let ink          = adaptive(light: hex(0x2A, 0x25, 0x21), dark: hex(0xEC, 0xE6, 0xDD))
    /// Secondary ink — examples, phonetics, supporting copy.
    static let inkSecondary = adaptive(light: hex(0x7C, 0x73, 0x6A), dark: hex(0x9C, 0x94, 0x8A))
    /// Tertiary ink — labels, hairline hints, inactive tabs.
    static let inkTertiary  = adaptive(light: hex(0xA8, 0x9E, 0x91), dark: hex(0x6E, 0x66, 0x5E))

    // MARK: Hairlines / chips

    /// Hairline dividers and panel border.
    static let line         = adaptive(light: hex(0x3C, 0x32, 0x28).withAlphaComponent(0.14),
                                       dark:  hex(0xFF, 0xFA, 0xF0).withAlphaComponent(0.10))
    /// Quiet chip fill (keyboard caps, phonetic tags, action buttons).
    static let chip         = adaptive(light: hex(0x3C, 0x32, 0x28).withAlphaComponent(0.05),
                                       dark:  hex(0xFF, 0xFA, 0xF0).withAlphaComponent(0.06))

    // MARK: - Brand accent
    //
    // One restrained accent, dialed back from the old vivid violet. A muted
    // indigo in Daylight, a softer lavender in Lamplight so it stays legible on
    // warm charcoal.

    /// The single accent — sense numbers, the speaker, the active tab, ⌃⌘D.
    static let accent = adaptive(light: hex(0x5A, 0x50, 0xC8), dark: hex(0xA9, 0x9B, 0xFF))
    /// A soft wash of the accent — the sense-number tile fill.
    static let accentSoft = adaptive(light: hex(0x5A, 0x50, 0xC8).withAlphaComponent(0.12),
                                     dark:  hex(0xA9, 0x9B, 0xFF).withAlphaComponent(0.16))

    /// Warm amber for the active favorite star — friendlier than system yellow.
    static let star = adaptive(light: hex(0xE0, 0xA9, 0x3B), dark: hex(0xF0, 0xC0, 0x4E))

    /// AppKit twin of `ink`, for the NSTextField search field's text color.
    static let inkNS = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? hex(0xEC, 0xE6, 0xDD) : hex(0x2A, 0x25, 0x21)
    }

    // MARK: - Legacy gradient tokens
    //
    // Kept so any code still referencing the old vivid brand keeps compiling.
    // The redesign no longer paints these across the chrome.

    /// Bright primary violet — the heart of the old brand.
    static let violet      = Color(red: 0.49, green: 0.33, blue: 0.96)   // ~#7E54F5
    /// Warmer magenta-violet, used as the top of the brand gradient.
    static let magenta     = Color(red: 0.64, green: 0.31, blue: 0.95)   // ~#A34FF2
    /// Deep indigo, used as the foot of the brand gradient.
    static let indigoDeep  = Color(red: 0.36, green: 0.24, blue: 0.88)   // ~#5C3DE0

    /// The signature gradient — sweep it across hero glyphs, the wordmark,
    /// active tabs, sense badges, and the speaker control.
    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [magenta, violet, indigoDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// A soft, low-opacity wash of the gradient for chip / pill fills.
    static var accentGradientSoft: LinearGradient {
        LinearGradient(
            colors: [magenta.opacity(0.18), violet.opacity(0.18), indigoDeep.opacity(0.18)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// AppKit twin of `paper`, for window background colors so rounded-corner
    /// slivers blend instead of flashing white/black.
    static let paperNSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? NSColor(srgbRed: 0x1B/255, green: 0x19/255, blue: 0x1D/255, alpha: 1)
                      : NSColor(srgbRed: 0xFB/255, green: 0xF8/255, blue: 0xF2/255, alpha: 1)
    }

    /// Serif font for the body of definitions — feels more "dictionary".
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Rounded UI font for everything else.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Font for IPA / phonetic strings.
    ///
    /// We DON'T use `.monospaced` here — SF Mono lacks most of the IPA
    /// Extensions block (ʊ, ɪ, ə, ŋ, ʃ, etc.), so IPA strings render as
    /// substitute glyphs (boxes / wrong characters). The default San
    /// Francisco system font does cover IPA.
    static func ipa(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .default)
    }

    /// Legacy alias — kept for any code that still asks for the old name.
    static func phonetic(_ size: CGFloat) -> Font {
        ipa(size)
    }
}

// MARK: - User appearance settings

/// User-adjustable appearance settings, persisted to `UserDefaults`.
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    /// Multiplier applied to the definition *body* text (1.0 = default). The
    /// Preferences slider constrains it to `range`.
    @Published var definitionFontScale: Double {
        didSet { UserDefaults.standard.set(definitionFontScale, forKey: Self.kScale) }
    }

    /// Allowed scale range for the slider.
    static let range: ClosedRange<Double> = 0.85...1.5

    private static let kScale = "definitionFontScale"

    private init() {
        let saved = UserDefaults.standard.object(forKey: Self.kScale) as? Double
        definitionFontScale = saved.map {
            Swift.min(Self.range.upperBound, Swift.max(Self.range.lowerBound, $0))
        } ?? 1.0
    }
}
