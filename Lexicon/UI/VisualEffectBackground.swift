//
//  VisualEffectBackground.swift
//  Lexicon
//
//  SwiftUI wrapper over NSVisualEffectView — used to get the proper macOS
//  frosted-glass material under the search panel (matches Spotlight).
//

import SwiftUI
import AppKit

struct VisualEffectBackground: NSViewRepresentable {

    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = state
        v.isEmphasized = true
        return v
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
    }
}

/// The themed base background. Reading Room = warm paper over a whisper of the
/// system blur; Luminous Glass = a vivid gradient (optionally over the blur).
/// Re-evaluated whenever a parent that observes `AppSettings` re-renders.
struct AppBackground: View {

    /// Whether to layer the system frosted blur behind (true for the floating
    /// panel; false for the titled auxiliary windows).
    var blur: Bool = true
    /// The current theme — passed in (not read from the global `Theme.active`)
    /// so that changing it actually re-renders this view: SwiftUI only re-runs a
    /// child's body when one of its inputs changes, and a global isn't an input.
    var theme: AppTheme = .readingRoom

    var body: some View {
        ZStack {
            if blur {
                VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                    .ignoresSafeArea()
            }
            fill.ignoresSafeArea()
        }
    }

    @ViewBuilder private var fill: some View {
        switch theme {
        case .readingRoom:
            Theme.paper.opacity(blur ? 0.92 : 1)
        case .luminousGlass:
            LinearGradient(colors: Theme.glassGradient,
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .opacity(blur ? 0.92 : 1)
        }
    }
}
