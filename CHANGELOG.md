# Changelog

All notable changes to Lexicon are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.5.0] — 2026-07-01

### Added
- **Themes** — choose between the warm **Reading Room** and a vivid
  **Luminous Glass** theme in Settings → Appearance. The whole app (search panel,
  study cards, settings) re-tints instantly, and the choice is remembered.

### Fixed
- **Chinese pronunciation** — Chinese words are now spoken with a Mandarin voice
  instead of an English voice reading the pinyin/characters. Text is detected by
  script; English words are unaffected.
- **Windows open centered** — the Study and Settings windows now appear centered
  on screen instead of off to one side.

## [1.4.0] — 2026-06-28

### Added
- **Customizable global hotkey** — set your own shortcut to summon Lexicon in
  Settings → Global shortcut. Click the field and press any combination (it must
  include ⌘, ⌃, or ⌥); the change takes effect immediately, and the panel,
  menu, and tooltip update to show it. A reset button restores the default ⌃⌘D.

### Fixed
- **Look up the selected word now prompts for permission** — pressing the hotkey
  on selected text needs Accessibility access. Lexicon now requests it (and opens
  the Accessibility settings pane) the first time you use it, instead of silently
  doing nothing; a "Enable look-up of selected text…" menu item appears until
  it's granted.

## [1.3.0] — 2026-06-28

### Added
- **Dictionary preferences** — a Settings window (menu bar → Settings…) lists
  every installed Apple dictionary so you can choose exactly which ones Lexicon
  searches, and drag to reorder them (which also orders the definition tabs).
- **Adjustable text size** — a slider in Settings scales the definition body
  text from 85% to 150%, with a live preview.
- **Study mode (spaced repetition)** — add words with the new graduation-cap
  button, then review them from menu bar → Study…. Cards are scheduled with the
  SM-2 (SuperMemo 2) algorithm — the same proven method behind Anki — grading
  each review Again / Hard / Good / Easy and growing the interval as a word
  sticks. Flashcards quiz both directions (recall the meaning, and guess the
  word), and the menu shows how many cards are due.
- **Bilingual study cards** — review cards show every enabled dictionary's
  entry, so English and Chinese meanings appear together; example sentences are
  hidden during "guess the word" so they don't give the answer away.
- **Clear Recent** — a menu item clears recent lookups while keeping favorites.

### Changed
- The Settings and Study windows use the same warm "Reading Room" paper styling
  as the main search panel.

## [1.2.0] — 2026-06-28

### Added
- **Share as image** — a share button in the definition header turns any entry
  into a word card you can **copy to the clipboard** or **save as a PNG**. The
  card uses the warm Reading Room style and shows the full entry for the active
  dictionary: headword, both phonetic variants, part of speech, every sense
  (with translations, domain labels, and examples), etymology, and a source
  attribution with a small Lexicon wordmark. It always renders in light mode so
  the exported image looks the same regardless of system appearance, and saved
  files default to a capitalized filename (e.g. `Serendipity.png`).

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
