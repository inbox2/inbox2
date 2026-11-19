import Foundation

/// Ranks the addresses seen across the conversation table into an autocomplete
/// order. Pure Foundation (no SQLite) so it can be pinned by tests — the store just
/// hands it `(from_address, to_address, updated_at)` rows.
///
/// The ranking is recency-weighted frequency, not lifetime volume: a correspondent
/// you mailed weekly this year has to beat one with a bigger all-time thread count
/// from four years ago, or the To/Cc suggestions fill up with people you've long
/// stopped writing to.
enum ContactRanking {
    /// Age buckets, newest cutoff first, as "yyyy-MM-dd" strings. `updated_at` is an
    /// ISO internet date-time, so its date prefix compares lexicographically — no
    /// per-row date parsing over the whole conversations table.
    /// ponytail: fixed buckets, not a continuous half-life — swap in a decay curve
    /// only if the steps ever show up as visibly wrong ordering.
    static func buckets(now: Date = Date()) -> [(day: String, weight: Double)] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return [(30.0, 16.0), (90.0, 8.0), (365.0, 4.0), (730.0, 2.0), (1460.0, 1.0)].map {
            (f.string(from: now.addingTimeInterval(-$0.0 * 86_400)), $0.1)
        }
    }

    /// The weight one conversation contributes to everyone on it. Anything older than
    /// the last bucket — or with a missing/unparseable timestamp — still counts, just
    /// barely, so an ancient correspondent is ordered last rather than dropped.
    static func weight(_ updatedAt: String, buckets: [(day: String, weight: Double)]) -> Double {
        let day = String(updatedAt.prefix(10))
        for b in buckets where day >= b.day { return b.weight }
        return 0.5
    }

    /// `rows` are `(from_address, to_address, updated_at)` straight off `conversations`.
    /// `Contact.total` stays the honest raw appearance count (Settings shows it as "N×");
    /// only the ORDER carries the recency weighting.
    static func rank(_ rows: [(from: String, to: String, updatedAt: String)], now: Date = Date()) -> [Contact] {
        let buckets = buckets(now: now)
        var map: [String: (name: String, total: Int, score: Double)] = [:]

        func add(_ raw: String, _ weight: Double) {
            for entry in MailAddress.parseList(raw) {
                let email = entry.email.lowercased()
                guard email.contains("@") else { continue }
                let name = entry.name.trimmingCharacters(in: .whitespaces)
                if var existing = map[email] {
                    existing.total += 1
                    existing.score += weight
                    // Upgrade to a richer (multi-word) name if we have one now.
                    if name.contains(" ") && !existing.name.contains(" ") { existing.name = name }
                    map[email] = existing
                } else {
                    map[email] = (name: name.isEmpty || name.lowercased() == email ? "" : name,
                                  total: 1, score: weight)
                }
            }
        }

        for row in rows {
            let w = weight(row.updatedAt, buckets: buckets)
            add(row.from, w)
            add(row.to, w)
        }

        return map
            .map { (contact: Contact(email: $0.key, name: $0.value.name, total: $0.value.total),
                    score: $0.value.score) }
            // Ties break on raw volume, then address, so the order is stable across runs
            // (dictionary iteration isn't).
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.contact.total != $1.contact.total { return $0.contact.total > $1.contact.total }
                return $0.contact.email < $1.contact.email
            }
            .map(\.contact)
    }
}
