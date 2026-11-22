import SwiftUI

/// Inline banner shown under a connected-account row when its last sync failed.
/// A dead-credentials account (`needs_reauth`) gets a prominent, tappable
/// "Reconnect" call-to-action telling the user exactly what to do; a transient
/// error shows the reason in a quieter style (the next sync usually clears it).
struct AccountErrorBanner: View {
    @Environment(\.theme) private var theme
    let acct: AccountRow
    let onReconnect: () -> Void
    private var p: ThemePalette { theme.palette }

    private var accent: Color { acct.needsReauth ? p.accentAmber : p.accentDanger }

    /// User-facing headline. `needs_reauth` is actionable; a transient error
    /// surfaces the core's reason so the user can tell "offline" from "revoked".
    private var headline: String {
        if acct.needsReauth { return "Sign-in expired. Reconnect to get new mail." }
        guard let message = acct.errorMessage else { return "Couldn't get new mail" }
        // A rate limit (Gmail sends it as a 403 with a JSON body) clears by itself;
        // show one plain line, not the JSON. The stored text keeps the retry time.
        if Self.isRateLimit(message) { return "The mail provider asked us to slow down. We'll try again when it lets us." }
        return "Couldn't get new mail: \(message)"
    }

    static func isRateLimit(_ message: String) -> Bool {
        let m = message.lowercased()
        return ["quota exceeded", "quotaexceeded", "ratelimitexceeded", "rate limit", "http 429"].contains { m.contains($0) }
    }

    var body: some View {
        HStack(spacing: Space.s2) {
            Image(systemName: acct.needsReauth ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                .font(AppFont.xs).foregroundStyle(accent)
            Text(headline)
                .font(AppFont.xs).foregroundStyle(p.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.s2)
            if acct.needsReauth {
                PillButton(title: "Reconnect", tint: accent, style: .outlined, action: onReconnect)
            }
        }
        .padding(.horizontal, Space.s3).padding(.vertical, Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(accent.opacity(0.10)))
        .padding(.bottom, Space.s3)
        .accessibilityElement(children: .combine)
        .accessibilityHint(acct.needsReauth ? "Double-tap Reconnect to sign in again" : "")
    }
}
