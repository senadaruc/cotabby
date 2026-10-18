import Foundation

/// File overview:
/// Which tokens may come next while an MLX generation replays the bytes token healing removed
/// from the prompt (`TokenHealingPlan`). The rule is the llama engine's (`TokenHealingVocabulary`
/// in CotabbyInference): prefer tokens that cover every remaining byte, since a short piece such as
/// " i" would otherwise outrank " intelligence" for an already typed " int"; only when no token
/// covers the bytes, allow tokens that spell a front part of them. Pieces are kept sorted, so each
/// step is a binary search rather than a scan of the whole vocabulary. Pure and testable.
nonisolated struct MLXHealingVocabulary {
    private struct Entry {
        let piece: [UInt8]
        let token: Int
        let containsLineBreak: Bool
    }

    private let entries: [Entry]

    /// - Parameter pieces: each token's decoded bytes by token id; empty for special tokens, which
    ///   can never replay typed text.
    init(pieces: [[UInt8]]) {
        entries = pieces.enumerated()
            .filter { !$0.element.isEmpty }
            .map { Entry(piece: $0.element, token: $0.offset, containsLineBreak: $0.element.contains { $0 == 10 || $0 == 13 }) }
            .sorted { $0.piece.lexicographicallyPrecedes($1.piece) }
    }

    func matchingTokens(prefix: [UInt8], singleLine: Bool) -> [Int] {
        guard !prefix.isEmpty else { return [] }
        var matches: [Int] = []
        var index = lowerBound(prefix)
        while index < entries.count, entries[index].piece.starts(with: prefix) {
            if !singleLine || !entries[index].containsLineBreak { matches.append(entries[index].token) }
            index += 1
        }
        if !matches.isEmpty { return matches }
        for length in 1 ..< prefix.count {
            let fragment = Array(prefix.prefix(length))
            var index = lowerBound(fragment)
            while index < entries.count, entries[index].piece == fragment {
                if !singleLine || !entries[index].containsLineBreak { matches.append(entries[index].token) }
                index += 1
            }
        }
        return matches
    }

    private func lowerBound(_ key: [UInt8]) -> Int {
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].piece.lexicographicallyPrecedes(key) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// A token's decoded bytes from its vocabulary string: "▁" is a space, "<0x0A>" a raw byte,
    /// and other angle-bracketed names are special tokens with no text.
    static func pieceBytes(_ token: String) -> [UInt8] {
        if token.count == 6, token.hasPrefix("<0x"), token.hasSuffix(">"),
           let byte = UInt8(token.dropFirst(3).dropLast(), radix: 16) {
            return [byte]
        }
        if token.count > 2, token.hasPrefix("<"), token.hasSuffix(">"), !token.contains(" "), !token.contains("▁") {
            return []
        }
        return Array(token.replacingOccurrences(of: "▁", with: " ").utf8)
    }
}
