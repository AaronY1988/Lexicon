//
//  LexiconApp.swift
//  Lexicon
//

import SwiftUI

@main
struct LexiconApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // We're a menu-bar app — Settings is the only Scene we declare so SwiftUI
        // doesn't make a window for us. Everything else is driven from AppDelegate.
        Settings {
            PreferencesView()
        }
    }
}

/// Lightweight placeholder so the SwiftUI `App` has a Scene to declare. It is
/// not surfaced anywhere — Launch at Login lives in the menu-bar menu.
private struct PreferencesView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent)
            Text("Lexicon")
                .font(.title2.weight(.semibold))
            Text("Press ⌃⌘D anywhere to look up a word.")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(width: 360, height: 240)
    }
}
