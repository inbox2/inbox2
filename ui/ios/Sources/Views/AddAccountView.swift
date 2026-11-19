import SwiftUI
import SafariServices

/// SFSafariViewController in SwiftUI — the system browser Google/Microsoft allow
/// for OAuth (embedded WebViews are blocked).
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

struct IdentifiableURL: Identifiable { let id = UUID(); let url: URL }

/// The BYOK Meta channels (see docs/Cloud-Push.md Meta). `providerType` mirrors the
/// engine's `add_meta_account` channel ids; `logoAsset` the bundled brand PNG.
enum MetaChannelOption: String, CaseIterable, Identifiable {
    case whatsapp, messenger, instagram
    var id: String { rawValue }
    var providerType: String { rawValue }
    var displayName: String {
        switch self {
        case .whatsapp: return "WhatsApp"
        case .messenger: return "Messenger"
        case .instagram: return "Instagram"
        }
    }
    var logoAsset: String {
        switch self {
        case .whatsapp: return "ch-whatsapp"
        case .messenger: return "ch-messenger"
        case .instagram: return "ch-instagram"
        }
    }
}

/// One connected Meta app, for credential reuse. Several channels can share an
/// app's secret + System User token; `repKey` is the account whose encrypted
/// bundle gets reused. Accounts without a known app id each form their own group.
struct MetaAppGroup: Identifiable {
    let id: String
    let appId: String?
    let repKey: String
    let channels: [AccountRow]

    var label: String {
        let chans = channels.map { channelDisplay($0.provider) }.joined(separator: ", ")
        let base = appId.map { "App \($0)" } ?? (channels.first?.email ?? "Existing Meta app")
        return chans.isEmpty ? base : "\(base) · \(chans)"
    }

    private func channelDisplay(_ provider: String) -> String {
        let p = provider.lowercased()
        if p.contains("whatsapp") { return "WhatsApp" }
        if p.contains("messenger") { return "Messenger" }
        if p.contains("instagram") { return "Instagram" }
        return provider
    }

    /// Group the connected Meta accounts by app for the reuse picker.
    static func from(_ accounts: [AccountRow]) -> [MetaAppGroup] {
        var order: [String] = []
        var groups: [String: (appId: String?, rep: String, rows: [AccountRow])] = [:]
        for a in accounts {
            let p = a.provider.lowercased()
            guard p.contains("whatsapp") || p.contains("messenger") || p.contains("instagram") else { continue }
            let key = a.metaAppId.map { "app:\($0)" } ?? "acct:\(a.id)"
            if groups[key] == nil {
                order.append(key)
                groups[key] = (a.metaAppId, a.id, [])
            }
            groups[key]?.rows.append(a)
        }
        return order.compactMap { key in
            guard let g = groups[key] else { return nil }
            return MetaAppGroup(id: key, appId: g.appId, repKey: g.rep, channels: g.rows)
        }
    }
}

/// Add a mail account: Google / Microsoft via the loopback OAuth flow, or IMAP via
/// a manual connect form. On success the engine stores the account + starts syncing.
struct AddAccountView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var engine: EngineModel
    @EnvironmentObject private var cloud: CloudSession
    @State private var safari: IdentifiableURL?
    @State private var connecting = false
    @State private var error: String?
    @State private var showIMAP = false
    @State private var metaChannel: MetaChannelOption?
    @State private var didAutoStart = false
    /// The in-flight OAuth flow, cancelled if this view goes away mid-flow.
    @State private var oauthTask: Task<Void, Never>?
    // Cloud credential backup (docs/E2EE.md). On by default; only effective when
    // signed into an inbox2 account (the vault unlocks with that password).
    @State private var cloudBackup = true
    private var canBackup: Bool { cloud.isSignedIn }
    private var effectiveBackup: Bool { canBackup && cloudBackup }
    private let oauth = OAuthService()
    private var p: ThemePalette { theme.palette }

    /// When presented to **reconnect** an account, the provider is pre-selected and
    /// its flow auto-starts (OAuth consent, or the IMAP form) so the user doesn't
    /// re-pick it. `nil` / `false` is the normal "add a new account" entry.
    var reauth: OAuthProvider? = nil
    var reauthIMAP: Bool = false
    var reauthEmail: String? = nil

    /// Reconnecting a known account (vs. adding a fresh one) — the provider is
    /// fixed, so we skip the chooser and show just that one provider.
    private var isReauth: Bool { reauth != nil || reauthIMAP }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    if isReauth {
                        // Reconnect: a single card for the known provider.
                        SectionLabel(text: "Reconnect\(reauthEmail.map { " \($0)" } ?? "")")
                        VStack(spacing: 0) {
                            if let provider = reauth {
                                providerButton(provider)
                            } else {
                                imapButton
                            }
                        }
                        .insetCard()
                    } else {
                        // Add: email mailboxes and social channels in separate
                        // sections so the social set doesn't crowd the mailboxes.
                        SectionLabel(text: "Connect a mailbox")
                        VStack(spacing: 0) {
                            ForEach(OAuthProvider.allCases) { provider in
                                providerButton(provider)
                                SettingsDivider()
                            }
                            imapButton
                        }
                        .insetCard()

                        // Meta BYOK channels (see docs/Cloud-Push.md Meta).
                        SectionLabel(text: "Social channels")
                        VStack(spacing: 0) {
                            ForEach(MetaChannelOption.allCases) { channel in
                                if channel != MetaChannelOption.allCases.first { SettingsDivider() }
                                metaButton(channel)
                            }
                        }
                        .insetCard()

                        // Cloud credential backup toggle (docs/E2EE.md).
                        Toggle(isOn: $cloudBackup) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Save logins to your inbox2 account").font(AppFont.base).foregroundStyle(p.textPrimary)
                                Text(canBackup
                                    ? "Encrypted so only you can read them. A new device gets them back without signing in."
                                    : "Sign in to inbox2 to keep an encrypted backup.")
                                    .font(AppFont.xs).foregroundStyle(p.textSecondary)
                            }
                        }
                        .disabled(!canBackup)
                        .padding(.horizontal, Space.s4)
                    }

                    if connecting {
                        HStack(spacing: Space.s2) { ProgressView(); Text("Connecting…").foregroundStyle(p.textSecondary) }
                            .padding(.horizontal, Space.s4)
                    }
                    if let error {
                        VStack(alignment: .leading, spacing: Space.s2) {
                            Text(error).font(AppFont.xs).foregroundStyle(p.accentDanger)
                            // In reconnect there's one obvious thing to retry; in
                            // "add" the chooser is right there, so no retry button.
                            if isReauth && !connecting {
                                Button { retry() } label: {
                                    Text("Try again").font(AppFont.xs).fontWeight(.semibold).foregroundStyle(p.accentViolet)
                                }
                            }
                        }
                        .padding(.horizontal, Space.s4)
                    }
                }
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s4)
            }
            .background(p.bgBase.ignoresSafeArea())
            .navigationTitle("Add account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.foregroundStyle(p.textSecondary) }
            }
            .sheet(item: $safari, onDismiss: { oauth.cancelRedirectWait() }) { SafariView(url: $0.url) }
            .sheet(isPresented: $showIMAP) {
                IMAPConnectView { req in await connectIMAP(req) }
            }
            .sheet(item: $metaChannel) { channel in
                MetaConnectView(channel: channel, metaApps: MetaAppGroup.from(engine.accounts)) { req in await req.connect(via: engine) }
            }
            .task {
                // Reconnect: jump straight into the pre-selected provider's flow.
                guard !didAutoStart else { return }
                didAutoStart = true
                // Let this sheet (and the alert it came from) finish animating, or
                // the nested Safari sheet can be dropped the moment it appears.
                guard (try? await Task.sleep(for: .milliseconds(500))) != nil else { return }
                if let provider = reauth { startOAuth(provider) }
                else if reauthIMAP { showIMAP = true }
            }
            .onDisappear { oauthTask?.cancel() }
        }
    }

    private func providerButton(_ provider: OAuthProvider) -> some View {
        Button { startOAuth(provider) } label: { FormRow { providerRow(provider) } }
            .buttonStyle(PressableStyle())
            .disabled(connecting)
    }

    private var imapButton: some View {
        Button { showIMAP = true } label: {
            FormRow {
                HStack(spacing: Space.s3) {
                    Image(systemName: "at").font(AppFont.lg(.regular)).foregroundStyle(p.accentViolet).frame(width: 30)
                    Text("IMAP account").font(AppFont.base).foregroundStyle(p.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right").font(AppFont.xs2).foregroundStyle(p.textTertiary)
                }
            }
        }
        .buttonStyle(PressableStyle())
        .disabled(connecting)
    }

    private func metaButton(_ channel: MetaChannelOption) -> some View {
        Button { metaChannel = channel } label: {
            FormRow {
                HStack(spacing: Space.s3) {
                    ChannelAvatar(logoAsset: channel.logoAsset, size: 30)
                    Text(channel.displayName).font(AppFont.base).foregroundStyle(p.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right").font(AppFont.xs2).foregroundStyle(p.textTertiary)
                }
            }
        }
        .buttonStyle(PressableStyle())
        .disabled(connecting)
    }

    private func providerRow(_ provider: OAuthProvider) -> some View {
        HStack(spacing: Space.s3) {
            ChannelAvatar(logoAsset: provider.logoAsset, size: 30)
            Text(provider.displayName).font(AppFont.base).foregroundStyle(p.textPrimary)
            Spacer()
            Image(systemName: "chevron.right").font(AppFont.xs2).foregroundStyle(p.textTertiary)
        }
    }

    /// Re-run the reconnect flow after a failure (provider OAuth or IMAP form).
    private func retry() {
        error = nil
        if let provider = reauth { startOAuth(provider) }
        else if reauthIMAP { showIMAP = true }
    }

    private func startOAuth(_ provider: OAuthProvider) {
        connecting = true; error = nil
        oauthTask?.cancel()
        oauthTask = Task {
            do {
                let tokens = try await oauth.connect(provider: provider, loginHint: reauthEmail) { url in safari = IdentifiableURL(url: url) }
                safari = nil
                let result = await engine.addAccount(
                    providerType: provider.providerType, email: tokens.email, displayName: tokens.email,
                    authMethod: "xoauth2", accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
                    cloudBackup: effectiveBackup)
                if result.ok { finish(error: nil) }
                else { finish(error: result.value) }
            } catch {
                finish(error: Self.friendlyMessage(error))
            }
        }
    }

    /// Turn an OAuth/network failure into a short, human message — never the raw
    /// `NSError` dump (which is what `"\(error)"` produces for a `URLError`).
    static func friendlyMessage(_ error: Error) -> String {
        if let o = error as? OAuthError { return o.errorDescription ?? "Couldn't connect." }
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet:
                return "No internet connection. Reconnect and try again."
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .dnsLookupFailed:
                return "Couldn't reach the sign-in server. Check your connection and try again."
            default:
                return u.localizedDescription
            }
        }
        return error.localizedDescription
    }

    private func connectIMAP(_ req: IMAPRequest) async -> String? {
        await req.connect(via: engine, cloudBackup: effectiveBackup)
    }

    @MainActor private func finish(error: String?) {
        safari = nil
        connecting = false
        self.error = error
        if error == nil { dismiss() }
    }
}

/// A manual IMAP/SMTP mailbox. SMTP host blank → the engine derives it from the
/// IMAP host. Shared by the onboarding and Settings entry points.
struct IMAPRequest {
    let email: String
    let host: String
    let port: UInt16
    let password: String
    let smtpHost: String?
    let smtpPort: UInt16

    /// Store the account through the engine; returns nil on success or an error message.
    @MainActor func connect(via engine: EngineModel, cloudBackup: Bool = false) async -> String? {
        let result = await engine.addAccount(
            providerType: "imap", email: email, displayName: email, authMethod: "plain",
            password: password, host: host, port: port, useTls: true,
            smtpHost: smtpHost?.isEmpty == false ? smtpHost : nil, smtpPort: smtpPort, smtpUseTls: true,
            cloudBackup: cloudBackup)
        return result.ok ? nil : result.value
    }
}

/// Manual IMAP connect form — separate Incoming (IMAP) and Outgoing (SMTP) sections.
struct IMAPConnectView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let connect: (IMAPRequest) async -> String?
    @State private var email = ""
    @State private var host = ""
    @State private var port = "993"
    @State private var password = ""
    @State private var smtpHost = ""
    @State private var smtpPort = "465"
    @State private var working = false
    @State private var error: String?
    private var p: ThemePalette { theme.palette }

    private var canConnect: Bool {
        !email.isEmpty && !host.isEmpty && !password.isEmpty && !working
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s5) {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        SectionLabel(text: "Incoming (IMAP)")
                        VStack(spacing: 0) {
                            FormRow { field("Email", $email, keyboard: .emailAddress) }
                            SettingsDivider()
                            FormRow { field("IMAP host", $host, keyboard: .URL, placeholder: "imap.example.com") }
                            SettingsDivider()
                            FormRow { field("Port", $port, keyboard: .numberPad) }
                            SettingsDivider()
                            FormRow { SecureField("Password", text: $password) }
                        }
                        .insetCard()
                    }

                    VStack(alignment: .leading, spacing: Space.s2) {
                        SectionLabel(text: "Outgoing (SMTP)")
                        VStack(spacing: 0) {
                            FormRow { field("SMTP host", $smtpHost, keyboard: .URL, placeholder: "Leave blank to use the IMAP host") }
                            SettingsDivider()
                            FormRow { field("Port", $smtpPort, keyboard: .numberPad) }
                        }
                        .insetCard()
                    }

                    if let error {
                        Text(error).font(AppFont.xs).foregroundStyle(p.accentDanger)
                            .padding(.horizontal, Space.s4)
                    }
                }
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s4)
            }
            .background(p.bgBase.ignoresSafeArea())
            .navigationTitle("IMAP account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.foregroundStyle(p.textSecondary) }
                ToolbarItem(placement: .topBarTrailing) {
                    if working { ProgressView() }
                    else { Button("Connect") { submit() }.disabled(!canConnect).foregroundStyle(canConnect ? p.accentViolet : p.textMuted) }
                }
            }
        }
    }

    private func field(_ label: String, _ text: Binding<String>, keyboard: UIKeyboardType, placeholder: String = "") -> some View {
        TextField(placeholder.isEmpty ? label : placeholder, text: text)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
    }

    private func submit() {
        working = true; error = nil
        Task {
            let err = await connect(IMAPRequest(
                email: email, host: host, port: UInt16(port) ?? 993, password: password,
                smtpHost: smtpHost, smtpPort: UInt16(smtpPort) ?? 465))
            await MainActor.run {
                working = false
                if let err { error = err } else { dismiss() }
            }
        }
    }
}

/// A BYOK Meta connection. The app secret + System User token are stored encrypted
/// on-device and never sent to our servers.
struct MetaRequest {
    let channel: MetaChannelOption
    let displayName: String?
    let appId: String
    let appSecret: String
    let systemUserToken: String
    let facebookPageId: String?
    let instagramAccountId: String?
    let whatsappPhoneNumberId: String?
    let whatsappBusinessAccountId: String?
    /// Reuse an existing Meta account's app credentials instead of `appSecret` /
    /// `systemUserToken` (those are left empty in that case).
    var reuseCredentialsFrom: String? = nil

    @MainActor func connect(via engine: EngineModel) async -> String? {
        let result = await engine.addMetaAccount(
            channel: channel.providerType, displayName: displayName, appId: appId,
            appSecret: appSecret, systemUserToken: systemUserToken,
            facebookPageId: facebookPageId, instagramAccountId: instagramAccountId,
            whatsappPhoneNumberId: whatsappPhoneNumberId,
            whatsappBusinessAccountId: whatsappBusinessAccountId,
            reuseCredentialsFrom: reuseCredentialsFrom)
        return result.ok ? nil : result.value
    }
}

/// BYOK Meta connect form. Collects the shared app-secret bundle for every channel
/// plus the channel-specific asset ids.
struct MetaConnectView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let channel: MetaChannelOption
    /// Existing Meta apps whose credentials can be reused (empty → no toggle).
    var metaApps: [MetaAppGroup] = []
    let connect: (MetaRequest) async -> String?

    @State private var displayName = ""
    @State private var appId = ""
    @State private var appSecret = ""
    @State private var token = ""
    @State private var pageId = ""
    @State private var igId = ""
    @State private var phoneId = ""
    @State private var wabaId = ""
    @State private var working = false
    @State private var error: String?
    // Credential source: reuse an existing app vs. enter new. Defaults to reuse
    // when any app exists (set in .onAppear); `reuseFrom` is the source key.
    @State private var reuseExisting = false
    @State private var reuseFrom = ""
    private var p: ThemePalette { theme.palette }

    private var reusing: Bool { reuseExisting && !metaApps.isEmpty }

    private var canConnect: Bool {
        guard !working else { return false }
        // New credentials require app secret + System User token; reuse needs a
        // selected source. Either way, one asset id per channel (the secondary —
        // phone / IG account — is auto-derived on connect).
        if reusing {
            if reuseFrom.isEmpty { return false }
        } else if appSecret.isEmpty || token.isEmpty {
            return false
        }
        switch channel {
        case .whatsapp: return !wabaId.isEmpty
        case .messenger: return !pageId.isEmpty
        case .instagram: return !pageId.isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s5) {
                    // Connecting auto-subscribes the app's webhook + starts receiving.
                    Text("Use your own Meta app. Its keys stay encrypted on this device. We set up its webhook for you.")
                        .font(AppFont.xs).foregroundStyle(p.textSecondary)
                        .padding(.horizontal, Space.s4)

                    VStack(alignment: .leading, spacing: Space.s2) {
                        SectionLabel(text: "App credentials")
                        if !metaApps.isEmpty {
                            Picker("Credentials", selection: $reuseExisting) {
                                Text("Use existing").tag(true)
                                Text("Add new").tag(false)
                            }
                            .pickerStyle(.segmented)
                        }
                        if reusing {
                            // Reuse an existing app's secret + System User token —
                            // only the new asset id is needed below.
                            VStack(spacing: 0) {
                                FormRow {
                                    Picker("Meta app", selection: $reuseFrom) {
                                        ForEach(metaApps) { app in
                                            Text(app.label).tag(app.repKey)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .insetCard()
                            Text("Uses the secret and System User token you saved for this app.")
                                .font(AppFont.xs2).foregroundStyle(p.textTertiary)
                        } else {
                            // App id + display name are auto-derived from the token.
                            VStack(spacing: 0) {
                                FormRow { SecureField("App secret", text: $appSecret) }
                                SettingsDivider()
                                FormRow { SecureField("System User token", text: $token) }
                            }
                            .insetCard()
                        }
                    }

                    VStack(alignment: .leading, spacing: Space.s2) {
                        SectionLabel(text: "Assets")
                        VStack(spacing: 0) {
                            // One asset id per channel; the secondary (phone / IG
                            // account) is auto-detected on connect — no field.
                            if channel == .whatsapp {
                                FormRow { field("WhatsApp Business Account ID", $wabaId, keyboard: .numberPad) }
                            } else {
                                FormRow { field("Facebook Page ID", $pageId, keyboard: .numberPad) }
                            }
                        }
                        .insetCard()
                    }

                    if let error {
                        Text(error).font(AppFont.xs).foregroundStyle(p.accentDanger)
                            .padding(.horizontal, Space.s4)
                    }
                }
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s4)
            }
            .background(p.bgBase.ignoresSafeArea())
            .onAppear {
                // Default to reuse when an app already exists (the toggle's point).
                if !metaApps.isEmpty {
                    reuseExisting = true
                    if reuseFrom.isEmpty { reuseFrom = metaApps[0].repKey }
                }
            }
            .navigationTitle("Connect \(channel.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.foregroundStyle(p.textSecondary) }
                ToolbarItem(placement: .topBarTrailing) {
                    if working { ProgressView() }
                    else { Button("Connect") { submit() }.disabled(!canConnect).foregroundStyle(canConnect ? p.accentViolet : p.textMuted) }
                }
            }
        }
    }

    private func field(_ label: String, _ text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        TextField(label, text: text)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
    }

    private func submit() {
        working = true; error = nil
        Task {
            // Reuse path: core copies the app secret + token from the chosen
            // account, so send them empty and pass the source key.
            let req = MetaRequest(
                channel: channel, displayName: displayName.isEmpty ? nil : displayName,
                appId: reusing ? "" : appId,
                appSecret: reusing ? "" : appSecret,
                systemUserToken: reusing ? "" : token,
                facebookPageId: pageId.isEmpty ? nil : pageId,
                instagramAccountId: igId.isEmpty ? nil : igId,
                whatsappPhoneNumberId: phoneId.isEmpty ? nil : phoneId,
                whatsappBusinessAccountId: wabaId.isEmpty ? nil : wabaId,
                reuseCredentialsFrom: reusing ? reuseFrom : nil)
            let err = await connect(req)
            await MainActor.run {
                working = false
                if let err { error = err } else { dismiss() }
            }
        }
    }
}
