import Foundation

/// File overview:
/// How much of the prompt the in-process MLX runtime can keep from its KV cache. Typing changes the
/// prompt only near its end, so a request usually shares almost every token with the previous one;
/// the runtime trims the cache back to that shared prefix and decodes only the rest, which is what
/// makes a keystroke cost one or two tokens instead of the whole prompt. Pure, so the rule is
/// tested without a model.
nonisolated enum MLXPromptCachePlan {
    /// The decision for one request.
    struct Decision: Equatable {
        /// Leading prompt tokens whose cache entries are reused.
        let reusedTokens: Int
        /// Cache entries to drop from the end before decoding (the tail the new prompt does not
        /// share, plus whatever the previous generation appended).
        let trimCount: Int
        /// The cache cannot serve this prompt and must be rebuilt from empty.
        var rebuild: Bool { reusedTokens == 0 }
    }

    /// - Parameters:
    ///   - cachedPrompt: the prompt tokens the cache was last filled with, empty when it is empty.
    ///   - cacheLength: the cache's current length, which includes tokens generated after that prompt.
    ///   - newPrompt: the tokens of the prompt to serve now.
    ///   - canTrim: whether every layer's cache can drop entries from its end.
    /// At least one token is always decoded, because the next token's logits come from decoding.
    static func decision(cachedPrompt: [Int], cacheLength: Int, newPrompt: [Int], canTrim: Bool) -> Decision {
        guard canTrim, !cachedPrompt.isEmpty, newPrompt.count > 1 else {
            return Decision(reusedTokens: 0, trimCount: 0)
        }
        var shared = 0
        let limit = min(cachedPrompt.count, newPrompt.count)
        while shared < limit, cachedPrompt[shared] == newPrompt[shared] { shared += 1 }
        let reused = min(shared, newPrompt.count - 1, cacheLength)
        guard reused > 0 else { return Decision(reusedTokens: 0, trimCount: 0) }
        return Decision(reusedTokens: reused, trimCount: cacheLength - reused)
    }
}
