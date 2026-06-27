# Changelog

All notable changes to Lexicon are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.1.0] — 2026-06-28

### Added
- **Inline gloss previews** — each word in the left match list now shows a
  one-line meaning underneath, so you can scan senses without clicking through.
- **Warm empty state** — opening the panel now greets you with a daily
  "word of the day" plus your favorites (or recents), instead of a bare logo.
- **Typo-tolerant lookup** — when nothing matches as a prefix, the system
  spell-checker's corrections are surfaced under a "Did you mean" header
  (e.g. `seperate` → `separate`).
- **Loading shimmer & keyboard hints** — a calm placeholder shows while a
  lookup resolves, and the footer hints `↑↓ navigate · ↩ open`.

### Changed
- **Panel proportions** — the search panel is now wider and shorter
  (560×580 → 640×500) for a calmer, more landscape two-pane reading layout.

### Fixed
- **Headword parsing** — bilingual dictionary entries without a phonetic
  delimiter no longer capture the whole line as the headword (e.g. it now
  reads `阿妈` instead of `阿妈 āmā noun dialect mum`). This also fixes the
  large headword shown atop the definition.
- **History cleanup** — a one-time pass sanitizes previously-recorded
  malformed entries (mixed-script lines, cross-reference arrows, trailing
  part-of-speech tokens) down to their actual headword, and de-duplicates.

## [1.0.0]

### Added
- Initial release.
- Global hotkey (`⌃⌘D`) summons a Spotlight-style frosted-glass search panel.
- Menu bar icon with recent lookups and favorites.
- Look up selected text from any app.
- Live search across every dictionary enabled in `Dictionary.app`, via Apple's
  `DictionaryServices` framework.
- Pronunciation, history & favorites, and a hand-tuned light/dark
  "Reading Room" theme.
