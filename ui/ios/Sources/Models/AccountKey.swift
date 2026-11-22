import Foundation

/// Account-key routing convention: inbox2 "MX" team-pool keys are prefixed `org_`
/// (the whole-org chip) or `dom_` (a per-domain workspace chip); everything else is
/// an offline channel. One place owns the prefixes so the routing decision isn't
/// re-derived across the view layer.
enum AccountKey {
    static let domainPrefix = "org_"
    static let domainWorkspacePrefix = "dom_"
    static func isDomain(_ key: String?) -> Bool {
        guard let key else { return false }
        return key.hasPrefix(domainPrefix) || key.hasPrefix(domainWorkspacePrefix)
    }

    /// The `dom_…` list filter when a specific domain workspace is selected; nil for
    /// the whole-org (legacy) chip, which shows the unfiltered pool.
    static func domainFilter(_ key: String?) -> String? {
        key?.hasPrefix(domainWorkspacePrefix) == true ? key : nil
    }
}
