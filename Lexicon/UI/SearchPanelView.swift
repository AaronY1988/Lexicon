//
//  SearchPanelView.swift
//  Lexicon
//
//  Top-level SwiftUI view that lives inside the floating panel.
//  Layout:
//    ┌─────────────────────────────────────────┐
//    │  🔍  search field          ⌫            │  ← header
//    ├──────────────┬──────────────────────────┤
//    │   sidebar    │   active definition      │
//    │ (history/    │   - headword + phonetic  │
//    │  favorites)  │   - dictionary tabs      │
//    │              │   - sections/senses      │
//    └──────────────┴──────────────────────────┘
//

import SwiftUI
import Combine

/// Drives search input → debounced lookup → results.
@MainActor
final class SearchViewModel: ObservableObject {

    @Published var query: String = ""
    @Published private(set) var results: [DefinitionRecord] = []
    @Published var activeSourceID: String? = nil
    @Published private(set) var isLoading: Bool = false

    /// Live type-ahead matches — words that match or partly match `query`.
    @Published private(set) var suggestions: [String] = []
    /// `true` when `suggestions` are spelling corrections for a misspelled word
    /// (no prefix match was found) rather than ordinary matches. Drives the
    /// "did you mean" header in the match list.
    @Published private(set) var suggestionsAreCorrections: Bool = false
    /// Index into `suggestions` of the word whose definition is on screen.
    /// `-1` when there is nothing highlighted.
    @Published var highlightedIndex: Int = -1
    /// The word whose definition is currently displayed. May differ from the
    /// raw `query` while the user browses the suggestion list with arrow keys.
    @Published private(set) var shownWord: String = ""

    /// One-line meaning previews for the words in `suggestions`, keyed by the
    /// lowercased word. An empty string marks "looked up, no gloss found" so we
    /// don't retry it. Filled lazily in the background for the visible rows.
    @Published private(set) var glosses: [String: String] = [:]

    private var cancellables = Set<AnyCancellable>()
    private let dictionaryService = DictionaryService.shared
    private let historyStore = HistoryStore.shared

    /// Monotonic token so a slow background lookup can't clobber the result of
    /// a newer one the user triggered by typing or arrowing.
    private var lookupToken = 0
    /// The in-flight definition lookup, cancelled whenever a newer one starts
    /// so rapid typing can't pile up background work (which froze the UI).
    private var lookupTask: Task<Void, Never>?
    /// The in-flight gloss-preview fetch for the visible suggestion rows.
    private var glossTask: Task<Void, Never>?

    init() {
        // Debounce typed input; cancel in-flight lookups when a new keystroke lands.
        $query
            .removeDuplicates()
            .debounce(for: .milliseconds(90), scheduler: DispatchQueue.main)
            .sink { [weak self] q in self?.refresh(q) }
            .store(in: &cancellables)
    }

    func focusForNewLookup() {
        // No-op: SearchField auto-focuses. We could pre-select text here later.
    }

    /// Called when the global hotkey was triggered with a selection seed.
    func queryFromExternalSeed(_ seed: String) {
        let cleaned = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        query = cleaned
    }

    /// The dictionary we prefer to surface first when it has a hit: the Oxford
    /// English–Chinese / Chinese–English bilingual dictionary (牛津英汉汉英词典).
    /// Falls back to the first available result when that dictionary didn't
    /// match (or isn't installed).
    private func preferredDefault(in records: [DefinitionRecord]) -> DefinitionRecord? {
        if let oxfordChinese = records.first(where: { isPreferredSource($0.source) }) {
            return oxfordChinese
        }
        return records.first
    }

    private func isPreferredSource(_ source: DictionarySource) -> Bool {
        let name = source.name
        // Match the dictionary's Chinese display name, or an English-named
        // variant ("Oxford Chinese Dictionary", "Oxford English-Chinese …").
        if name.contains("牛津") && (name.contains("英汉") || name.contains("汉英")) {
            return true
        }
        let lower = name.lowercased()
        return lower.contains("oxford") && lower.contains("chinese")
    }

    // MARK: - Typing → suggestions + definition

    /// Called on every (debounced) keystroke. Refreshes the suggestion list
    /// (cheap, synchronous) and kicks off the definition lookup for the
    /// best-matching word (background).
    private func refresh(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lookupTask?.cancel()
            glossTask?.cancel()
            suggestions = []
            suggestionsAreCorrections = false
            highlightedIndex = -1
            results = []
            shownWord = ""
            activeSourceID = nil
            isLoading = false
            return
        }

        // 1. Suggestion list — fast and bounded, so it's fine on the main actor
        //    and the list updates instantly as you type. Falls back to spelling
        //    corrections when nothing matches as a prefix.
        let result = dictionaryService.suggestions(for: trimmed)
        let matches = result.words
        suggestions = matches
        suggestionsAreCorrections = result.isCorrection
        // Fetch one-line previews for the rows the user can actually see.
        loadGlosses(for: Array(matches.prefix(14)))
        // Prefer an exact hit on what was typed; otherwise the top match.
        let target = matches.first(where: {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }) ?? matches.first ?? trimmed
        highlightedIndex = matches.firstIndex {
            $0.caseInsensitiveCompare(target) == .orderedSame
        } ?? (matches.isEmpty ? -1 : 0)

        // 2. Definition for the chosen word — in the background. Record history
        //    only when the user typed a full real word (target == typed).
        showDefinition(for: target,
                       record: target.caseInsensitiveCompare(trimmed) == .orderedSame)
    }

    // MARK: - Suggestion navigation

    /// Move the highlight by `delta` rows and show that word's definition.
    func moveHighlight(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        let base = highlightedIndex < 0 ? 0 : highlightedIndex
        let next = max(0, min(suggestions.count - 1, base + delta))
        guard next != highlightedIndex else { return }
        highlightedIndex = next
        showDefinition(for: suggestions[next])
    }

    /// Pick a suggestion by index (e.g. on click) and record it to history.
    func selectSuggestion(at index: Int) {
        guard suggestions.indices.contains(index) else { return }
        highlightedIndex = index
        showDefinition(for: suggestions[index], record: true)
    }

    /// Return / double-action: commit the highlighted suggestion (or raw query).
    func commitHighlighted() {
        if suggestions.indices.contains(highlightedIndex) {
            showDefinition(for: suggestions[highlightedIndex], record: true)
        } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showDefinition(for: query, record: true)
        }
    }

    /// Look up `word` and show its definition without disturbing the typed query.
    private func showDefinition(for word: String, record: Bool = false) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isLoading = true
        lookupToken &+= 1
        let token = lookupToken
        let sourcesSnapshot = dictionaryService.sources
        // Cancel any in-flight lookup so fast typing can't pile up work.
        lookupTask?.cancel()
        lookupTask = Task.detached(priority: .userInitiated) { [trimmed, dictionaryService] in
            if Task.isCancelled { return }
            let found = dictionaryService.lookup(trimmed, in: sourcesSnapshot)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self, token == self.lookupToken else { return }
                self.results = found
                self.shownWord = trimmed
                self.activeSourceID = self.preferredDefault(in: found)?.source.id
                self.isLoading = false
                if record, let preferred = self.preferredDefault(in: found) {
                    HistoryStore.shared.record(preferred.headword)
                }
            }
        }
    }

    // MARK: - Gloss previews

    /// A one-line meaning for `word`, or `nil` if none is known yet / exists.
    func gloss(for word: String) -> String? {
        guard let g = glosses[word.lowercased()], !g.isEmpty else { return nil }
        return g
    }

    /// Fetch glosses for `words` not already cached, one at a time on a utility
    /// queue, updating the cache as each resolves. Cancelled when the suggestion
    /// list changes so we never gloss stale rows.
    private func loadGlosses(for words: [String]) {
        let needed = words.filter { glosses[$0.lowercased()] == nil }
        guard !needed.isEmpty else { return }
        let sourcesSnapshot = dictionaryService.sources
        glossTask?.cancel()
        glossTask = Task.detached(priority: .utility) { [needed, sourcesSnapshot, dictionaryService] in
            for word in needed {
                if Task.isCancelled { return }
                let gloss = dictionaryService.shortGloss(for: word, in: sourcesSnapshot)
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    // Store "" when nothing was found so we don't refetch it.
                    self?.glosses[word.lowercased()] = gloss ?? ""
                }
            }
        }
    }
}

struct SearchPanelView: View {

    @ObservedObject var viewModel: SearchViewModel
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var settings = AppSettings.shared
    var onClose: () -> Void

    private let cornerRadius: CGFloat = 18

    var body: some View {
        ZStack {
            panelBackground

            VStack(spacing: 0) {
                header
                Rectangle().fill(Theme.line).frame(height: 1)
                activeDefinitionPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                recentsBar
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(borderStroke)
    }

    // MARK: Background

    /// Warm paper over a whisper of the system blur. The frosted material still
    /// reads at the very edges, but a high-opacity paper fill on top turns the
    /// surface into a calm reading page rather than cold glass.
    private var panelBackground: some View {
        ZStack {
            VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
            Theme.paper.opacity(0.92)
                .ignoresSafeArea()
        }
    }

    /// A single warm hairline edge — no gradient, no glow.
    private var borderStroke: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(Theme.line, lineWidth: 1)
            .allowsHitTesting(false)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accent.opacity(0.85))
            SearchField(text: $viewModel.query,
                        placeholder: "Look up a word",
                        fontSize: 22,
                        serif: true,
                        textColor: Theme.inkNS,
                        onSubmit: { viewModel.commitHighlighted() },
                        onCancel: onClose,
                        onArrowUp: { viewModel.moveHighlight(by: -1) },
                        onArrowDown: { viewModel.moveHighlight(by: 1) })
                .frame(height: 34)
            if viewModel.query.isEmpty {
                HStack(spacing: 4) {
                    ForEach(settings.hotKey.capTokens, id: \.self) { keycap($0) }
                }
            } else {
                Button {
                    viewModel.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.inkTertiary)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    /// A small keyboard cap, used in the header and the empty state.
    private func keycap(_ key: String) -> some View {
        Text(key)
            .font(Theme.ui(12, weight: .medium))
            .foregroundStyle(Theme.inkSecondary)
            .frame(minWidth: 20, minHeight: 20)
            .padding(.horizontal, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.chip)
            )
    }

    // MARK: Recents bar

    /// A quiet row pinned to the foot of the panel while a lookup is active:
    /// recent words on the left, a faint keyboard-navigation hint on the right.
    /// Hidden in the empty state, which surfaces its own recents/favorites.
    @ViewBuilder
    private var recentsBar: some View {
        let recents = Array(history.recent.prefix(7))
        let navigable = !viewModel.suggestions.isEmpty
        let isSearching = !viewModel.query.trimmingCharacters(in: .whitespaces).isEmpty
        if isSearching && (!recents.isEmpty || navigable) {
            VStack(spacing: 0) {
                Rectangle().fill(Theme.line).frame(height: 1)
                HStack(spacing: 10) {
                    if !recents.isEmpty {
                        Text("RECENT")
                            .font(Theme.ui(10, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(Theme.inkTertiary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(recents) { entry in
                                    Button {
                                        viewModel.query = entry.word
                                    } label: {
                                        Text(entry.word)
                                            .font(Theme.serif(14))
                                            .foregroundStyle(Theme.inkSecondary)
                                            .lineLimit(1)
                                            .padding(.horizontal, 13)
                                            .padding(.vertical, 5)
                                            .background(Capsule().fill(Theme.chip))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Look up \u{201C}\(entry.word)\u{201D}")
                                }
                            }
                            .padding(.trailing, 4)
                        }
                    } else {
                        Spacer(minLength: 0)
                    }

                    if navigable {
                        keyHints
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
    }

    /// Faint keycap hints teaching the keyboard-first flow.
    private var keyHints: some View {
        HStack(spacing: 5) {
            keycap("\u{2191}\u{2193}")
            Text("navigate")
                .font(Theme.ui(11))
                .foregroundStyle(Theme.inkTertiary)
            keycap("\u{23CE}")
            Text("open")
                .font(Theme.ui(11))
                .foregroundStyle(Theme.inkTertiary)
        }
        .fixedSize()
    }

    // MARK: Active definition pane

    @ViewBuilder
    private var activeDefinitionPane: some View {
        if viewModel.query.trimmingCharacters(in: .whitespaces).isEmpty {
            emptyState
        } else if viewModel.suggestions.isEmpty && !viewModel.isLoading {
            noMatchState
        } else {
            // Two-pane, Dictionary.app style: a live list of matching words on
            // the left, the highlighted word's definition on the right.
            HStack(spacing: 0) {
                matchListPane
                    .frame(width: 208)
                Rectangle().fill(Theme.line).frame(width: 1)
                definitionPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Left rail: the scrollable list of matching / partially-matching words.
    private var matchListPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if viewModel.suggestionsAreCorrections {
                        didYouMeanHeader
                    }
                    ForEach(Array(viewModel.suggestions.indices), id: \.self) { index in
                        matchRow(viewModel.suggestions[index],
                                 isSelected: index == viewModel.highlightedIndex)
                            .id(index)
                            .onTapGesture { viewModel.selectSuggestion(at: index) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            }
            .onChange(of: viewModel.highlightedIndex) { newValue in
                guard newValue >= 0 else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    /// Small header shown atop the rail when the list holds spelling corrections.
    private var didYouMeanHeader: some View {
        HStack(spacing: 5) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
            Text("DID YOU MEAN")
                .font(Theme.ui(10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.inkTertiary)
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private func matchRow(_ word: String, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(word)
                .font(Theme.serif(15, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.accent : Theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            if let gloss = viewModel.gloss(for: word) {
                Text(gloss)
                    .font(Theme.ui(11))
                    .foregroundStyle(isSelected ? Theme.accent.opacity(0.7) : Theme.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Theme.accentSoft : Color.clear)
        )
        .contentShape(Rectangle())
    }

    /// Right pane: the definition of the highlighted word.
    @ViewBuilder
    private var definitionPane: some View {
        if let active = currentRecord {
            VStack(spacing: 0) {
                if viewModel.results.count > 1 {
                    DictionaryTabs(records: viewModel.results,
                                   activeID: $viewModel.activeSourceID)
                        .padding(.horizontal, 24)
                        .padding(.top, 14)
                        .padding(.bottom, 6)
                }
                ScrollView {
                    DefinitionView(record: active)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else if viewModel.isLoading {
            // First lookup for this word is still resolving — show a calm
            // shimmer placeholder instead of a blank flash.
            definitionSkeleton
        } else {
            // A word is highlighted in the list but no dictionary had a full
            // entry for it (rare — e.g. an inflected index form).
            VStack(spacing: 8) {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.inkTertiary)
                Text("No entry for \u{201C}\(viewModel.shownWord)\u{201D}")
                    .font(Theme.ui(13))
                    .foregroundStyle(Theme.inkSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A skeletal preview of a definition — a headword bar, a phonetic line and
    /// a few sense rows — that shimmers gently while the real entry loads.
    private var definitionSkeleton: some View {
        VStack(alignment: .leading, spacing: 18) {
            SkeletonBlock(width: 200, height: 30)
            SkeletonBlock(width: 132, height: 13)
            ForEach(0..<3, id: \.self) { _ in
                HStack(alignment: .top, spacing: 10) {
                    SkeletonBlock(width: 21, height: 21, cornerRadius: 7)
                    VStack(alignment: .leading, spacing: 7) {
                        SkeletonBlock(height: 14)
                        SkeletonBlock(width: 220, height: 14)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var currentRecord: DefinitionRecord? {
        if let id = viewModel.activeSourceID,
           let match = viewModel.results.first(where: { $0.source.id == id }) {
            return match
        }
        return viewModel.results.first
    }

    private var emptyState: some View {
        EmptyStateView(onPick: { viewModel.query = $0 })
    }

    private var noMatchState: some View {
        VStack(spacing: 10) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(Theme.inkTertiary)
            Text("No definition for \u{201C}\(viewModel.query)\u{201D}")
                .font(Theme.ui(15, weight: .medium))
                .foregroundStyle(Theme.ink)
            Text("Try a different spelling, or enable more dictionaries in Dictionary.app preferences.")
                .multilineTextAlignment(.center)
                .font(Theme.ui(12))
                .foregroundStyle(Theme.inkSecondary)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Word of the day

/// A tiny curated rotation of evocative words. The pick is deterministic per
/// calendar day, so the empty state shows the same "word of the day" all day
/// and changes at midnight — no storage needed.
enum WordOfTheDay {
    static let words: [String] = [
        "serendipity", "ephemeral", "petrichor", "mellifluous", "luminous",
        "solace", "reverie", "ineffable", "halcyon", "quixotic",
        "eloquent", "nostalgia", "ethereal", "wanderlust", "lucid",
        "epiphany", "resilience", "sonorous", "tranquil", "vivid",
        "aurora", "zenith", "cadence", "effervescent", "gossamer",
        "labyrinth", "nebula", "oasis", "panacea", "quintessence",
    ]

    static func today(_ date: Date = Date()) -> String {
        guard !words.isEmpty else { return "serendipity" }
        let day = Calendar.current.ordinality(of: .day, in: .era, for: date) ?? 0
        return words[((day % words.count) + words.count) % words.count]
    }
}

// MARK: - Empty state

/// The panel's resting face when nothing has been typed: the wordmark, a
/// tappable "word of the day", and a quick row of favorites (or recents).
private struct EmptyStateView: View {

    @ObservedObject private var history = HistoryStore.shared
    var onPick: (String) -> Void

    @State private var wotd: String = WordOfTheDay.today()
    @State private var wotdGloss: String? = nil

    var body: some View {
        // Scrolls when the content is taller than the panel (e.g. lots of wide
        // recent entries) so the header above is never pushed off-screen; stays
        // vertically centered when it fits.
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 18) {
                    VStack(spacing: 8) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 30, weight: .regular))
                            .foregroundStyle(Theme.accent)
                        Text("Lexicon")
                            .font(Theme.serif(24, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                    }

                    wordOfTheDayCard
                    chipSection
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(minHeight: geo.size.height, alignment: .center)
            }
        }
        .task(id: wotd) {
            let service = DictionaryService.shared
            let sources = service.sources
            let word = wotd
            let gloss = await Task.detached(priority: .utility) { [service, sources, word] in
                service.shortGloss(for: word, in: sources)
            }.value
            wotdGloss = gloss
        }
    }

    private var wordOfTheDayCard: some View {
        Button {
            onPick(wotd)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text("WORD OF THE DAY")
                    .font(Theme.ui(10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.inkTertiary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(wotd)
                        .font(Theme.serif(22, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                if let gloss = wotdGloss, !gloss.isEmpty {
                    Text(gloss)
                        .font(Theme.serif(14))
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.paperRaised)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 360)
        .help("Look up \u{201C}\(wotd)\u{201D}")
    }

    @ViewBuilder
    private var chipSection: some View {
        let favorites = Array(history.favorites.prefix(6))
        let recents = Array(history.recent.prefix(6))
        if !favorites.isEmpty {
            labeledChips("FAVORITES", entries: favorites)
        } else if !recents.isEmpty {
            labeledChips("RECENT", entries: recents)
        }
    }

    private func labeledChips(_ title: String, entries: [HistoryEntry]) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(Theme.ui(10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.inkTertiary)
            FlowHStack(spacing: 8, lineSpacing: 8) {
                ForEach(entries) { entry in
                    Button {
                        onPick(entry.word)
                    } label: {
                        Text(entry.word)
                            .font(Theme.serif(14))
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(1)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Theme.chip))
                    }
                    .buttonStyle(.plain)
                    .help("Look up \u{201C}\(entry.word)\u{201D}")
                }
            }
            .frame(maxWidth: 380)
        }
    }
}

// MARK: - Skeleton

/// A single rounded placeholder bar with a soft shimmer sweep. Adaptive: the
/// sweep uses `Theme.ink` at low opacity, so it darkens over light paper and
/// lightens over the dark "Lamplight" surface.
private struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14
    var cornerRadius: CGFloat = 6

    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.paperRaised)
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
            .frame(height: height)
            .overlay {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.clear, Theme.ink.opacity(0.06), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width)
                        .offset(x: phase * geo.size.width)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onAppear {
                phase = -1
                withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}
