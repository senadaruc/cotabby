import SwiftUI

/// File overview:
/// The card that offers a drafted answer to a question: the draft, then the messages it was drawn
/// from, then how to take or leave it.
///
/// Why the sources are always shown: an answer can quote facts from a different conversation than
/// the one being replied in (the user chose that for answers), so the card names each fact's sender,
/// chat, date and app before anything is inserted. Presentation only; built by
/// `AnswerCardController` from an `AnswerOffer`.
struct AnswerCardView: View {
    let offer: AnswerOffer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                Text("Answer from memory").font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                Text("Tab to insert · Esc to dismiss")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(offer.draft)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            if !offer.sources.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(offer.sources) { source in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(source.byline)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(source.excerpt)
                                .font(.caption)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.accentColor.opacity(0.5)))
        .padding(2)
    }
}

/// A drafted answer and where its facts came from.
nonisolated struct AnswerOffer: Equatable, Sendable {
    struct Source: Equatable, Identifiable, Sendable {
        let id: String
        /// "Irem Dogru · THY – Imperum · 10 May · Outlook"
        let byline: String
        let excerpt: String
    }

    let draft: String
    let sources: [Source]
}
