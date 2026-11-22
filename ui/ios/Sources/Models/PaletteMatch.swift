import Foundation

/// Subsequence match: every query character in order. Earlier, adjacent and
/// word-start hits score higher; nil when a character is missing.
enum PaletteMatch {
    static func score(_ query: String, _ text: String) -> Int? {
        let q = Array(query.lowercased()), t = Array(text.lowercased())
        guard !q.isEmpty else { return 0 }
        var qi = 0, score = 0, last = -2
        for (i, c) in t.enumerated() where qi < q.count && c == q[qi] {
            score += 10
            if i == last + 1 { score += 15 }                      // adjacent
            if i == 0 || t[i - 1] == " " || t[i - 1] == "@" { score += 20 } // word start
            score -= min(i, 20) / 4                                // earlier is better
            last = i; qi += 1
        }
        return qi == q.count ? score : nil
    }
}
