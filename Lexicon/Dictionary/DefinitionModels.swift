//
//  DefinitionModels.swift
//  Lexicon
//

import Foundation

/// One installed/active dictionary (e.g. New Oxford American Dictionary).
struct DictionarySource: Identifiable, Hashable {
    let id: String           // short name, e.g. "com.apple.dictionary.NOAD"
    let name: String         // display name
    /// Underlying CFTypeRef so we can pass it back to DictionaryServices.
    let handle: AnyObject

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// One matching record returned for a query (a headword in a specific dictionary).
struct DefinitionRecord: Identifiable {
    let id = UUID()
    let headword: String
    let source: DictionarySource
    /// Parsed, display-ready sections (part of speech, senses, etymology, …).
    let sections: [DefinitionSection]
    /// Optional phonetic / IPA pulled from the XML, if present.
    /// Each variant carries an optional dialect tag ("BrE", "AmE", …).
    let phonetics: [PhoneticVariant]
    /// The raw XML payload (kept so power users could export it later).
    let rawXML: String?

    /// Convenience: legacy single-string phonetic (joined for plain-text copy).
    var phonetic: String? {
        guard !phonetics.isEmpty else { return nil }
        return phonetics.map { v in
            if let d = v.dialect { return "\(d) \(v.ipa)" }
            return v.ipa
        }.joined(separator: ", ")
    }
}

/// One pronunciation variant — e.g. (BrE, aʊtˈstændɪŋ).
struct PhoneticVariant: Hashable {
    let dialect: String?   // "BrE", "AmE", or nil for unmarked
    let ipa: String        // raw IPA string, without surrounding slashes
}

/// A semantic chunk of a definition — we group these for nice rendering.
struct DefinitionSection: Identifiable {
    let id = UUID()
    let kind: Kind
    let text: String
    /// Nested senses (only used when kind == .partOfSpeech).
    let senses: [Sense]

    enum Kind {
        case partOfSpeech     // "noun", "verb"
        case etymology        // "ORIGIN"
        case note             // "USAGE", phrases, etc.
        case plain            // fallback for unrecognised XML
    }

    struct Sense: Identifiable {
        let id = UUID()
        let number: String?         // "1", "①", "2a", etc.
        /// Parenthetical category label that some bilingual entries put right
        /// after the sense number, e.g. "(excellent)" in
        /// `① (excellent) 杰出的 …`. Rendered as a sense subtitle.
        let categoryLabel: String?
        /// Prose definition (used for monolingual entries and as a fallback
        /// when bilingual structure couldn't be extracted).
        let definition: String
        /// Structured rows for bilingual entries:
        /// `target script + pronunciation + applicable domains`.
        /// Empty for monolingual senses.
        let translations: [Translation]
        let examples: [String]
    }

    /// One row inside a bilingual sense, e.g.
    ///   target = "杰出的", pronunciation = "jiéchū de", domains = ["achievement"]
    struct Translation: Identifiable {
        let id = UUID()
        let target: String
        let pronunciation: String?
        let domains: [String]
    }
}
