//
//  LexiconApp.swift
//  Lexicon
//

import SwiftUI
import AppKit

@main
struct LexiconApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // We're a menu-bar app — Settings is the only Scene we declare so SwiftUI
        // doesn't make a window for us. It hosts the dictionary preferences and
        // is opened from the menu-bar menu (Settings… ⌘,).
        Settings {
            PreferencesView()
        }
    }
}

/// Preferences: choose which installed Apple dictionaries Lexicon searches, and
/// drag to set their order (which also orders the tabs in a definition).
private struct PreferencesView: View {

    @ObservedObject private var service = DictionaryService.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                header
                hairline
                appearanceSection.padding(16)
                hairline
                dictionariesHeader
                dictionaryList
                hairline
                footer
            }
        }
        .frame(width: 460, height: 560)
    }

    private var hairline: some View { Rectangle().fill(Theme.line).frame(height: 1) }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text("Settings")
                .font(Theme.serif(22, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("APPEARANCE")
                .font(Theme.ui(10, weight: .semibold)).tracking(0.6)
                .foregroundStyle(Theme.inkTertiary)
            HStack {
                Text("Definition text size")
                    .font(Theme.serif(15)).foregroundStyle(Theme.ink)
                Spacer()
                Text("\(Int((settings.definitionFontScale * 100).rounded()))%")
                    .font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.inkSecondary)
            }
            HStack(spacing: 12) {
                Text("A").font(Theme.serif(12)).foregroundStyle(Theme.inkTertiary)
                Slider(value: $settings.definitionFontScale, in: AppSettings.range)
                Text("A").font(Theme.serif(22)).foregroundStyle(Theme.inkTertiary)
            }
            Text("a fortunate stroke of serendipity")
                .font(Theme.serif(16 * settings.definitionFontScale))
                .foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.paperRaised)
        )
    }

    // MARK: Dictionaries

    private var dictionariesHeader: some View {
        HStack {
            Text("DICTIONARIES")
                .font(Theme.ui(10, weight: .semibold)).tracking(0.6)
                .foregroundStyle(Theme.inkTertiary)
            Spacer()
            Text("Drag to reorder")
                .font(Theme.ui(10)).foregroundStyle(Theme.inkTertiary)
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 4)
    }

    @ViewBuilder
    private var dictionaryList: some View {
        if service.allDictionaries.isEmpty {
            emptyState
        } else {
            List {
                ForEach(service.allDictionaries) { dict in
                    row(dict).listRowBackground(Color.clear)
                }
                .onMove { service.moveDictionaries(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func row(_ dict: DictionarySource) -> some View {
        let on = service.isEnabled(dict.id)
        return HStack(spacing: 12) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(on ? Theme.accent : Theme.inkTertiary)
            VStack(alignment: .leading, spacing: 1) {
                Text(dict.name).font(Theme.serif(15)).foregroundStyle(Theme.ink)
                Text(dict.id).font(Theme.ui(11)).foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(Theme.inkTertiary.opacity(0.6))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { service.setEnabled(dict.id, !on) }
    }

    private var footer: some View {
        HStack {
            Text("\(service.enabledIDs.count) of \(service.allDictionaries.count) enabled")
                .font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
            Spacer()
            Button("Rescan") { service.reloadSources() }
                .buttonStyle(.plain)
                .font(Theme.ui(12, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .font(.system(size: 30))
                .foregroundStyle(Theme.inkTertiary)
            Text("No Apple dictionaries found")
                .font(Theme.serif(15)).foregroundStyle(Theme.ink)
            Text("Open Dictionary.app, enable some dictionaries, then click Rescan.")
                .font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
}

/// Factory for the app's auxiliary windows (Preferences, Study), styled to match
/// the main panel: warm paper background, transparent full-height titlebar.
@MainActor
enum LexiconWindows {
    static func paper<Content: View>(_ content: Content, title: String) -> NSWindow {
        let hosting = NSHostingController(rootView: content)
        let win = NSWindow(contentViewController: hosting)
        win.title = title
        win.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.backgroundColor = Theme.paperNSColor
        win.isReleasedWhenClosed = false
        win.center()
        return win
    }
}

/// A plain AppKit window hosting the SwiftUI preferences. We use this instead of
/// opening the SwiftUI `Settings` scene because an accessory (menu-bar-only) app
/// can't reliably summon that scene's window programmatically.
@MainActor
final class PreferencesWindowController {

    static let shared = PreferencesWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            window = LexiconWindows.paper(PreferencesView(), title: "Lexicon Settings")
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Study (spaced-repetition flashcards)

private enum StudyDirection { case recallMeaning, recallWord }

private struct StudyView: View {

    @ObservedObject private var store = StudyStore.shared

    @State private var queue: [StudyCard] = []
    @State private var revealed = false
    @State private var records: [DefinitionRecord] = []
    @State private var direction: StudyDirection = .recallMeaning
    @State private var sessionTotal = 0
    @State private var reviewedCount = 0
    @State private var started = false

    private var current: StudyCard? { queue.first }

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                Rectangle().fill(Theme.line).frame(height: 1)
                if queue.isEmpty { doneState } else { cardArea }
            }
        }
        .frame(width: 520, height: 580)
        .onAppear { if !started { started = true; startSession() } }
        .task(id: current?.id) { await loadRecord() }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "graduationcap")
                .font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.accent)
            Text("Study").font(Theme.serif(20, weight: .semibold)).foregroundStyle(Theme.ink)
            Spacer()
            if sessionTotal > 0 {
                Text("\(min(reviewedCount + 1, sessionTotal)) / \(sessionTotal)")
                    .font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.inkSecondary)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var cardArea: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    wordHeader
                    if showMeaning {
                        if records.isEmpty {
                            Text("No definition found for this word.")
                                .font(Theme.ui(13)).foregroundStyle(Theme.inkSecondary)
                        } else {
                            ForEach(records) { rec in
                                VStack(alignment: .leading, spacing: 8) {
                                    if records.count > 1 {
                                        Text(rec.source.name)
                                            .font(Theme.ui(9, weight: .semibold)).tracking(0.6)
                                            .foregroundStyle(Theme.inkTertiary)
                                            .lineLimit(1)
                                    }
                                    StudyDefinitionView(
                                        record: rec,
                                        hideExamples: direction == .recallWord && !revealed
                                    )
                                }
                            }
                        }
                    }
                    if !revealed { recallHint }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            controls
        }
    }

    @ViewBuilder private var wordHeader: some View {
        switch direction {
        case .recallMeaning:
            Text(current?.word ?? "")
                .font(Theme.serif(38, weight: .semibold)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        case .recallWord:
            Text(revealed ? (current?.word ?? "") : "？ ？ ？")
                .font(Theme.serif(38, weight: .semibold))
                .foregroundStyle(revealed ? Theme.accent : Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var showMeaning: Bool { direction == .recallWord || revealed }

    private var recallHint: some View {
        Text(direction == .recallMeaning ? "Recall the meaning, then reveal."
                                         : "What's the word? Then reveal.")
            .font(Theme.ui(12)).foregroundStyle(Theme.inkTertiary)
    }

    @ViewBuilder private var controls: some View {
        if revealed {
            HStack(spacing: 8) {
                gradeButton("Again", .again)
                gradeButton("Hard", .hard)
                gradeButton("Good", .good)
                gradeButton("Easy", .easy)
            }
            .padding(14)
        } else {
            Button { revealed = true } label: {
                Text("Show answer")
                    .font(Theme.ui(14, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .padding(14)
        }
    }

    private func gradeButton(_ title: String, _ g: ReviewGrade) -> some View {
        Button { grade(g) } label: {
            VStack(spacing: 2) {
                Text(title)
                    .font(Theme.ui(13, weight: .semibold))
                    .foregroundStyle(g == .again ? Theme.inkSecondary : Theme.accent)
                Text(intervalHint(g))
                    .font(Theme.ui(10)).foregroundStyle(Theme.inkTertiary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.chip))
        }
        .buttonStyle(.plain)
    }

    private var doneState: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 46)).foregroundStyle(Theme.accent)
            Text(store.cards.isEmpty ? "No words in study yet" : "All caught up")
                .font(Theme.serif(22, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(store.cards.isEmpty
                 ? "Look up a word and tap the graduation-cap button to add it here."
                 : "\(store.cards.count) words in your deck — nothing due right now.")
                .font(Theme.ui(13)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
    }

    // MARK: Session logic

    private func startSession() {
        queue = store.dueCards
        sessionTotal = queue.count
        reviewedCount = 0
        revealed = false
        direction = Bool.random() ? .recallMeaning : .recallWord
    }

    private func grade(_ g: ReviewGrade) {
        guard let card = current else { return }
        store.grade(card.word, g)
        var q = queue
        q.removeFirst()
        if g == .again {
            if let updated = store.cards.first(where: { $0.id == card.id }) { q.append(updated) }
        } else {
            reviewedCount += 1
        }
        revealed = false
        direction = Bool.random() ? .recallMeaning : .recallWord
        queue = q
    }

    private func intervalHint(_ g: ReviewGrade) -> String {
        guard var card = current else { return "" }
        StudyStore.apply(g, to: &card)
        if g == .again { return "soon" }
        return card.intervalDays <= 1 ? "1 day" : "\(card.intervalDays) days"
    }

    private func loadRecord() async {
        guard let word = current?.word else { records = []; return }
        let svc = DictionaryService.shared
        let sources = svc.sources
        let recs = await Task.detached(priority: .userInitiated) { [svc, sources, word] in
            svc.lookup(word, in: sources)
        }.value
        records = recs
    }
}

/// Compact, button-free definition rendering for the study card (so the meaning
/// can be shown with or without the headword). Honors the font-size setting.
private struct StudyDefinitionView: View {

    let record: DefinitionRecord
    /// When true, examples are hidden (used for the "guess the word" prompt so an
    /// example sentence doesn't give the answer away).
    var hideExamples: Bool = false
    @ObservedObject private var settings = AppSettings.shared
    private var s: CGFloat { CGFloat(settings.definitionFontScale) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !record.phonetics.isEmpty { phonetics }
            ForEach(record.sections) { section in
                if section.kind == .partOfSpeech { posBlock(section) }
            }
        }
    }

    private var phonetics: some View {
        HStack(spacing: 14) {
            ForEach(Array(record.phonetics.prefix(2).enumerated()), id: \.offset) { _, v in
                HStack(spacing: 5) {
                    if let d = v.dialect {
                        Text(d).font(Theme.ui(9, weight: .bold)).tracking(0.4).foregroundStyle(Theme.inkTertiary)
                    }
                    Text("/\(v.ipa)/").font(Theme.ui(13)).foregroundStyle(Theme.inkSecondary)
                }
            }
            Spacer()
        }
    }

    private func posBlock(_ section: DefinitionSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !section.text.isEmpty {
                Text(section.text)
                    .font(Theme.serif(14 * s, weight: .semibold).italic())
                    .foregroundStyle(Theme.accent)
            }
            ForEach(Array(section.senses.prefix(4).enumerated()), id: \.element.id) { idx, sense in
                senseRow(idx + 1, sense)
            }
        }
    }

    private func senseRow(_ n: Int, _ sense: DefinitionSection.Sense) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(sense.number ?? "\(n)")
                .font(Theme.ui(12, weight: .semibold)).foregroundStyle(Theme.accent)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.accentSoft))
            VStack(alignment: .leading, spacing: 6) {
                if let label = sense.categoryLabel, !label.isEmpty {
                    Text(label).font(Theme.ui(11, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                if !sense.translations.isEmpty {
                    Text(sense.translations.prefix(4).map(\.target).joined(separator: "  "))
                        .font(Theme.serif(16 * s, weight: .medium)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !sense.definition.isEmpty {
                    Text(sense.definition)
                        .font(Theme.serif(16 * s)).foregroundStyle(Theme.ink)
                        .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                }
                if !hideExamples, let ex = sense.examples.first {
                    Text("\u{25B8} \(ex)")
                        .font(Theme.serif(14 * s).italic()).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A fresh study window each time it's opened, so the session reloads what's due.
@MainActor
final class StudyWindowController {

    static let shared = StudyWindowController()
    private var window: NSWindow?

    func show() {
        window?.close()
        let win = LexiconWindows.paper(StudyView(), title: "Lexicon Study")
        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
}
