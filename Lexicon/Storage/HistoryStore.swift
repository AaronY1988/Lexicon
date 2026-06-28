//
//  HistoryStore.swift
//  Lexicon
//
//  Tracks recently-looked-up words and starred favorites. Persists to a JSON
//  file in ~/Library/Application Support/Lexicon/ so it survives launches.
//

import Foundation
import Combine

struct HistoryEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let word: String
    let lookedUpAt: Date
    var isFavorite: Bool

    init(word: String, lookedUpAt: Date = Date(), isFavorite: Bool = false) {
        self.id = UUID()
        self.word = word
        self.lookedUpAt = lookedUpAt
        self.isFavorite = isFavorite
    }
}

@MainActor
final class HistoryStore: ObservableObject {

    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []

    private let maxEntries = 200
    private let fileURL: URL

    private init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory,
                                      in: .userDomainMask,
                                      appropriateFor: nil,
                                      create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("Lexicon", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("history.json")
        load()
    }

    // MARK: - Public

    var recent: [HistoryEntry] {
        entries.sorted { $0.lookedUpAt > $1.lookedUpAt }
    }

    var favorites: [HistoryEntry] {
        entries.filter(\.isFavorite).sorted { $0.lookedUpAt > $1.lookedUpAt }
    }

    func record(_ word: String) {
        let normalized = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        if let idx = entries.firstIndex(where: { $0.word.caseInsensitiveCompare(normalized) == .orderedSame }) {
            // Bump existing entry to "now", keep favorite flag and casing.
            let existing = entries.remove(at: idx)
            entries.insert(HistoryEntry(word: existing.word,
                                        lookedUpAt: Date(),
                                        isFavorite: existing.isFavorite), at: 0)
        } else {
            entries.insert(HistoryEntry(word: normalized), at: 0)
        }
        trim()
        save()
    }

    func toggleFavorite(for word: String) {
        guard let idx = entries.firstIndex(where: { $0.word.caseInsensitiveCompare(word) == .orderedSame }) else {
            // No existing entry — add one and star it.
            entries.insert(HistoryEntry(word: word, isFavorite: true), at: 0)
            save()
            return
        }
        entries[idx].isFavorite.toggle()
        save()
    }

    func isFavorite(_ word: String) -> Bool {
        entries.first { $0.word.caseInsensitiveCompare(word) == .orderedSame }?.isFavorite ?? false
    }

    func clearHistory() {
        entries = entries.filter(\.isFavorite)
        save()
    }

    // MARK: - Persistence

    private func trim() {
        if entries.count <= maxEntries { return }
        // Keep all favorites plus the most-recent non-favorites up to the cap.
        let favs = entries.filter(\.isFavorite)
        let others = entries.filter { !$0.isFavorite }
            .sorted { $0.lookedUpAt > $1.lookedUpAt }
        let keptOthers = others.prefix(max(0, maxEntries - favs.count))
        entries = favs + keptOthers
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return }
        // One-time cleanup of legacy entries that stored a whole crammed
        // dictionary line as the "word" (e.g. "阿妈 āmā noun dialect mum").
        let cleaned = Self.sanitize(decoded)
        entries = cleaned
        let changed = cleaned.count != decoded.count
            || zip(cleaned, decoded).contains { $0.word != $1.word }
        if changed { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Malformed-entry cleanup

    /// Reduce clearly-malformed stored words — crammed "headword pinyin POS"
    /// lines, cross-reference arrows, trailing part-of-speech tokens — to just
    /// their leading headword, then drop the resulting duplicates. Conservative:
    /// ordinary single- or multi-word entries are left untouched.
    private static func sanitize(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        var out: [HistoryEntry] = []
        for entry in entries {
            let cleaned = cleanWord(entry.word)
            if let idx = out.firstIndex(where: {
                $0.word.caseInsensitiveCompare(cleaned) == .orderedSame
            }) {
                // Collapsed onto an existing word — keep the earlier (more
                // recent) entry, but carry over a favorite flag.
                if entry.isFavorite { out[idx].isFavorite = true }
                continue
            }
            if cleaned == entry.word {
                out.append(entry)
            } else {
                out.append(HistoryEntry(word: cleaned,
                                        lookedUpAt: entry.lookedUpAt,
                                        isFavorite: entry.isFavorite))
            }
        }
        return out
    }

    private static func cleanWord(_ word: String) -> String {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isMalformed(w) else { return w }
        return leadingHeadword(w)
    }

    /// Strong signals that a stored "word" is actually a crammed entry line.
    private static func isMalformed(_ w: String) -> Bool {
        if w.contains("→") { return true }
        let hasCJK = w.contains { $0.isCJKScalar }
        let hasLatin = w.contains { $0.isASCIILetter }
        // A real headword is a single script; pinyin makes these lines mixed.
        if hasCJK && hasLatin { return true }
        // A later token that is a part of speech, e.g. "AM abbreviation".
        let tokens = w.split(separator: " ").map { $0.lowercased() }
        if tokens.count > 1, tokens.dropFirst().contains(where: { posWords.contains($0) }) {
            return true
        }
        return false
    }

    private static let posWords: Set<String> = [
        "noun", "verb", "adjective", "adverb", "pronoun", "preposition",
        "conjunction", "interjection", "exclamation", "determiner", "article",
        "abbreviation", "prefix", "suffix", "contraction", "symbol", "phrase",
    ]

    private static func leadingHeadword(_ s0: String) -> String {
        let s = s0.trimmingCharacters(in: .whitespaces)
        guard let first = s.first else { return s }
        if first.isCJKScalar {
            var idx = s.startIndex
            while idx < s.endIndex, s[idx].isCJKScalar { idx = s.index(after: idx) }
            let head = String(s[s.startIndex..<idx]).trimmingCharacters(in: .whitespaces)
            return head.isEmpty ? s : head
        }
        if let space = s.firstIndex(of: " ") {
            return String(s[s.startIndex..<space])
        }
        return s
    }
}

// MARK: - Script helpers

private extension Character {
    /// True for common CJK ideograph ranges (good enough to tell Chinese
    /// headwords from Latin pinyin / part-of-speech tails).
    var isCJKScalar: Bool {
        unicodeScalars.contains { scalar in
            let v = scalar.value
            return (0x4E00...0x9FFF).contains(v) ||   // CJK Unified Ideographs
                   (0x3400...0x4DBF).contains(v) ||   // Extension A
                   (0x20000...0x2A6DF).contains(v) || // Extension B
                   (0xF900...0xFAFF).contains(v)      // Compatibility Ideographs
        }
    }

    var isASCIILetter: Bool { isASCII && isLetter }
}

// MARK: - Spaced-repetition study deck
//
// A small SM-2 (SuperMemo 2) scheduler — the algorithm behind Anki. Each word
// the user adds to study becomes a card with an easiness factor, an interval,
// and a due date. Grading a card on review (Again / Hard / Good / Easy) updates
// those and schedules the next review, so well-known words come back rarely and
// shaky ones come back soon. Persisted to study.json alongside history.

/// How well the user recalled a card. Maps to an SM-2 quality 0–5.
enum ReviewGrade: CaseIterable {
    case again, hard, good, easy
    var quality: Int {
        switch self {
        case .again: return 1
        case .hard:  return 3
        case .good:  return 4
        case .easy:  return 5
        }
    }
}

struct StudyCard: Identifiable, Codable, Hashable {
    /// One card per word (case-insensitive).
    var id: String { word.lowercased() }
    let word: String
    var ease: Double          // SM-2 easiness factor, ≥ 1.3
    var intervalDays: Int     // current scheduling interval
    var reps: Int             // consecutive successful repetitions
    var due: Date             // next time this card should be reviewed
    let addedAt: Date
    var lastReviewedAt: Date?

    init(word: String, now: Date = Date()) {
        self.word = word
        self.ease = 2.5
        self.intervalDays = 0
        self.reps = 0
        self.due = now            // brand-new cards are due immediately
        self.addedAt = now
        self.lastReviewedAt = nil
    }

    var isNew: Bool { reps == 0 && lastReviewedAt == nil }
}

@MainActor
final class StudyStore: ObservableObject {

    static let shared = StudyStore()

    @Published private(set) var cards: [StudyCard] = []

    private let fileURL: URL

    private init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory,
                                      in: .userDomainMask,
                                      appropriateFor: nil,
                                      create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("Lexicon", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("study.json")
        load()
    }

    // MARK: Membership

    func isStudying(_ word: String) -> Bool {
        cards.contains { $0.word.caseInsensitiveCompare(word) == .orderedSame }
    }

    func add(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !isStudying(w) else { return }
        cards.append(StudyCard(word: w))
        save()
    }

    func remove(_ word: String) {
        cards.removeAll { $0.word.caseInsensitiveCompare(word) == .orderedSame }
        save()
    }

    func toggle(_ word: String) {
        isStudying(word) ? remove(word) : add(word)
    }

    // MARK: Scheduling

    /// Cards due for review now, soonest first.
    var dueCards: [StudyCard] {
        let now = Date()
        return cards.filter { $0.due <= now }.sorted { $0.due < $1.due }
    }

    var dueCount: Int { dueCards.count }
    var newCount: Int { cards.filter(\.isNew).count }

    /// Apply a review grade to a word and reschedule (SM-2).
    func grade(_ word: String, _ grade: ReviewGrade) {
        guard let idx = cards.firstIndex(where: {
            $0.word.caseInsensitiveCompare(word) == .orderedSame
        }) else { return }
        var card = cards[idx]
        Self.apply(grade, to: &card)
        cards[idx] = card
        save()
    }

    /// The SM-2 update. `again` resets the card and makes it due again now (so it
    /// re-appears later in the same session); the others grow the interval and
    /// nudge the easiness factor.
    static func apply(_ grade: ReviewGrade, to card: inout StudyCard, now: Date = Date()) {
        let q = grade.quality
        if q < 3 {
            card.reps = 0
            card.intervalDays = 0
            card.due = now
        } else {
            switch card.reps {
            case 0:  card.intervalDays = 1
            case 1:  card.intervalDays = 6
            default: card.intervalDays = max(1, Int((Double(card.intervalDays) * card.ease).rounded()))
            }
            card.reps += 1
            let delta = 0.1 - Double(5 - q) * (0.08 + Double(5 - q) * 0.02)
            card.ease = max(1.3, card.ease + delta)
            let base = Calendar.current.startOfDay(for: now)
            card.due = Calendar.current.date(byAdding: .day, value: card.intervalDays, to: base) ?? now
        }
        card.lastReviewedAt = now
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([StudyCard].self, from: data)
        else { return }
        cards = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(cards) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
