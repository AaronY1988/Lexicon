//
//  DictionaryTabs.swift
//  Lexicon
//

import SwiftUI

struct DictionaryTabs: View {

    let records: [DefinitionRecord]
    @Binding var activeID: String?

    var body: some View {
        // Understated underlined text tabs — the active source is marked by an
        // accent label sitting over an accent rule; everything else recedes to
        // tertiary ink. A hairline runs the full width beneath the row.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 22) {
                ForEach(records) { record in
                    Button {
                        activeID = record.source.id
                    } label: {
                        Text(displayName(for: record.source.name))
                            .font(Theme.ui(13, weight: isActive(record) ? .semibold : .regular))
                            .foregroundStyle(isActive(record) ? Theme.accent : Theme.inkTertiary)
                            .padding(.bottom, 9)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(isActive(record) ? Theme.accent : Color.clear)
                                    .frame(height: 2)
                            }
                    }
                    .buttonStyle(.plain)
                    .help(record.source.name)
                }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    private func isActive(_ record: DefinitionRecord) -> Bool {
        record.source.id == (activeID ?? records.first?.source.id)
    }

    /// Most dictionary names are long ("New Oxford American Dictionary").
    /// Show a short pill label.
    private func displayName(for full: String) -> String {
        let lower = full.lowercased()
        if lower.contains("oxford american") { return "Oxford American" }
        if lower.contains("oxford") && lower.contains("thes") { return "Thesaurus" }
        if lower.contains("oxford") { return "Oxford" }
        if lower.contains("wikipedia") { return "Wikipedia" }
        if lower.contains("apple") { return "Apple" }
        if lower.contains("simplified chinese") { return "中文" }
        if lower.contains("japanese") { return "日本語" }
        return full
    }
}
