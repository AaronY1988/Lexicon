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
