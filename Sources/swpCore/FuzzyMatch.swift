import Foundation

/// Fuzzy matching with scoring, for the picker's filter box.
///
/// Subsequence matching, the way every fuzzy finder does it: the query's
/// characters must appear in order, and how tightly and where they landed
/// decides the score. Bonuses favour word starts and runs, so `nsrv` finds
/// `node server.js` ahead of a process that happens to contain those letters
/// scattered through a path.
public enum FuzzyMatch {

    public struct MatchResult: Equatable, Sendable {
        public let score: Int
        public let matchedIndices: [Int]
    }

    public static func match(_ query: String, against target: String) -> MatchResult? {
        guard !query.isEmpty else { return nil }
        let queryChars = Array(query.lowercased())
        let targetChars = Array(target.lowercased())
        let original = Array(target)

        var matched: [Int] = []
        var q = 0
        var t = 0
        var score = 0

        while q < queryChars.count, t < targetChars.count {
            if queryChars[q] == targetChars[t] {
                matched.append(t)
                score += 10
                if matched.count > 1, t == matched[matched.count - 2] + 1 { score += 15 }
                if t == 0 || isWordBoundary(targetChars[t - 1]) { score += 30 }
                if t > 0, original[t].isUppercase, !original[t - 1].isUppercase { score += 25 }
                q += 1
            }
            t += 1
        }
        guard q == queryChars.count else { return nil }

        // Gaps cost, so a tight match in a long string beats a sprawling one.
        if matched.count > 1 {
            for i in 1..<matched.count { score -= (matched[i] - matched[i - 1]) * 2 }
        }
        return MatchResult(score: score, matchedIndices: matched)
    }

    private static func isWordBoundary(_ c: Character) -> Bool {
        c == " " || c == "_" || c == "-" || c == "/" || c == "." || c == ":" || c == "\\"
    }

    /// Filter and rank values that merely *carry* the text to match, handing
    /// back the matched character offsets so the caller can highlight them.
    ///
    /// The label closure exists because a picker row is not a string: it knows
    /// the process it stands for, and looking that up again by its rendered text
    /// is exactly the bug that duplicate rows expose.
    public static func filterAndSort<T>(_ items: [T], query: String,
                                        label: (T) -> String) -> [(item: T, indices: [Int])] {
        guard !query.isEmpty else { return items.map { ($0, []) } }
        var results: [(item: T, score: Int, indices: [Int])] = []
        for item in items {
            if let hit = match(query, against: label(item)) {
                results.append((item, hit.score, hit.matchedIndices))
            }
        }
        results.sort { $0.score > $1.score }
        return results.map { ($0.item, $0.indices) }
    }
}
