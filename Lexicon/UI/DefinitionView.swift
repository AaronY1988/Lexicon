//
//  DefinitionView.swift
//  Lexicon
//
//  Renders one DefinitionRecord. The layout is hierarchical:
//
//    headword                             [🔊] [★] [📋]
//    BrE /ipa/   AmE /ipa/
//    ─────────────────────────────────────────────────
//    adjective
//      ① (excellent)
//          杰出的    jiéchū de      [achievement]
//          优异的    yōuyì de       [performance]
//          出色的    chūsè de       [talent]
//          ▸ an outstanding beauty   绝色美人
//      ② (prominent)
//          ...
//
//  Monolingual entries fall back to the old prose-style render: each sense
//  shows a numbered prose definition with examples below.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DefinitionView: View {

    let record: DefinitionRecord
    @ObservedObject private var history = HistoryStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            headerBlock
            ForEach(record.sections) { section in
                switch section.kind {
                case .partOfSpeech:
                    partOfSpeechBlock(section)
                case .etymology:
                    etymologyBlock(section)
                case .note, .plain:
                    plainBlock(section)
                }
            }
        }
    }

    // MARK: Header

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                // Headword. `minimumScaleFactor` lets long single words shrink
                // to fit instead of breaking mid-syllable ("outstand" / "ing").
                Text(record.headword)
                    .font(Theme.serif(34, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.55)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                Spacer(minLength: 4)

                // Headword speaker: defaults to the first phonetic variant's
                // dialect if we have one (so on a bilingual entry it just
                // plays *something* sensible); otherwise en-US. Per-variant
                // buttons live on the phonetic row below.
                Button {
                    let lang = Pronouncer.bcp47(forDialectTag: record.phonetics.first?.dialect)
                    Pronouncer.shared.speak(record.headword, language: lang)
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.accent))
                }
                .buttonStyle(.plain)
                .help("Pronounce")

                Button {
                    history.toggleFavorite(for: record.headword)
                } label: {
                    let starred = history.isFavorite(record.headword)
                    Image(systemName: starred ? "star.fill" : "star")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(starred ? Theme.star : Theme.inkSecondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.chip))
                }
                .buttonStyle(.plain)
                .help(history.isFavorite(record.headword) ? "Remove from favorites" : "Add to favorites")

                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(plainTextSummary(), forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.chip))
                }
                .buttonStyle(.plain)
                .help("Copy definition")

                Menu {
                    Button {
                        ShareCardExporter.copyToPasteboard(record)
                    } label: {
                        Label("Copy as image", systemImage: "doc.on.doc")
                    }
                    Button {
                        ShareCardExporter.savePNG(record)
                    } label: {
                        Label("Save as PNG…", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.chip))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Share as image")
            }

            if !record.phonetics.isEmpty {
                phoneticRow
            }
        }
    }

    private var phoneticRow: some View {
        // Each variant: small "BrE" badge + IPA string + a per-dialect
        // speaker button. Wraps to a second line on very narrow panels.
        FlowHStack(spacing: 14, lineSpacing: 6) {
            ForEach(Array(record.phonetics.enumerated()), id: \.offset) { _, v in
                variantChip(v)
            }
        }
    }

    @ViewBuilder
    private func variantChip(_ v: PhoneticVariant) -> some View {
        let lang = Pronouncer.bcp47(forDialectTag: v.dialect)
        HStack(spacing: 6) {
            if let dialect = v.dialect {
                Text(dialect)
                    .font(Theme.ui(10, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.inkTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Theme.chip)
                    )
            }
            Text("/\(v.ipa)/")
                .font(Theme.ipa(15))
                .foregroundStyle(Theme.inkSecondary)
                .textSelection(.enabled)
            Button {
                Pronouncer.shared.speak(record.headword, language: lang)
            } label: {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .help(speakerHelpText(language: lang, dialect: v.dialect))
        }
    }

    private func speakerHelpText(language: String, dialect: String?) -> String {
        let label = dialect ?? language
        if !Pronouncer.shared.hasVoice(for: language) {
            return "No \(label) voice installed — System Settings ▸ Accessibility ▸ Spoken Content ▸ System Voice"
        }
        if !Pronouncer.shared.hasHighQualityVoice(for: language) {
            return "Pronounce in \(label) (tip: download a Premium voice in System Settings ▸ Accessibility ▸ Spoken Content for clearer audio)"
        }
        return "Pronounce in \(label)"
    }

    // MARK: POS block

    private func partOfSpeechBlock(_ section: DefinitionSection) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !section.text.isEmpty {
                HStack(spacing: 8) {
                    Text(section.text)
                        .font(Theme.serif(15, weight: .semibold).italic())
                        .foregroundStyle(Theme.accent)
                    Rectangle()
                        .fill(Theme.line)
                        .frame(height: 1)
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(section.senses.enumerated()), id: \.element.id) { idx, sense in
                    senseBlock(index: idx + 1,
                               sense: sense,
                               hideNumber: section.senses.count == 1 && sense.number == nil && sense.categoryLabel == nil)
                }
            }
        }
    }

    private func senseBlock(index: Int,
                            sense: DefinitionSection.Sense,
                            hideNumber: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if !hideNumber {
                Text(sense.number ?? "\(index)")
                    .font(Theme.ui(12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 21, height: 21)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.accentSoft)
                    )
                    .padding(.top, 3)
            }
            VStack(alignment: .leading, spacing: 8) {
                if let label = sense.categoryLabel, !label.isEmpty {
                    Text(label)
                        .font(Theme.ui(12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Theme.accentSoft)
                        )
                }

                // Bilingual structured rows, when present.
                if !sense.translations.isEmpty {
                    translationsGrid(sense.translations)
                }

                // Prose definition (monolingual entries, or bilingual residue).
                if !sense.definition.isEmpty {
                    Text(sense.definition)
                        .font(Theme.serif(16))
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                // Examples.
                if !sense.examples.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(sense.examples, id: \.self) { ex in
                            exampleRow(ex)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func translationsGrid(_ rows: [DefinitionSection.Translation]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // Target (CJK or otherwise) — primary visual weight.
                    Text(row.target)
                        .font(Theme.serif(16, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    if let pron = row.pronunciation {
                        Text(pron)
                            .font(Theme.ui(12, weight: .regular).italic())
                            .foregroundStyle(Theme.inkSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !row.domains.isEmpty {
                        // Domain chips, e.g. [achievement] [performance]
                        FlowHStack(spacing: 4, lineSpacing: 4) {
                            ForEach(row.domains, id: \.self) { d in
                                Text(d)
                                    .font(Theme.ui(10, weight: .medium))
                                    .foregroundStyle(Theme.inkTertiary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(
                                        Capsule().fill(Theme.chip)
                                    )
                                    .overlay(
                                        Capsule().stroke(Theme.line, lineWidth: 0.5)
                                    )
                            }
                        }
                    }
                }
            }
        }
    }

    private func exampleRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\u{25B8}")
                .font(Theme.ui(11, weight: .bold))
                .foregroundStyle(Theme.accent.opacity(0.7))
            Text(text)
                .font(Theme.serif(15).italic())
                .foregroundStyle(Theme.inkSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.leading, 2)
    }

    // MARK: Etymology / plain

    private func etymologyBlock(_ section: DefinitionSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ORIGIN")
                .font(Theme.ui(10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.inkTertiary)
            Text(section.text)
                .font(Theme.serif(13.5))
                .foregroundStyle(Theme.inkSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.paperRaised)
        )
    }

    @ViewBuilder
    private func plainBlock(_ section: DefinitionSection) -> some View {
        let chunks = splitOnExampleMarkers(section.text)
        if chunks.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                if let head = chunks.first, !head.isEmpty {
                    Text(head)
                        .font(Theme.serif(16))
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                ForEach(Array(chunks.dropFirst().enumerated()), id: \.offset) { _, chunk in
                    exampleRow(chunk)
                }
            }
        } else {
            Text(section.text)
                .font(Theme.serif(16))
                .foregroundStyle(Theme.ink)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    /// Splits text on ▶ / ▸ / ‣ / ⁌ example markers, trimming each chunk.
    private func splitOnExampleMarkers(_ text: String) -> [String] {
        let markers: [Character] = ["\u{25B6}", "\u{25B8}", "\u{2023}", "\u{204C}"]
        var parts: [String] = []
        var current = ""
        for ch in text {
            if markers.contains(ch) {
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return parts.filter { !$0.isEmpty }
    }

    // MARK: Plain-text export

    private func plainTextSummary() -> String {
        var lines: [String] = [record.headword]
        if let p = record.phonetic { lines.append("| \(p) |") }
        for section in record.sections {
            switch section.kind {
            case .partOfSpeech:
                if !section.text.isEmpty { lines.append("\n\(section.text)") }
                for (i, s) in section.senses.enumerated() {
                    let num = s.number ?? "\(i + 1)"
                    var head = "  \(num)."
                    if let label = s.categoryLabel { head += " (\(label))" }
                    if !s.definition.isEmpty { head += " \(s.definition)" }
                    if head.trimmingCharacters(in: .whitespaces) != "\(num)." {
                        lines.append(head)
                    }
                    for row in s.translations {
                        var rowLine = "     • \(row.target)"
                        if let pron = row.pronunciation { rowLine += "  \(pron)" }
                        if !row.domains.isEmpty {
                            rowLine += "  <\(row.domains.joined(separator: ", "))>"
                        }
                        lines.append(rowLine)
                    }
                    for ex in s.examples { lines.append("     \u{25B8} \(ex)") }
                }
            case .etymology:
                lines.append("\nORIGIN")
                lines.append(section.text)
            case .note, .plain:
                lines.append(section.text)
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - FlowHStack
//
// A minimal flow layout — lays children left-to-right and wraps to the next
// line when the row width would be exceeded. Used for phonetic variants and
// domain-chip strings, where the count is dynamic and a fixed HStack would
// either overflow or force ugly truncation.

struct FlowHStack: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(subviews: subviews, maxWidth: maxWidth)
        let height = rows.reduce(0) { $0 + $1.height } +
            CGFloat(max(0, rows.count - 1)) * lineSpacing
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        let rows = computeRows(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = subviews[item.index].sizeThatFits(.unspecified)
                subviews[item.index].place(at: CGPoint(x: x, y: y),
                                           anchor: .topLeading,
                                           proposal: ProposedViewSize(width: size.width,
                                                                      height: size.height))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [(index: Int, width: CGFloat)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = (rows[rows.count - 1].items.isEmpty ? 0 : spacing) + size.width
            if rows[rows.count - 1].width + needed > maxWidth,
               !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            let space = rows[rows.count - 1].items.isEmpty ? 0 : spacing
            rows[rows.count - 1].width += space + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            rows[rows.count - 1].items.append((index, size.width))
        }
        return rows
    }
}

// MARK: - Share card
//
// A self-contained, export-friendly rendering of one `DefinitionRecord`, with
// a Lexicon wordmark and source attribution. Kept on a fixed warm "Daylight"
// palette (the exporter forces `.light`) so the saved PNG always looks the same
// regardless of the user's system appearance.

struct ShareCardView: View {

    let record: DefinitionRecord
    /// Card width in points; the PNG is rendered at 2× this.
    var width: CGFloat = 520

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHeader

            Text(record.headword)
                .font(.system(size: 40, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)

            if !record.phonetics.isEmpty {
                phoneticRow.padding(.top, 12)
            }

            Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 18)

            VStack(alignment: .leading, spacing: 18) {
                ForEach(record.sections) { section in
                    sectionView(section)
                }
            }

            Rectangle().fill(Theme.line).frame(height: 1)
                .padding(.top, 18).padding(.bottom, 12)

            footer
        }
        .padding(.horizontal, 34)
        .padding(.top, 30)
        .padding(.bottom, 24)
        .frame(width: width, alignment: .leading)
        .background(Theme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
    }

    private var brandHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "book.closed")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("LEXICON")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(Theme.inkTertiary)
        }
    }

    private var phoneticRow: some View {
        FlowHStack(spacing: 18, lineSpacing: 6) {
            ForEach(Array(record.phonetics.enumerated()), id: \.offset) { _, v in
                HStack(spacing: 6) {
                    if let dialect = v.dialect {
                        Text(dialect)
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(Theme.inkTertiary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.chip))
                    }
                    Text("/\(v.ipa)/")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: DefinitionSection) -> some View {
        switch section.kind {
        case .partOfSpeech:
            posBlock(section)
        case .etymology:
            originBlock(section)
        case .note, .plain:
            Text(section.text)
                .font(.system(size: 16, design: .serif))
                .foregroundStyle(Theme.ink)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func posBlock(_ section: DefinitionSection) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if !section.text.isEmpty {
                Text(section.text)
                    .font(.system(size: 15, weight: .semibold, design: .serif).italic())
                    .foregroundStyle(Theme.accent)
            }
            ForEach(Array(section.senses.enumerated()), id: \.element.id) { idx, sense in
                senseRow(index: idx + 1, sense: sense)
            }
        }
    }

    private func senseRow(index: Int, sense: DefinitionSection.Sense) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(sense.number ?? "\(index)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.accentSoft)
                )
            VStack(alignment: .leading, spacing: 8) {
                if let label = sense.categoryLabel, !label.isEmpty {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.accentSoft))
                }
                ForEach(sense.translations) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(row.target)
                            .font(.system(size: 17, weight: .medium, design: .serif))
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if let pron = row.pronunciation {
                            Text(pron)
                                .font(.system(size: 12).italic())
                                .foregroundStyle(Theme.inkSecondary)
                        }
                        if !row.domains.isEmpty {
                            FlowHStack(spacing: 4, lineSpacing: 4) {
                                ForEach(row.domains, id: \.self) { d in
                                    Text(d)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Theme.inkTertiary)
                                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                                        .background(Capsule().fill(Theme.chip))
                                        .overlay(Capsule().stroke(Theme.line, lineWidth: 0.5))
                                }
                            }
                        }
                    }
                }
                if !sense.definition.isEmpty {
                    Text(sense.definition)
                        .font(.system(size: 17, design: .serif))
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(sense.examples, id: \.self) { ex in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\u{25B8}")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.accent.opacity(0.7))
                        Text(ex)
                            .font(.system(size: 15, design: .serif).italic())
                            .foregroundStyle(Theme.inkSecondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func originBlock(_ section: DefinitionSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ORIGIN")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.inkTertiary)
            Text(section.text)
                .font(.system(size: 13.5, design: .serif))
                .foregroundStyle(Theme.inkSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.paperRaised)
        )
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(record.source.name)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.inkTertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Image(systemName: "book.closed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Looked up with Lexicon")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .fixedSize()
        }
    }
}

// MARK: - Share card export

@MainActor
enum ShareCardExporter {

    /// Render the share card for `record` to an `NSImage` (2× for retina).
    static func image(for record: DefinitionRecord) -> NSImage? {
        let card = ShareCardView(record: record)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: card)
        renderer.scale = max(2, NSScreen.main?.backingScaleFactor ?? 2)
        return renderer.nsImage
    }

    /// Copy the card image to the general pasteboard.
    static func copyToPasteboard(_ record: DefinitionRecord) {
        guard let image = image(for: record) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    /// Prompt for a location and write the card as a PNG.
    static func savePNG(_ record: DefinitionRecord) {
        guard let image = image(for: record),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(safeFileName(record.headword)).png"
        panel.canCreateDirectories = true
        panel.title = "Save word card"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            try? png.write(to: url)
        }
    }

    private static func safeFileName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = cleaned.first else { return "Word" }
        // Capitalize only the first letter, leaving the rest as-is
        // (e.g. "serendipity" → "Serendipity"; CJK headwords are unchanged).
        return first.uppercased() + cleaned.dropFirst()
    }
}
