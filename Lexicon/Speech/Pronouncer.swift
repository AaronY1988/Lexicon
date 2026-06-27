//
//  Pronouncer.swift
//  Lexicon
//
//  Speaks a word using *professional, human-recorded* audio when we can get
//  it, and only falls back to Apple's `AVSpeechSynthesizer` (the robotic
//  "reads-the-letters" voice) when no recording exists.
//
//  Primary source — Google / Oxford recordings
//  ───────────────────────────────────────────
//  Google's dictionary serves the Oxford voice-actor recordings as plain mp3s
//  from `ssl.gstatic.com`, with separate British and American takes:
//
//      https://ssl.gstatic.com/dictionary/static/sounds/oxford/<word>--_gb_1.mp3
//      https://ssl.gstatic.com/dictionary/static/sounds/oxford/<word>--_us_1.mp3
//
//  These are real human pronunciations — the same audio you hear in a Google
//  search dictionary card. They cover the vast majority of common headwords.
//  We request the dialect that matches the tapped phonetic variant, fall back
//  to the other dialect, and only then drop to synthesis.
//
//  Caching
//  ───────
//  Downloaded clips are cached to
//      ~/Library/Application Support/Lexicon/PronunciationCache/<dialect>/<word>.mp3
//  so repeat lookups (and re-taps) are instant and offline.
//
//  Fallback — AVSpeechSynthesizer
//  ──────────────────────────────
//  For words with no recording we still speak them, picking the best-quality
//  installed voice (premium > enhanced > default). The UI uses
//  `hasVoice` / `hasHighQualityVoice` to nudge the user toward downloading a
//  Premium system voice for clearer fallback audio.
//

import AVFoundation

@MainActor
final class Pronouncer {

    static let shared = Pronouncer()

    // MARK: Synthesis fallback

    private let synth = AVSpeechSynthesizer()
    /// Cache the best voice per language so we don't iterate the (large)
    /// installed-voice list on every click.
    private var voiceCache: [String: AVSpeechSynthesisVoice] = [:]

    // MARK: Recorded-audio playback

    /// Held strongly while a clip plays — an `AVAudioPlayer` that goes out of
    /// scope stops immediately.
    private var audioPlayer: AVAudioPlayer?
    /// Monotonic token; bumped on every `speak` so a slow download for an old
    /// word can't talk over the word the user just tapped.
    private var requestToken = 0
    /// On-disk cache of downloaded mp3 clips.
    private let cacheDir: URL
    /// In-memory note of URLs we already know return no recording, so we don't
    /// re-hit the network for the same miss within a session.
    private var knownMisses: Set<String> = []

    private let session: URLSession

    private init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory,
                                      in: .userDomainMask,
                                      appropriateFor: nil,
                                      create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport
            .appendingPathComponent("Lexicon", isDirectory: true)
            .appendingPathComponent("PronunciationCache", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheDir = dir

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public

    /// Pronounce `word` in the given dialect. `language` is a BCP-47 code
    /// (`en-GB`, `en-US`, …). Tries a real Oxford recording first, then the
    /// other dialect's recording, then synthesis.
    func speak(_ word: String, language: String = "en-US") {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Interrupt whatever's currently sounding and claim this request.
        stop()
        requestToken &+= 1
        let token = requestToken

        let dialects = Self.dialectPreference(forBCP47: language)

        Task { [weak self] in
            guard let self else { return }
            if let fileURL = await self.recordedClip(for: trimmed, dialects: dialects) {
                // A newer tap may have landed while we were downloading.
                guard token == self.requestToken else { return }
                if !self.play(fileURL) {
                    self.speakWithSynthesizer(trimmed, language: language)
                }
            } else {
                guard token == self.requestToken else { return }
                self.speakWithSynthesizer(trimmed, language: language)
            }
        }
    }

    /// Stop any in-flight recording playback or synthesis.
    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        audioPlayer?.stop()
        audioPlayer = nil
    }

    // MARK: - Recorded audio

    /// Returns a local mp3 URL for `word` in the most-preferred available
    /// dialect, downloading and caching on demand. `nil` if no recording
    /// exists for any requested dialect.
    private func recordedClip(for word: String, dialects: [String]) async -> URL? {
        // Oxford clips are keyed by the lowercased word; multi-word phrases and
        // anything with odd characters won't have a recording, but we still try
        // (a miss just falls through to synthesis).
        let key = word.lowercased()

        for dialect in dialects {
            // 1) Disk cache.
            let cached = cacheFileURL(word: key, dialect: dialect)
            if let size = try? cached.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > 0 {
                return cached
            }

            // 2) Network.
            guard let remote = Self.oxfordURL(word: key, dialect: dialect) else { continue }
            if knownMisses.contains(remote.absoluteString) { continue }

            do {
                let (data, response) = try await session.data(from: remote)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                // gstatic answers 404 (often with a tiny body) for missing words.
                guard status == 200, data.count > 512 else {
                    knownMisses.insert(remote.absoluteString)
                    continue
                }
                try data.write(to: cached, options: .atomic)
                return cached
            } catch {
                // Network error — don't cache as a permanent miss; just try the
                // next dialect / fall through to synthesis this time.
                continue
            }
        }
        return nil
    }

    private func cacheFileURL(word: String, dialect: String) -> URL {
        let dir = cacheDir.appendingPathComponent(dialect, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Sanitize the word into a safe filename.
        let safe = word.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
            .reduce(into: "") { $0.append($1) }
        return dir.appendingPathComponent("\(safe).mp3")
    }

    /// Build the Google/Oxford recording URL for a word + dialect ("gb"/"us").
    private static func oxfordURL(word: String, dialect: String) -> URL? {
        guard let encoded = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "https://ssl.gstatic.com/dictionary/static/sounds/oxford/\(encoded)--_\(dialect)_1.mp3")
    }

    /// Plays a local audio file. Returns `false` if the file couldn't be
    /// decoded (so the caller can fall back to synthesis).
    @discardableResult
    private func play(_ url: URL) -> Bool {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            audioPlayer = player
            player.prepareToPlay()
            return player.play()
        } catch {
            audioPlayer = nil
            return false
        }
    }

    // MARK: - Synthesis fallback

    private func speakWithSynthesizer(_ word: String, language: String) {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }

        let utterance = AVSpeechUtterance(string: word)
        utterance.voice = bestVoice(for: language)
            ?? bestVoice(for: "en-US")
            ?? AVSpeechSynthesisVoice(language: language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.pitchMultiplier = 1.0
        utterance.preUtteranceDelay = 0
        synth.speak(utterance)
    }

    /// Returns the highest-quality installed voice for `language`, or nil if
    /// nothing matching is installed.
    func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        if let cached = voiceCache[language] { return cached }

        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.caseInsensitiveCompare(language) == .orderedSame }
        guard !voices.isEmpty else { return nil }

        // Pick by quality: premium > enhanced > default.
        let qualityOrder: [AVSpeechSynthesisVoiceQuality] = [.premium, .enhanced, .default]
        for q in qualityOrder {
            let candidates = voices.filter { $0.quality == q }
            if let pick = candidates.first {
                voiceCache[language] = pick
                return pick
            }
        }

        voiceCache[language] = voices.first
        return voices.first
    }

    /// Tells the UI whether the user has any non-default voice installed for
    /// `language`. The view can use this to show a one-time "Tip: download a
    /// Premium voice in System Settings for clearer audio" hint.
    func hasHighQualityVoice(for language: String) -> Bool {
        guard let v = bestVoice(for: language) else { return false }
        return v.quality == .premium || v.quality == .enhanced
    }

    /// True if there's *any* installed voice for `language`. Use this to
    /// decide whether to show the dialect-specific speaker button at all.
    func hasVoice(for language: String) -> Bool {
        bestVoice(for: language) != nil
    }
}

// MARK: - Dialect mapping
//
// Bilingual entries label phonetic variants with strings like "BrE", "AmE",
// "US", "UK", "AusE". Map those to BCP-47 codes that AVSpeechSynthesisVoice
// understands. Unknown / nil tags fall back to en-US.

extension Pronouncer {
    static func bcp47(forDialectTag tag: String?) -> String {
        guard let raw = tag?.uppercased(), !raw.isEmpty else { return "en-US" }
        switch raw {
        case "BRE", "UK", "GB", "BR":            return "en-GB"
        case "AME", "US", "USE", "AM":           return "en-US"
        case "AUSE", "AUS", "AU":                return "en-AU"
        case "CANE", "CAN", "CA":                return "en-CA"
        case "INDE", "IN":                       return "en-IN"
        case "IRE", "IE":                        return "en-IE"
        case "SAFE", "ZA":                       return "en-ZA"
        case "NZE", "NZ":                        return "en-NZ"
        default:                                 return "en-US"
        }
    }

    /// Ordered list of Oxford recording dialects ("gb"/"us") to try for a given
    /// BCP-47 language. Oxford only publishes British and American takes, so we
    /// map every variant onto the closer of the two, then list the other as a
    /// secondary so a tap always has a shot at *some* human recording.
    static func dialectPreference(forBCP47 language: String) -> [String] {
        let lower = language.lowercased()
        let british = lower == "en-gb" || lower == "en-ie" || lower == "en-au"
            || lower == "en-nz" || lower == "en-za" || lower == "en-in"
        return british ? ["gb", "us"] : ["us", "gb"]
    }
}
