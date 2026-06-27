//
//  DictionaryService.swift
//  Lexicon
//
//  Looks up words via Apple's private DictionaryServices framework, using the
//  plain-text path (`DCSCopyTextDefinition`) which returns a well-formatted
//  textual entry — same content Dictionary.app shows in its hover popover.
//
//  We then parse that plain text into sections for nicer rendering. This is
//  far more robust than trying to parse the raw XML body, whose schema varies
//  per dictionary and uses nested spans that are easy to mis-handle.
//

import Foundation
import CoreServices
import AppKit

/// Result of a suggestion query: the candidate words plus whether they are
/// spelling *corrections* (surfaced when the typed word matched nothing and
/// looks misspelled) rather than ordinary prefix matches. The UI uses the flag
/// to show a small "did you mean" header above the list.
struct WordSuggestions {
    var words: [String]
    var isCorrection: Bool
    static let empty = WordSuggestions(words: [], isCorrection: false)
}

@MainActor
final class DictionaryService: ObservableObject {

    static let shared = DictionaryService()

    /// All dictionaries the user has enabled in System Settings → Dictionary.
    @Published private(set) var sources: [DictionarySource] = []

    private init() {
        reloadSources()
    }

    // MARK: - Source discovery

    func reloadSources() {
        var found: [DictionarySource] = []

        // Active = enabled + ordered as in Dictionary.app preferences.
        if let active = DCSGetActiveDictionaries()?.takeUnretainedValue() as? [AnyObject] {
            for dict in active {
                let name = (DCSDictionaryGetName(dict)?.takeUnretainedValue() as String?) ?? "Dictionary"
                let id   = (DCSDictionaryGetShortName(dict)?.takeUnretainedValue() as String?) ?? UUID().uuidString
                found.append(.init(id: id, name: name, handle: dict))
            }
        }

        // Fall back to "all available" if for some reason the active list was empty.
        if found.isEmpty,
           let available = DCSCopyAvailableDictionaries()?.takeRetainedValue() as? [AnyObject] {
            for dict in available {
                let name = (DCSDictionaryGetName(dict)?.takeUnretainedValue() as String?) ?? "Dictionary"
                let id   = (DCSDictionaryGetShortName(dict)?.takeUnretainedValue() as String?) ?? UUID().uuidString
                found.append(.init(id: id, name: name, handle: dict))
            }
        }

        self.sources = found
    }

    // MARK: - Lookup

    /// Looks up `query` across every active dictionary and returns one
    /// `DefinitionRecord` per dictionary that had a hit. Safe to call from a
    /// background queue — caller must pass an explicit `sources` snapshot
    /// captured on the main actor (e.g. `dictionaryService.sources`).
    nonisolated func lookup(_ query: String,
                            in sources: [DictionarySource]) -> [DefinitionRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let range = CFRange(location: 0, length: trimmed.utf16.count)
        var results: [DefinitionRecord] = []

        // Per-dictionary plain-text lookup. We pass the dictionary handle so
        // each result is attributed to its source, allowing the tab UI to
        // switch between dictionaries.
        for source in sources {
            guard let textRef = DCSCopyTextDefinition(source.handle,
                                                      trimmed as CFString,
                                                      range)?.takeRetainedValue()
            else { continue }
            let text = (textRef as String).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let parsed = PlainTextDefinitionParser.parse(text, fallbackHeadword: trimmed)
            results.append(.init(headword: parsed.headword,
                                 source: source,
                                 sections: parsed.sections,
                                 phonetics: parsed.phonetics,
                                 rawXML: nil))
        }

        // If nothing matched per-dictionary, try the "all active dictionaries"
        // path — sometimes DCSCopyTextDefinition with a specific handle misses
        // matches that the global lookup finds.
        if results.isEmpty,
           let textRef = DCSCopyTextDefinition(nil, trimmed as CFString, range)?.takeRetainedValue() {
            let text = (textRef as String).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, let fallbackSource = sources.first {
                let parsed = PlainTextDefinitionParser.parse(text, fallbackHeadword: trimmed)
                results.append(.init(headword: parsed.headword,
                                     source: fallbackSource,
                                     sections: parsed.sections,
                                     phonetics: parsed.phonetics,
                                     rawXML: nil))
            }
        }

        return results
    }

    // MARK: - Short gloss (one-line preview)

    /// A compact, one-line meaning for `word`, suitable for the suggestion-rail
    /// preview. Returns the first sense's bilingual targets (e.g. "杰出的，优异的")
    /// when available, otherwise the first prose definition. `nil` when no
    /// dictionary had a usable entry. Safe to call off the main actor with a
    /// `sources` snapshot captured on the main actor.
    nonisolated func shortGloss(for word: String,
                                in sources: [DictionarySource]) -> String? {
        let records = lookup(word, in: sources)
        guard let record = records.first else { return nil }
        return Self.firstGloss(from: record)
    }

    private nonisolated static func firstGloss(from record: DefinitionRecord) -> String? {
        for section in record.sections where section.kind == .partOfSpeech {
            for sense in section.senses {
                if !sense.translations.isEmpty {
                    let joined = sense.translations.prefix(3)
                        .map(\.target)
                        .filter { !$0.isEmpty }
                        .joined(separator: "，")
                    if !joined.isEmpty { return joined }
                }
                let def = sense.definition.trimmingCharacters(in: .whitespacesAndNewlines)
                if !def.isEmpty { return def }
            }
        }
        // Fall back to the first non-empty plain / note section.
        for section in record.sections where section.kind != .partOfSpeech {
            let text = section.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    // MARK: - Suggestions (type-ahead matching words)

    /// Returns matching / partially-matching words for `prefix`, the way
    /// Dictionary.app populates its suggestion list as you type.
    ///
    /// Backed by `NSSpellChecker.completions(forPartialWordRange:)` — fast,
    /// bounded prefix completions from the system word list (this is what
    /// surfaces "rib, ribbon, rice, rich…" for "ri"). The correctly-spelled
    /// typed word itself is always included so a complete word the user typed
    /// is offered even if the completion list omitted it.
    ///
    /// Results are de-duplicated case-insensitively and ranked: exact match
    /// first, then words that *start with* what was typed, then words that
    /// merely *contain* it, then the rest — each tier alphabetical. Cheap
    /// enough to call on the main actor on every keystroke.
    func suggestions(for prefix: String, limit: Int = 40) -> WordSuggestions {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        var seen = Set<String>()
        var ordered: [String] = []

        func add(_ candidate: String) {
            let word = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, seen.insert(word.lowercased()).inserted else { return }
            ordered.append(word)
        }

        let checker = NSSpellChecker.shared
        let ns = trimmed as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        // Prefix completions from the system spell dictionary.
        if let completions = checker.completions(
                forPartialWordRange: fullRange,
                in: trimmed,
                language: nil,
                inSpellDocumentWithTag: 0) {
            for word in completions { add(word) }
        }

        // Always offer the typed word itself when it is spelled correctly,
        // even if it wasn't in the completion list.
        let misspelled = checker.checkSpelling(of: trimmed, startingAt: 0)
        if misspelled.location == NSNotFound { add(trimmed) }

        let lowerQuery = trimmed.lowercased()
        let ranked = ordered.sorted { lhs, rhs in
            Self.rankKey(lhs, lowerQuery: lowerQuery)
                < Self.rankKey(rhs, lowerQuery: lowerQuery)
        }
        if !ranked.isEmpty {
            return WordSuggestions(words: Array(ranked.prefix(limit)), isCorrection: false)
        }

        // Nothing matched as a prefix — the word is likely misspelled. Fall back
        // to the spell-checker's corrections, kept in its own likelihood order
        // (best guess first) rather than re-ranked. e.g. "seperate" → "separate".
        var corrections: [String] = []
        var seenC = Set<String>()
        if let guesses = checker.guesses(
                forWordRange: fullRange,
                in: trimmed,
                language: nil,
                inSpellDocumentWithTag: 0) {
            for guess in guesses {
                let word = guess.trimmingCharacters(in: .whitespacesAndNewlines)
                // Keep single, lookup-friendly words (the checker occasionally
                // returns phrases or hyphenated forms).
                guard !word.isEmpty, !word.contains(" ") else { continue }
                if seenC.insert(word.lowercased()).inserted { corrections.append(word) }
            }
        }
        return WordSuggestions(words: Array(corrections.prefix(limit)),
                               isCorrection: !corrections.isEmpty)
    }

    /// Sort key: lower tier sorts first. (0 exact, 1 prefix, 2 contains, 3 other),
    /// then alphabetically within a tier.
    private nonisolated static func rankKey(_ word: String,
                                            lowerQuery: String) -> (Int, String) {
        let lower = word.lowercased()
        let tier: Int
        if lower == lowerQuery { tier = 0 }
        else if lower.hasPrefix(lowerQuery) { tier = 1 }
        else if lower.contains(lowerQuery) { tier = 2 }
        else { tier = 3 }
        return (tier, lower)
    }
}

// MARK: - Plain text parser
//
// DCSCopyTextDefinition returns text in two broad shapes:
//
// (A) English-only dictionaries (e.g. New Oxford American Dictionary):
//
//   morn·ing | ˈmôrniNG |
//   noun
//   1 the period of time between midnight and noon, especially from sunrise to
//   noon: I'll see you tomorrow morning | a beautiful morning.
//     • the period from sunrise to the time of day when one stops work or
//     activity for lunch: she would do her chores in the morning.
//   2 [in singular] a particular period or stage: the morning of his career.
//
//   PHRASES
//   in the morning : tomorrow during the morning.
//
//   ORIGIN
//   Middle English mor(we)ning, from mor(we)n (see morn), patterned on evening.
//
// (B) Bilingual dictionaries (e.g. Oxford Chinese Dictionary) come in two
//     sub-shapes:
//
// (B1) Multi-POS, lettered headers — "morning":
//
//   morning | BrE 'mɔːnɪŋ, AmE 'mɔrnɪŋ |
//   A. noun (before noon) 上午 shàngwǔ; (first hours of the day) 早晨 zǎochen
//   ▶ a beautiful morning 一个美丽的早晨 ▶ this morning 今天上午 …
//   B. adjective attributive 上午的 shàngwǔ de <coffee, flight>
//   ▶ the morning papers 晨报 chénbào ▶ the fresh morning air 早晨清新的空气
//
// (B2) Single-POS, circled-number senses — "outstanding":
//
//   outstanding | BrE aʊtˈstændɪŋ, AmE ˌaʊtˈstændɪŋ |
//   adjective ① (excellent) 杰出的 jiéchū de <achievement>; 优异的 yōuyì de
//   <performance>; 出色的 chūsè de <talent>
//   ▶ an outstanding beauty 绝色美人 ② (prominent) 显著的 xiǎnzhù de
//   <landmark, characteristic>; 突出的 tūchū de <feature, example>
//   ③ (unresolved) 未偿还的 wèi chánghuán de <loan, debt>; 未付的 wèi fù de
//   <interest, bill>; 未完成的 wèi wánchéng de <work>; 未解决的 wèi jiějué de
//   <problem>
//   ▶ outstanding shares 已发行的股票
//
// Bilingual entries use `▶` as the only separator between examples, the
// triples `target pinyin <domains>` separated by `;` inside one sense, and
// optionally circled numbers (①②③ = U+2460..) as sense markers.
//
// We normalise all shapes into:
//  - headword (line 1, before the first `|`)
//  - phonetics (list of {dialect, ipa} pulled from the `| … |` block)
//  - part-of-speech blocks, each with one or more senses; bilingual senses
//    populate `translations` and `categoryLabel`, monolingual senses populate
//    `definition`
//  - section headings (PHRASES, DERIVATIVES, ORIGIN, …)

private enum PlainTextDefinitionParser {

    struct Result {
        let headword: String
        let phonetics: [PhoneticVariant]
        let sections: [DefinitionSection]
    }

    private static let partsOfSpeech: Set<String> = [
        "noun", "verb", "adjective", "adverb", "pronoun",
        "preposition", "conjunction", "interjection", "exclamation",
        "determiner", "article", "abbreviation", "prefix", "suffix",
        "plural noun", "auxiliary verb", "modal verb",
        "transitive verb", "intransitive verb", "phrasal verb",
        "combining form", "predeterminer", "ordinal number", "cardinal number",
        "contraction"
    ]

    /// Circled-number sense markers used by bilingual entries.
    /// Map "①" → "1", "②" → "2", … up to "⑳".
    private static let circledNumberMap: [Character: String] = {
        var m: [Character: String] = [:]
        // ① U+2460 .. ⑳ U+2473 → 1..20
        for i in 0..<20 {
            let scalar = UnicodeScalar(0x2460 + i)!
            m[Character(scalar)] = "\(i + 1)"
        }
        return m
    }()

    static func parse(_ text: String, fallbackHeadword: String) -> Result {
        // Bilingual dictionaries cram an entire entry onto one or two lines
        // and use `▶` as the only separator between examples. Insert a
        // newline before every example marker, every circled-number sense
        // marker, and every lettered POS header — regardless of preceding
        // whitespace — so the line-by-line walker below sees them cleanly.
        var normalised = text

        // ▶ U+25B6, ▸ U+25B8, ‣ U+2023, ⁌ U+204C
        for marker in ["\u{25B6}", "\u{25B8}", "\u{2023}", "\u{204C}"] {
            normalised = normalised.replacingOccurrences(of: marker,
                                                        with: "\n" + marker)
        }

        // ①②③ … ⑳ — break before each, but never at the very start of the
        // string (where one might already be at the head of a line).
        for (ch, _) in circledNumberMap {
            normalised = normalised.replacingOccurrences(of: String(ch),
                                                        with: "\n" + String(ch))
        }

        // Lettered POS labels "A. " through "G. " mid-line.
        for letter in ["A", "B", "C", "D", "E", "F", "G"] {
            normalised = normalised.replacingOccurrences(of: " \(letter). ",
                                                        with: "\n\(letter). ")
        }

        // Collapse duplicate newlines.
        while normalised.contains("\n\n") {
            normalised = normalised.replacingOccurrences(of: "\n\n", with: "\n")
        }
        let lines = normalised.components(separatedBy: .newlines)
        guard !lines.isEmpty else {
            return Result(headword: fallbackHeadword, phonetics: [], sections: [])
        }

        // ── Headword + phonetic from the first line(s) ──────────────────
        var headword = fallbackHeadword
        var phonetics: [PhoneticVariant] = []
        var bodyStartIndex = 0
        var leftoverFirstLine: String? = nil

        let firstLine = lines[0].trimmingCharacters(in: .whitespaces)
        if !firstLine.isEmpty {
            if firstLine.contains("|") {
                // Standard "headword | ipa | rest" shape.
                let parts = firstLine.split(separator: "|", maxSplits: 2,
                                            omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if let raw = parts.first, !raw.isEmpty {
                    // Strip the U+00B7 syllable dots (e.g. "morn·ing" → "morning")
                    headword = raw.replacingOccurrences(of: "\u{00B7}", with: "")
                }
                if parts.count >= 2, !parts[1].isEmpty {
                    phonetics = parsePhoneticBlock(parts[1])
                }
                if parts.count >= 3, !parts[2].isEmpty {
                    leftoverFirstLine = parts[2]
                }
            } else {
                // No phonetic delimiter — some bilingual entries cram
                // "headword pinyin POS …" onto one line. Keep only the leading
                // headword token (or run of CJK characters) so the headword and
                // recorded history stay clean; the remainder feeds the body so
                // the definition itself isn't swallowed.
                let (head, rest) = leadingHeadword(firstLine)
                headword = head.replacingOccurrences(of: "\u{00B7}", with: "")
                if !rest.isEmpty { leftoverFirstLine = rest }
            }
            bodyStartIndex = 1
        }

        // Body lines = remaining real lines, with any leftover from line 1.
        var bodyLines = Array(lines.dropFirst(bodyStartIndex))
        if let leftover = leftoverFirstLine {
            bodyLines.insert(leftover, at: 0)
        }

        // ── Body: walk lines, grouping by part-of-speech / section ──────
        var sections: [DefinitionSection] = []
        var currentPOS: String? = nil
        var currentSenses: [DefinitionSection.Sense] = []
        var inSpecialSection: String? = nil
        var specialBuffer: [String] = []

        func flushSpecial() {
            guard let heading = inSpecialSection else { return }
            let body = specialBuffer.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                let kind: DefinitionSection.Kind = (heading == "ORIGIN") ? .etymology : .note
                sections.append(.init(kind: kind, text: body, senses: []))
            }
            inSpecialSection = nil
            specialBuffer = []
        }

        func flushPOS() {
            flushSpecial()
            guard !currentSenses.isEmpty || currentPOS != nil else { return }
            sections.append(.init(kind: .partOfSpeech,
                                  text: currentPOS ?? "",
                                  senses: currentSenses))
            currentPOS = nil
            currentSenses = []
        }

        for raw in bodyLines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // ── Section heading? ALL CAPS, short. ───────────────────────
            if isSectionHeading(line) {
                flushPOS()
                inSpecialSection = line.uppercased()
                continue
            }

            if inSpecialSection != nil {
                specialBuffer.append(line)
                continue
            }

            // ── Bare part-of-speech line? ──────────────────────────────
            // Sometimes followed inline by a sense, e.g. "adjective ① (…)…".
            if let split = leadingBarePartOfSpeech(in: line) {
                flushPOS()
                currentPOS = split.pos
                let rest = split.rest.trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty {
                    appendSenseChunks(from: rest, into: &currentSenses)
                }
                continue
            }

            // ── Lettered POS header "A. noun (…) 上午 shàngwǔ" ─────────
            if let lettered = leadingLetteredPartOfSpeech(in: line) {
                flushPOS()
                currentPOS = lettered.pos
                let rest = lettered.rest.trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty {
                    appendSenseChunks(from: rest, into: &currentSenses)
                }
                continue
            }

            // ── Circled-number sense start, e.g. "① (excellent) 杰出的 …" ──
            if let first = line.first, let num = circledNumberMap[first] {
                let rest = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                let (label, body) = splitCategoryLabel(rest)
                let translations = parseBilingualTranslations(body)
                let definitionFallback = translations.isEmpty ? body : ""
                currentSenses.append(.init(number: num,
                                           categoryLabel: label,
                                           definition: definitionFallback,
                                           translations: translations,
                                           examples: []))
                continue
            }

            // ── Numeric sense "1 …", "2. …" ────────────────────────────
            if let (number, rest) = leadingSenseNumber(in: line) {
                let (def, examples) = splitDefinitionAndExamples(rest)
                currentSenses.append(.init(number: number,
                                           categoryLabel: nil,
                                           definition: def,
                                           translations: [],
                                           examples: examples))
                continue
            }

            // ── Example bullet "▶ …" — attach to most recent sense. ───
            if line.hasPrefix("\u{25B6}") || line.hasPrefix("\u{25B8}") ||
               line.hasPrefix("\u{2023}") || line.hasPrefix("\u{204C}") {
                let stripped = String(line.drop(while: {
                    $0 == "\u{25B6}" || $0 == "\u{25B8}" ||
                    $0 == "\u{2023}" || $0 == "\u{204C}" || $0 == " "
                }))
                if stripped.isEmpty { continue }
                if let prior = currentSenses.popLast() {
                    currentSenses.append(.init(number: prior.number,
                                               categoryLabel: prior.categoryLabel,
                                               definition: prior.definition,
                                               translations: prior.translations,
                                               examples: prior.examples + [stripped]))
                } else if currentPOS != nil {
                    currentSenses.append(.init(number: nil,
                                               categoryLabel: nil,
                                               definition: "",
                                               translations: [],
                                               examples: [stripped]))
                } else {
                    sections.append(.init(kind: .plain,
                                          text: "\u{25B6} " + stripped,
                                          senses: []))
                }
                continue
            }

            // ── Sub-bullet "• …" — attach to most recent sense. ────────
            if line.hasPrefix("\u{2022}") || line.hasPrefix("•") {
                let stripped = String(line.drop(while: { $0 == "•" || $0 == "\u{2022}" || $0 == " " }))
                let (def, examples) = splitDefinitionAndExamples(stripped)
                let prior = currentSenses.popLast()
                if let prior {
                    let combinedDef = prior.definition.isEmpty
                        ? "• " + def
                        : prior.definition + "\n• " + def
                    currentSenses.append(.init(number: prior.number,
                                               categoryLabel: prior.categoryLabel,
                                               definition: combinedDef,
                                               translations: prior.translations,
                                               examples: prior.examples + examples))
                } else {
                    currentSenses.append(.init(number: nil,
                                               categoryLabel: nil,
                                               definition: "• " + def,
                                               translations: [],
                                               examples: examples))
                }
                continue
            }

            // ── Continuation of previous sense (wrapped line). ────────
            if let prior = currentSenses.popLast() {
                // If the prior sense holds bilingual translation rows, try to
                // parse this continuation as more rows; otherwise treat as
                // continued prose.
                if !prior.translations.isEmpty {
                    let more = parseBilingualTranslations(line)
                    if !more.isEmpty {
                        currentSenses.append(.init(number: prior.number,
                                                   categoryLabel: prior.categoryLabel,
                                                   definition: prior.definition,
                                                   translations: prior.translations + more,
                                                   examples: prior.examples))
                        continue
                    }
                }
                let (extraDef, extraExamples) = splitDefinitionAndExamples(line)
                currentSenses.append(.init(number: prior.number,
                                           categoryLabel: prior.categoryLabel,
                                           definition: (prior.definition + " " + extraDef).trimmingCharacters(in: .whitespaces),
                                           translations: prior.translations,
                                           examples: prior.examples + extraExamples))
            } else if currentPOS != nil {
                appendSenseChunks(from: line, into: &currentSenses)
            } else {
                sections.append(.init(kind: .plain, text: line, senses: []))
            }
        }

        flushPOS()

        if sections.isEmpty {
            sections.append(.init(kind: .plain, text: text, senses: []))
        }

        return Result(headword: headword, phonetics: phonetics, sections: sections)
    }

    // MARK: Helpers

    /// Split a delimiter-less first line into `(headword, remainder)`. The
    /// headword is the leading run of CJK characters when the line starts with
    /// CJK (e.g. "阿妈 āmā noun …" → "阿妈"), otherwise the first whitespace-
    /// delimited token (e.g. "AM abbreviation" → "AM"). The remainder is fed
    /// back into the body so its senses/translations are still parsed.
    private static func leadingHeadword(_ line: String) -> (head: String, rest: String) {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard let first = s.first else { return (s, "") }

        if first.isCJKChar {
            var idx = s.startIndex
            while idx < s.endIndex, s[idx].isCJKChar {
                idx = s.index(after: idx)
            }
            let head = String(s[s.startIndex..<idx]).trimmingCharacters(in: .whitespaces)
            let rest = String(s[idx...]).trimmingCharacters(in: .whitespaces)
            return (head.isEmpty ? s : head, rest)
        }

        if let space = s.firstIndex(of: " ") {
            let head = String(s[s.startIndex..<space])
            let rest = String(s[s.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            return (head, rest)
        }
        return (s, "")
    }

    /// True if `line` looks like an ALL-CAPS section heading (PHRASES, ORIGIN, …).
    private static func isSectionHeading(_ line: String) -> Bool {
        guard line.count <= 24 else { return false }
        let letters = line.filter { $0.isLetter }
        guard letters.count >= 3 else { return false }
        return letters.allSatisfy { $0.isUppercase }
    }

    /// Append one or more senses derived from a chunk that may itself contain
    /// nested circled-number markers — e.g. an entire bilingual line of the
    /// form "(excellent) 杰出的 …; 出色的 … ② (prominent) 显著的 …".
    private static func appendSenseChunks(from chunk: String,
                                          into senses: inout [DefinitionSection.Sense]) {
        // The normaliser already split circled-number markers onto their own
        // lines, so this chunk usually only contains zero or one sense head.
        // Treat it as a single sense: extract any leading "(label)" gloss,
        // then either bilingual rows or plain prose.
        let (label, body) = splitCategoryLabel(chunk)
        let translations = parseBilingualTranslations(body)
        if !translations.isEmpty {
            senses.append(.init(number: nil,
                                categoryLabel: label,
                                definition: "",
                                translations: translations,
                                examples: []))
        } else {
            let (def, examples) = splitDefinitionAndExamples(body)
            senses.append(.init(number: nil,
                                categoryLabel: label,
                                definition: def,
                                translations: [],
                                examples: examples))
        }
    }

    /// Detects "noun …", "adjective …", "plural noun …" at the start of `line`.
    private static func leadingBarePartOfSpeech(in line: String) -> (pos: String, rest: String)? {
        let words = line.split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard !words.isEmpty else { return nil }
        // Try 3-, 2-, then 1-word POS phrases.
        for chunkSize in stride(from: min(3, words.count), through: 1, by: -1) {
            let candidate = words[0..<chunkSize].joined(separator: " ").lowercased()
            if partsOfSpeech.contains(candidate) {
                let rest = words.dropFirst(chunkSize).joined(separator: " ")
                return (candidate, rest)
            }
        }
        return nil
    }

    /// Detects the bilingual-dictionary header form "X. <pos>[ <modifier>]…".
    private static func leadingLetteredPartOfSpeech(in line: String) -> (pos: String, rest: String)? {
        guard line.count >= 4 else { return nil }
        var idx = line.startIndex
        guard line[idx].isLetter, line[idx].isUppercase else { return nil }
        idx = line.index(after: idx)
        guard idx < line.endIndex, line[idx] == "." else { return nil }
        idx = line.index(after: idx)
        guard idx < line.endIndex, line[idx] == " " else { return nil }
        idx = line.index(after: idx)
        let remainder = String(line[idx...])

        let words = remainder.split(separator: " ", omittingEmptySubsequences: true)
            .map { String($0) }
        guard !words.isEmpty else { return nil }

        for chunkSize in stride(from: min(3, words.count), through: 1, by: -1) {
            let candidate = words[0..<chunkSize]
                .joined(separator: " ")
                .lowercased()
            let modifiers: Set<String> = [
                "attributive", "predicative", "informal", "formal",
                "literary", "archaic", "vulgar", "dated", "historical",
                "transitive", "intransitive", "auxiliary"
            ]
            if partsOfSpeech.contains(candidate) {
                let rest = words.dropFirst(chunkSize)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                return (candidate, rest)
            }
            if chunkSize == 2,
               partsOfSpeech.contains(words[0].lowercased()),
               modifiers.contains(words[1].lowercased()) {
                let rest = words.dropFirst(2)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                return ("\(words[0].lowercased()) \(words[1].lowercased())", rest)
            }
        }

        for (i, w) in words.enumerated().prefix(3) where i > 0 {
            if partsOfSpeech.contains(w.lowercased()) {
                let pos = w.lowercased()
                var remaining = Array(words.prefix(i))
                remaining.append(contentsOf: words.dropFirst(i + 1))
                let rest = remaining
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                return (pos, rest)
            }
        }

        return nil
    }

    /// Numeric sense head: "1 ", "2. ", "10 " etc.
    private static func leadingSenseNumber(in line: String) -> (String, String)? {
        var idx = line.startIndex
        while idx < line.endIndex, line[idx].isNumber {
            idx = line.index(after: idx)
        }
        guard idx > line.startIndex else { return nil }
        let number = String(line[line.startIndex..<idx])
        var rest = String(line[idx...])
        if rest.hasPrefix(".") { rest.removeFirst() }
        guard rest.hasPrefix(" ") else { return nil }
        return (number, rest.trimmingCharacters(in: .whitespaces))
    }

    /// Apple plain-text monolingual sense:
    ///   "the period …: I'll see you tomorrow morning | a beautiful morning."
    /// The colon separates definition from one-or-more examples (joined by "|").
    private static func splitDefinitionAndExamples(_ text: String) -> (String, [String]) {
        guard let colonIdx = text.firstIndex(of: ":") else {
            return (text, [])
        }
        let def = text[text.startIndex..<colonIdx].trimmingCharacters(in: .whitespaces)
        let after = text[text.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
        let examples = after.components(separatedBy: " | ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (def, examples)
    }

    /// Extracts a leading parenthetical "(label)" from a bilingual sense body.
    /// Returns the label without parens and the remaining body.
    private static func splitCategoryLabel(_ text: String) -> (label: String?, body: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("("),
              let close = trimmed.firstIndex(of: ")") else {
            return (nil, trimmed)
        }
        let labelStart = trimmed.index(after: trimmed.startIndex)
        let label = String(trimmed[labelStart..<close]).trimmingCharacters(in: .whitespaces)
        let body = String(trimmed[trimmed.index(after: close)...])
            .trimmingCharacters(in: .whitespaces)
        return (label.isEmpty ? nil : label, body)
    }

    /// Splits a bilingual sense body into structured translation rows.
    /// Expected shape, separated by `;`:
    ///   `汉字 [pinyin] [<domain1, domain2>]`
    /// Returns an empty array if no row contains a CJK target (i.e. the body
    /// is plain English prose, not a bilingual gloss).
    private static func parseBilingualTranslations(_ body: String) -> [DefinitionSection.Translation] {
        let pieces = body.components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !pieces.isEmpty else { return [] }

        var rows: [DefinitionSection.Translation] = []
        var sawCJK = false

        for piece in pieces {
            // Pull out trailing <domain1, domain2> if present.
            var rest = piece
            var domains: [String] = []
            if let openIdx = rest.lastIndex(of: "<"),
               let closeIdx = rest.lastIndex(of: ">"),
               openIdx < closeIdx {
                let inner = String(rest[rest.index(after: openIdx)..<closeIdx])
                domains = inner.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                rest = String(rest[rest.startIndex..<openIdx])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // Pull off a category label like "(unresolved)" if it leads this
            // piece. Some entries repeat the label per piece; we attach it
            // back as part of the target so it doesn't get dropped silently.
            let (innerLabel, innerBody) = splitCategoryLabel(rest)
            var workingBody = innerBody

            // Target = the run of CJK (+ trailing 的/地/性 etc.) at the start.
            // Pronunciation = the remaining Latin/pinyin tail.
            let (target, pronunciation) = splitTargetAndPronunciation(workingBody)
            workingBody = target
            if target.contains(where: { $0.isCJKChar }) { sawCJK = true }

            // If a leading label was present, prepend it back onto the target
            // visually so the renderer still shows it (rare edge case).
            let displayedTarget: String
            if let innerLabel {
                displayedTarget = "(\(innerLabel)) \(target)"
            } else {
                displayedTarget = target
            }

            // Skip empties (mostly from stray double semicolons).
            if displayedTarget.isEmpty && pronunciation == nil && domains.isEmpty {
                continue
            }
            rows.append(.init(target: displayedTarget,
                              pronunciation: pronunciation,
                              domains: domains))
        }

        return sawCJK ? rows : []
    }

    /// Given "杰出的 jiéchū de", returns ("杰出的", "jiéchū de").
    /// Given "杰出的", returns ("杰出的", nil).
    /// Given "outstanding shares", returns ("outstanding shares", nil).
    private static func splitTargetAndPronunciation(_ s: String) -> (String, String?) {
        // Walk from the end while we're seeing Latin / space / IPA-ish chars,
        // then a space, then CJK. That space is the split point.
        let chars = Array(s)
        guard !chars.isEmpty else { return ("", nil) }

        // Find the last CJK character; pronunciation, if present, lies after
        // it (possibly preceded by a separating space).
        var lastCJK: Int? = nil
        for (i, c) in chars.enumerated() where c.isCJKChar {
            lastCJK = i
        }
        guard let last = lastCJK else { return (s, nil) }

        // The pronunciation tail starts at the first non-CJK, non-space char
        // after `last`.
        var i = last + 1
        // Skip CJK-attached suffix chars (None expected; CJK is contiguous in
        // practice but we tolerate spaces between CJK + pronunciation).
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        if i >= chars.count {
            return (String(chars[0...last]).trimmingCharacters(in: .whitespaces), nil)
        }
        // If the tail starts with another CJK character (very rare), bail out.
        if chars[i].isCJKChar {
            return (s.trimmingCharacters(in: .whitespaces), nil)
        }
        let target = String(chars[0...last]).trimmingCharacters(in: .whitespaces)
        let pron = String(chars[i..<chars.count]).trimmingCharacters(in: .whitespaces)
        return (target, pron.isEmpty ? nil : pron)
    }

    /// Parses a phonetic block like "BrE aʊtˈstændɪŋ, AmE ˌaʊtˈstændɪŋ" or
    /// just "ˈmôrniNG" into one or more `(dialect, ipa)` pairs.
    private static func parsePhoneticBlock(_ raw: String) -> [PhoneticVariant] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        // Split on commas — bilingual entries use ", " between dialect variants.
        let pieces = trimmed.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var out: [PhoneticVariant] = []
        for piece in pieces {
            // Detect a leading dialect tag of 2–4 ASCII letters followed by a
            // space (e.g. "BrE ", "AmE ", "US ", "UK ").
            let words = piece.split(separator: " ", maxSplits: 1,
                                    omittingEmptySubsequences: true)
                .map { String($0) }
            if words.count == 2,
               looksLikeDialectTag(words[0]) {
                out.append(.init(dialect: words[0], ipa: words[1]))
            } else {
                out.append(.init(dialect: nil, ipa: piece))
            }
        }
        return out
    }

    private static func looksLikeDialectTag(_ s: String) -> Bool {
        guard (2...5).contains(s.count) else { return false }
        // Must be all ASCII letters, with at least one uppercase letter.
        var sawUpper = false
        for ch in s {
            guard ch.isASCII, ch.isLetter else { return false }
            if ch.isUppercase { sawUpper = true }
        }
        return sawUpper
    }
}

// MARK: - CJK helper

private extension Character {
    /// True for CJK Unified Ideographs (the common ranges; good enough for
    /// distinguishing target script from pinyin tail).
    var isCJKChar: Bool {
        for scalar in unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) ||      // CJK Unified Ideographs
               (0x3400...0x4DBF).contains(v) ||      // CJK Extension A
               (0x20000...0x2A6DF).contains(v) ||    // CJK Extension B
               (0x3000...0x303F).contains(v) ||      // CJK punctuation
               (0xFF00...0xFFEF).contains(v) {       // Halfwidth/Fullwidth
                return true
            }
        }
        return false
    }
}
