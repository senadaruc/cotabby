import Foundation

/// File overview:
/// Words the preview's warning when a rewrite contains a number or name that is in neither the
/// user's text nor memory (`AnswerGroundingPolicy.unsupportedSpecifics`). The user then decides
/// whether to "Replace anyway", so the warning must say what changed: "1000% eminim" came back as
/// "%100 eminim" (2026-10-11), and the old wording ("Not in your text or memory: 100") hid that the
/// rewrite had turned 1000 into 100. A number the user wrote that the rewrite dropped is shown as
/// what it replaced. Pure, so the wording is pinned by tests.
nonisolated enum RewriteChangeWarning {
    /// The warning for `unsupported` terms, or nil when there are none.
    static func message(selection: String, rewrite: String, unsupported: [String], usedMemory: Bool) -> String? {
        guard !unsupported.isEmpty else { return nil }
        let addedNumbers = unsupported.filter { $0.allSatisfy(\.isNumber) }
        let addedNames = unsupported.filter { !$0.allSatisfy(\.isNumber) }
        let source = usedMemory ? "your text or memory" : "your text"
        var sentences: [String] = []

        if !addedNumbers.isEmpty {
            let rewriteNumbers = Set(AnswerGroundingPolicy.numbers(in: rewrite))
            var seen = Set<String>()
            let dropped = AnswerGroundingPolicy.numbers(in: selection).filter { !rewriteNumbers.contains($0) && seen.insert($0).inserted }
            switch (dropped.count, addedNumbers.count) {
            case (0, 1):
                sentences.append("The rewrite adds the number \(addedNumbers[0]), which isn't in \(source).")
            case (0, _):
                sentences.append("The rewrite adds the numbers \(addedNumbers.joined(separator: ", ")), which aren't in \(source).")
            case (1, 1):
                sentences.append("The number changed: you wrote \(dropped[0]), the rewrite says \(addedNumbers[0]).")
            default:
                sentences.append("Numbers changed: you wrote \(dropped.joined(separator: ", ")); the rewrite says \(addedNumbers.joined(separator: ", ")).")
            }
        }
        if !addedNames.isEmpty {
            let quoted = addedNames.map { "“\($0)”" }.joined(separator: ", ")
            sentences.append(addedNames.count == 1
                ? "The rewrite adds \(quoted), which isn't in \(source)."
                : "The rewrite adds \(quoted), which aren't in \(source).")
        }
        return sentences.joined(separator: " ")
    }
}
