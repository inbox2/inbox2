import SwiftUI
import OSLog
import UIKit

// MARK: - Shared settings chrome (flat rows on the dark surface)

/// Section header — small uppercase, muted.
struct SettingsHeader: View {
    @Environment(\.theme) private var theme
    let text: String?
    var body: some View {
        if let text {
            Text(text.uppercased()).font(AppFont.section(12, .semibold)).tracking(0.8)
                .foregroundStyle(theme.palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.s5).padding(.top, Space.s6).padding(.bottom, Space.s2)
        } else {
            Color.clear.frame(height: Space.s6)
        }
    }
}

/// Groovebox: a run of settings rows sits on a solid island panel. A no-op under
/// every other theme (wrap the rows in `VStack(spacing: 0)`, which lays out the
/// same as the flat list it replaces).
/// `gap` adds a top margin (Groovebox only) for a group that directly follows another.
private struct SettingsGroup: ViewModifier {
    @Environment(\.theme) private var theme
    var gap = false
    func body(content: Content) -> some View {
        if let r = theme.palette.panelRadius {
            content
                .padding(.vertical, Space.s2)
                .background(theme.palette.bgPanel, in: RoundedRectangle(cornerRadius: r, style: .continuous))
                .padding(.horizontal, Space.s3)
                .padding(.top, gap ? Space.s3 : 0)
        } else {
            content
        }
    }
}

/// Groovebox: the chosen option's row is a solid fill with a lavender ring. Drawn
/// in the background, so layout is untouched; a no-op under every other theme.
private struct SettingsSelected: ViewModifier {
    @Environment(\.theme) private var theme
    let on: Bool
    func body(content: Content) -> some View {
        content.background {
            if on, let fill = theme.palette.selectedRowFill {
                let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                shape.fill(fill)
                    .overlay { if let outline = theme.palette.selectionOutline { shape.strokeBorder(outline, lineWidth: 1.5) } }
                    .padding(.horizontal, Space.s2).padding(.vertical, 2)
            }
        }
    }
}

extension View {
    func settingsGroup(gap: Bool = false) -> some View { modifier(SettingsGroup(gap: gap)) }
    func settingsSelected(_ on: Bool) -> some View { modifier(SettingsSelected(on: on)) }
}

/// Hairline inset divider.
struct SettingsDivider: View {
    @Environment(\.theme) private var theme
    var body: some View { Rectangle().fill(theme.palette.borderSubtle).frame(height: 0.5).padding(.leading, Space.s5) }
}

/// A scroll container with the flat dark background + a title, and an optional
/// top-right accessory (e.g. a "+" add button, following iOS nav-bar semantics).
struct SettingsScaffold<Content: View, Trailing: View>: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var chrome: ChromeModel
    let title: AttributedString
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(title: String,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = AttributedString(title)
        self.trailing = trailing
        self.content = content
    }

    /// Styled-title variant (e.g. `inbox2 mx` with the `mx` run in code font).
    init(styledTitle: AttributedString,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = styledTitle
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(styled: title, showBack: true) { trailing() }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content(); Color.clear.frame(height: 60) }
            }
            .scrollContentBackground(.hidden)
        }
        .pageBackground()
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        // Settings detail panels are detail screens like any other — hide the
        // floating nav while one is on screen (counter balances nested pushes).
        .onAppear { chrome.detailScreens += 1 }
        .onDisappear { chrome.detailScreens = max(0, chrome.detailScreens - 1) }
    }
}

/// A "+" add button for a settings panel header (iOS nav-bar convention).
struct SettingsAddButton: View {
    @Environment(\.theme) private var theme
    var disabled: Bool = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(AppFont.lg)
                .foregroundStyle(disabled ? theme.palette.textMuted : theme.palette.accentViolet)
                .frame(width: 34, height: 34).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// Icon + label (+ chevron) menu row used by the level-1 list.
struct SettingsMenuRow: View {
    @Environment(\.theme) private var theme
    let icon: String
    let title: AttributedString
    init(icon: String, title: String) { self.icon = icon; self.title = AttributedString(title) }
    init(icon: String, styledTitle: AttributedString) { self.icon = icon; self.title = styledTitle }
    var body: some View {
        HStack(spacing: Space.s3) {
            Image(systemName: icon).font(AppFont.body).foregroundStyle(theme.palette.textSecondary).frame(width: 28)
            Text(title).font(AppFont.md(.regular)).foregroundStyle(theme.palette.textSecondary)
            Spacer()
            Image(systemName: "chevron.right").font(AppFont.xs(.semibold)).foregroundStyle(theme.palette.textMuted)
        }
        .padding(.horizontal, Space.s5).frame(minHeight: 54).contentShape(Rectangle())
    }
}

/// Title + multi-line explanatory body — for panels that describe a desktop-managed
/// or not-yet-on-mobile capability.
struct SettingsInfo: View {
    @Environment(\.theme) private var theme
    let icon: String
    let title: String
    let body0: String
    var note: String? = nil
    /// When true, the inbox2 brand logo replaces the SF Symbol icon (used by the
    /// inbox2 mx state so it leads with the brand).
    var brandLogo: Bool = false
    /// When set, names an SF Symbol to lead with as a gradient hero glyph (instead of the
    /// plain `icon`) — so settings zero-states match the app's empty states. No baked
    /// background, so it reads in both dark and light.
    var heroSymbol: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            if let heroSymbol {
                GradientGlyph(systemImage: heroSymbol, size: 52)
                    .frame(height: 72, alignment: .leading)
            } else if brandLogo {
                InboxLogoTile(size: 60)
            } else {
                Image(systemName: icon).font(AppFont.glyph(34)).foregroundStyle(theme.palette.accentViolet)
            }
            Text(title).font(AppFont.lg).foregroundStyle(theme.palette.textPrimary)
            Text(body0).font(AppFont.sm).foregroundStyle(theme.palette.textSecondary)
            if let note {
                Text(note).font(AppFont.xs).foregroundStyle(theme.palette.textTertiary)
                    .padding(.top, Space.s2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.s5)
    }
}

// MARK: - Level 1 — the settings menu

/// Settings — a level-based menu (mirrors the desktop SettingsPage nav): grouped
/// categories that push to detail panels. Org-only sections are omitted (iOS runs
/// in local standalone mode).
struct SettingsView: View {
    @Environment(\.theme) private var theme
    /// Set when shown as a sheet (iPad): adds a close button top right.
    var onClose: (() -> Void)? = nil
    private var p: ThemePalette { theme.palette }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScreenHeader("Settings") {
                    if let onClose { IconButton("xmark", tint: p.textSecondary, action: onClose).accessibilityLabel("Close") }
                }
                ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsHeader(text: "General")
                    VStack(spacing: 0) {
                        menuLink("gearshape", "Preferences") { PreferencesPanel() }
                        SettingsDivider()
                        menuLink("link", "Connected accounts") { ConnectedAccountsPanel() }
                        SettingsDivider()
                        menuLink("building.2", styled: .inbox2mx(monoSize: 15)) { CloudAccountPanel() }
                        SettingsDivider()
                        menuLink("photo", "Theme") { ThemePanel() }
                    }
                    .settingsGroup()

                    SettingsHeader(text: "Intelligence")
                    VStack(spacing: 0) {
                        menuLink("person.2", "Contacts") { EnrichmentPanel() }
                        SettingsDivider()
                        menuLink("brain", "On-device AI") { BridgeVoicePanel() }
                        SettingsDivider()
                        menuLink("sparkles.rectangle.stack", "Triage & sync") { TriageSyncPanel() }
                        SettingsDivider()
                        menuLink("line.3.horizontal.decrease", "Auto rules") { AutoRulesPanel() }
                    }
                    .settingsGroup()

                    SettingsHeader(text: "Security & compliance")
                    menuLink("terminal", "App logs") { AppLogsPanel() }
                        .settingsGroup()

                    SettingsHeader(text: nil)
                    NavigationLink { DevModePanel() } label: {
                        HStack(spacing: Space.s2) {
                            Image(systemName: "ladybug").font(AppFont.sm(.semibold))
                            Text("DEV MODE").font(AppFont.sm(.bold)).tracking(0.6)
                        }
                        .foregroundStyle(p.keycapLabel(.secondary, or: p.accentViolet))
                        .frame(maxWidth: .infinity).padding(.vertical, Space.s3)
                        .keycapSurface(.secondary, radius: Radius.lg) {
                            RoundedRectangle(cornerRadius: Radius.lg).stroke(p.accentViolet.opacity(0.5), lineWidth: 1)
                        }
                        .padding(.horizontal, Space.s5).padding(.top, Space.s2)
                    }
                    .buttonStyle(.plain)

                    Color.clear.frame(height: 90)
                }
                }
                .scrollContentBackground(.hidden)
            }
            .pageBackground()
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func menuLink<Dest: View>(_ icon: String, _ title: String, @ViewBuilder _ dest: () -> Dest) -> some View {
        NavigationLink { dest() } label: { SettingsMenuRow(icon: icon, title: title) }
            .buttonStyle(.plain)
    }

    /// Menu link with a styled label (e.g. `inbox2 mx` with the `mx` run in code font).
    private func menuLink<Dest: View>(_ icon: String, styled title: AttributedString, @ViewBuilder _ dest: () -> Dest) -> some View {
        NavigationLink { dest() } label: { SettingsMenuRow(icon: icon, styledTitle: title) }
            .buttonStyle(.plain)
    }
}

// MARK: - Level 2 — panels

/// Preferences — notifications + reading behavior.
struct PreferencesPanel: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var markRead: MarkReadManager
    @EnvironmentObject private var engine: EngineModel
    @AppStorage(NotificationManager.newMailKey) private var notifyNewMail = true
    @AppStorage(NotificationManager.soundKey) private var notifySound = true
    @AppStorage(MeetingAlarms.enabledKey) private var meetingAlarm = false
    @AppStorage(MeetingAlarms.leadKey) private var alarmLead = 5
    @ObservedObject private var alarms = MeetingAlarms.shared
    private var p: ThemePalette { theme.palette }

    /// How early the alarm goes off. Anything under a minute isn't enough warning
    /// to walk anywhere; anything over 30 you'd forget again.
    private static let leadChoices = [1, 2, 5, 10, 15, 30]

    var body: some View {
        SettingsScaffold(title: "Preferences") {
            SettingsHeader(text: "Notifications")
            VStack(spacing: 0) {
                Toggle("New mail", isOn: $notifyNewMail).tint(p.toggle)
                    .font(AppFont.md(.regular)).foregroundStyle(p.textSecondary)
                    .padding(.horizontal, Space.s5).frame(minHeight: 52)
                SettingsDivider()
                Toggle("Sound", isOn: $notifySound).tint(p.toggle)
                    .font(AppFont.md(.regular)).foregroundStyle(p.textSecondary)
                    .padding(.horizontal, Space.s5).frame(minHeight: 52)
                SettingsDivider()
                Toggle("Meeting alarm", isOn: $meetingAlarm).tint(p.toggle)
                    .font(AppFont.md(.regular)).foregroundStyle(p.textSecondary)
                    .padding(.horizontal, Space.s5).frame(minHeight: 52)
                if meetingAlarm {
                    SettingsDivider()
                    Menu {
                        Picker("", selection: $alarmLead) {
                            ForEach(Self.leadChoices, id: \.self) { Text("\($0) min before").tag($0) }
                        }
                    } label: {
                        HStack {
                            Text("Alarm at").font(AppFont.md(.regular)).foregroundStyle(p.textSecondary)
                            Spacer()
                            Text("\(alarmLead) min before").font(AppFont.body).foregroundStyle(p.textTertiary)
                            Image(systemName: "chevron.up.chevron.down").font(AppFont.xs2).foregroundStyle(p.textMuted)
                        }
                        .padding(.horizontal, Space.s5).frame(minHeight: 52)
                    }
                    SettingsDivider()
                    Button {
                        Task { await MeetingAlarms.shared.fireTest() }
                    } label: {
                        HStack {
                            Text("Test alarm").font(AppFont.md(.regular)).foregroundStyle(p.textSecondary)
                            Spacer()
                            Text("in 5s").font(AppFont.body).foregroundStyle(p.textTertiary)
                            Image(systemName: "bell.badge").font(AppFont.sm).foregroundStyle(p.accentViolet)
                        }
                        .padding(.horizontal, Space.s5).frame(minHeight: 52).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .settingsGroup()
            Text("Rings for 25 seconds before each meeting, even in Focus. The silent switch still mutes it.")
                .font(AppFont.xs2).foregroundStyle(p.textTertiary)
                .padding(.horizontal, Space.s5).padding(.top, Space.s2)
            // The feature fails silently by definition, so say out loud whether iOS
            // is currently letting it through.
            if meetingAlarm, let status = alarms.systemStatus {
                Text(status).font(AppFont.xs2).foregroundStyle(p.textTertiary)
                    .padding(.horizontal, Space.s5).padding(.top, Space.s2)
            }

            SettingsHeader(text: "Reading")
            VStack(spacing: 0) {
                Menu {
                    Picker("", selection: $markRead.mode) {
                        ForEach(MarkReadMode.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    HStack {
                        Text("Mark as read").font(AppFont.md(.regular)).foregroundStyle(p.textSecondary)
                        Spacer()
                        Text(markRead.mode.title).font(AppFont.body).foregroundStyle(p.textTertiary)
                        Image(systemName: "chevron.up.chevron.down").font(AppFont.xs2).foregroundStyle(p.textMuted)
                    }
                    .padding(.horizontal, Space.s5).frame(minHeight: 52)
                }
                if markRead.mode == .delay {
                    SettingsDivider()
                    HStack {
                        Text("Delay").font(AppFont.md(.regular)).foregroundStyle(p.textSecondary)
                        Spacer()
                        Stepper("\(markRead.delaySeconds)s", value: $markRead.delaySeconds, in: 1...30).labelsHidden()
                        Text("\(markRead.delaySeconds)s").font(AppFont.body).foregroundStyle(p.textTertiary).frame(width: 36, alignment: .trailing)
                    }
                    .padding(.horizontal, Space.s5).frame(minHeight: 52)
                }
            }
            .settingsGroup()
            Text(markRead.mode.detail).font(AppFont.xs2).foregroundStyle(p.textTertiary)
                .padding(.horizontal, Space.s5).padding(.top, Space.s2)
        }
        // Turning the alarm on/off or changing the lead re-arms (or clears) every
        // pending alarm — they're scheduled ahead, so nothing else would pick it up.
        .task { await alarms.refreshSystemStatus() }
        .onChange(of: meetingAlarm) { _, _ in
            Task { await MeetingAlarms.shared.reconcile(engine: engine, force: true) }
        }
        .onChange(of: alarmLead) { _, _ in
            Task { await MeetingAlarms.shared.reconcile(engine: engine, force: true) }
        }
    }
}

/// Theme — appearance picker.
struct ThemePanel: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var icon: AppIconOption = .sun
    private var p: ThemePalette { theme.palette }
    var body: some View {
        SettingsScaffold(title: "Theme") {
            SettingsHeader(text: "Appearance")
            VStack(spacing: 0) {
                ForEach(Appearance.allCases) { appearance in
                    Button {
                    // Entering Groovebox brings its icon along — once, on the switch
                    // itself, so a later manual icon pick sticks. Leaving it changes nothing.
                    if appearance == .groovebox, themeManager.appearance != .groovebox {
                        Task { icon = await AppIconOption.apply(.groovebox) }
                    }
                    themeManager.appearance = appearance
                } label: {
                        HStack {
                            Text(appearance.label).font(AppFont.md(.regular)).foregroundStyle(p.textSecondary)
                            Spacer()
                            if themeManager.appearance == appearance {
                                Image(systemName: "checkmark").font(AppFont.sm(.semibold)).foregroundStyle(p.accentViolet)
                            }
                        }
                        .padding(.horizontal, Space.s5).frame(minHeight: 52).contentShape(Rectangle())
                        .settingsSelected(themeManager.appearance == appearance)
                    }
                    .buttonStyle(.plain)
                    if appearance != Appearance.allCases.last { SettingsDivider() }
                }
            }
            .settingsGroup()
            Text("Dark is the default. System follows your device setting.")
                .font(AppFont.xs2).foregroundStyle(p.textTertiary).padding(.horizontal, Space.s5).padding(.top, Space.s2)

            SettingsHeader(text: "App icon")
            VStack(spacing: 0) {
                ForEach(AppIconOption.allCases) { option in
                    Button {
                        Task { icon = await AppIconOption.apply(option) }
                    } label: {
                        AppIconRow(option: option, selected: icon == option)
                    }
                    .buttonStyle(.plain)
                    if option != AppIconOption.allCases.last { SettingsDivider() }
                }
            }
            .settingsGroup()
            Text("Changes your home screen icon. iOS asks you to confirm the first time.")
                .font(AppFont.xs2).foregroundStyle(p.textTertiary).padding(.horizontal, Space.s5).padding(.top, Space.s2)
        }
        .onAppear { icon = AppIconOption.current }
    }
}

/// One row of the app-icon picker: artwork, name, blurb, tick.
private struct AppIconRow: View {
    @Environment(\.theme) private var theme
    let option: AppIconOption
    let selected: Bool
    private var p: ThemePalette { theme.palette }

    var body: some View {
        HStack(spacing: Space.s3) {
            // UIImage(named:), not Image(_:) — SwiftUI's initialiser only searches
            // asset catalogs, and alternate icons have to be loose bundle files.
            Image(uiImage: UIImage(named: option.previewImageName) ?? UIImage())
                .resizable().frame(width: 44, height: 44)
                // iOS masks the real icon; the picker has to round it itself.
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(p.textTertiary.opacity(0.25), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(option.label).font(AppFont.md(.regular)).foregroundStyle(p.textSecondary)
                Text(option.blurb).font(AppFont.xs2).foregroundStyle(p.textTertiary)
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark").font(AppFont.sm(.semibold)).foregroundStyle(p.accentViolet)
            }
        }
        .padding(.horizontal, Space.s5).frame(minHeight: 64).contentShape(Rectangle())
        .settingsSelected(selected)
    }
}

/// Connected accounts — the account list + add.
struct ConnectedAccountsPanel: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var engine: EngineModel
    @State private var showAddAccount = false
    @State private var reconnectTarget: AccountRow?
    @State private var pendingRemove: AccountRow?
    @State private var removing = false
    private var p: ThemePalette { theme.palette }

    /// Map an account's stored provider type back to the OAuth provider so reconnect
    /// can pre-select it (nil for IMAP / unknown).
    private func oauthProvider(for acct: AccountRow) -> OAuthProvider? {
        OAuthProvider.allCases.first { $0.providerType == acct.provider }
    }

    /// Status-dot colour: green = healthy, amber = needs re-auth (actionable),
    /// red = transient sync error, muted = not connected yet.
    private func statusColor(_ acct: AccountRow) -> Color {
        switch acct.status {
        case AccountStatusValue.connected: return p.accentSuccess
        case AccountStatusValue.needsReauth: return p.accentAmber
        case AccountStatusValue.error: return p.accentDanger
        default: return p.textMuted
        }
    }
    var body: some View {
        SettingsScaffold(title: "Connected accounts", trailing: {
            SettingsAddButton { showAddAccount = true }
        }) {
            if engine.accounts.isEmpty {
                SettingsInfo(icon: "link", title: "No accounts",
                    body0: "Connect a Gmail, Outlook, or IMAP mailbox with the + above.",
                    heroSymbol: "person.crop.circle.badge.plus")
            } else {
                SettingsHeader(text: "Accounts")
            }
            VStack(spacing: 0) {
                ForEach(Array(engine.accounts.enumerated()), id: \.element.id) { i, acct in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: Space.s3) {
                            ChannelAvatar(logoAsset: ChannelAvatar.brandLogo(for: acct.provider),
                                          initials: String(acct.email.prefix(2)).uppercased(),
                                          size: 38)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(acct.email).font(AppFont.md(.regular)).foregroundStyle(p.textSecondary)
                                Text(acct.provider).font(AppFont.xs2).foregroundStyle(p.textTertiary)
                            }
                            Spacer()
                            Circle().fill(statusColor(acct)).frame(width: 8, height: 8)
                            Menu {
                                Button { reconnectTarget = acct } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                                Button(role: .destructive) { pendingRemove = acct } label: {
                                    Label("Remove account", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis").font(AppFont.md(.semibold))
                                    .foregroundStyle(p.textTertiary).frame(width: 30, height: 30).contentShape(Rectangle())
                            }
                        }
                        .frame(minHeight: 56)
                        if acct.isFailing { AccountErrorBanner(acct: acct) { reconnectTarget = acct } }
                        OpenTrackingRow(accountKey: acct.id, provider: acct.provider, email: acct.email)
                    }
                    .padding(.horizontal, Space.s5)
                    if i < engine.accounts.count - 1 { SettingsDivider() }
                }
            }
            .settingsGroup()

            // Privacy / Cloud Proxy lives at the bottom of Connected accounts, as on
            // desktop — it governs how mail from any connected account renders.
            PrivacyProxySection()
        }
        .sheet(isPresented: $showAddAccount) { AddAccountView() }
        .sheet(item: $reconnectTarget) { acct in
            AddAccountView(reauth: oauthProvider(for: acct),
                           reauthIMAP: oauthProvider(for: acct) == nil,
                           reauthEmail: acct.email)
        }
        .confirmationDialog(
            pendingRemove.map { "Remove \($0.email)?" } ?? "",
            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove account", role: .destructive) {
                guard let acct = pendingRemove else { return }
                pendingRemove = nil
                removing = true
                Task {
                    _ = await engine.removeAccount(accountKey: acct.id)
                    removing = false
                }
            }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: {
            Text("Its mail, calendars and sign-in leave this device. The mailbox itself keeps everything.")
        }
    }
}

/// inbox2 domain — sign in to the API-backed team pool ("MX"), or show the
/// signed-in identity + org and sign out. Distinct from Connected accounts (the
/// offline Gmail/Outlook/IMAP mailboxes); this is the shared-domain mode.
struct CloudAccountPanel: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var cloud: CloudSession
    // Sign-out also tears down the credential-vault session on the engine.
    @EnvironmentObject private var engine: EngineModel
    @State private var showLogin = false
    @State private var signingOut = false
    private var p: ThemePalette { theme.palette }

    var body: some View {
        SettingsScaffold(styledTitle: .inbox2mx(monoSize: 17, weight: .semibold)) {
            switch cloud.state {
            case .loading:
                HStack(spacing: Space.s2) { ProgressView(); Text("Checking session…").foregroundStyle(p.textSecondary) }
                    .padding(.horizontal, Space.s5).frame(minHeight: 56)
            case .signedOut:
                SettingsInfo(icon: "building.2.crop.circle", title: "Not connected",
                    body0: "Sign in to see your domain's inbox next to your own accounts.",
                    note: "Your Gmail, Outlook and IMAP accounts stay on this device.",
                    brandLogo: true)
                VStack(spacing: 0) {
                    Button { showLogin = true } label: {
                        HStack(spacing: Space.s3) {
                            Image(systemName: "person.crop.circle.badge.plus").font(AppFont.glyph(19)).foregroundStyle(p.accentViolet)
                            Text("Sign in to inbox2").font(AppFont.body).foregroundStyle(p.accentViolet)
                            Spacer()
                        }
                        .padding(.horizontal, Space.s5).frame(minHeight: 52).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .settingsGroup()
            case .signedIn:
                SettingsHeader(text: "Signed in")
                VStack(spacing: 0) {
                    HStack(spacing: Space.s3) {
                        Avatar(initials: String((cloud.user?.label ?? "?").prefix(2)).uppercased(),
                               size: 40, seed: MailAddress.seed(cloud.user?.billingEmail ?? cloud.user?.username ?? "?"))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(cloud.user?.label ?? "—").font(AppFont.md(.regular)).foregroundStyle(p.textSecondary)
                            if let email = cloud.user?.billingEmail, !email.isEmpty {
                                Text(email).font(AppFont.xs2).foregroundStyle(p.textTertiary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, Space.s5).frame(minHeight: 58)
                }
                .settingsGroup()

                if !cloud.orgs.isEmpty {
                    SettingsHeader(text: cloud.orgs.count == 1 ? "Domain" : "Domains")
                    VStack(spacing: 0) {
                        ForEach(cloud.orgs) { org in
                            Button { cloud.selectOrg(org.id) } label: {
                                HStack(spacing: Space.s3) {
                                    Image(systemName: "globe").font(AppFont.md(.regular)).foregroundStyle(p.accentViolet).frame(width: 26)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(org.name).font(AppFont.md(.regular)).foregroundStyle(p.textSecondary)
                                        if let d = org.domain, !d.isEmpty { Text(d).font(AppFont.xs3).foregroundStyle(p.textTertiary) }
                                    }
                                    Spacer()
                                    if org.id == cloud.currentOrgId {
                                        Image(systemName: "checkmark").font(AppFont.xs(.semibold)).foregroundStyle(p.accentSuccess)
                                    }
                                }
                                .padding(.horizontal, Space.s5).frame(minHeight: 54).contentShape(Rectangle())
                                .settingsSelected(org.id == cloud.currentOrgId)
                            }
                            .buttonStyle(.plain)
                            SettingsDivider()
                        }
                    }
                    .settingsGroup()
                }

                VStack(spacing: 0) {
                    Button(role: .destructive) {
                        signingOut = true
                        // Tear down the credential vault session too (docs/E2EE.md), so a
                        // different inbox2 account can't upload into this one's vault.
                        engine.clearVaultSession()
                        Task { await cloud.signOut(); await MainActor.run { signingOut = false } }
                    } label: {
                        HStack(spacing: Space.s3) {
                            Image(systemName: "rectangle.portrait.and.arrow.right").font(AppFont.lg(.regular)).foregroundStyle(p.accentDanger)
                            Text("Sign out").font(AppFont.body).foregroundStyle(p.accentDanger)
                            Spacer()
                            if signingOut { ProgressView() }
                        }
                        .padding(.horizontal, Space.s5).frame(minHeight: 52).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(signingOut)
                }
                .settingsGroup(gap: true)
            }
        }
        .sheet(isPresented: $showLogin) { CloudLoginView() }
    }
}

/// Cloud Proxy — remote-image loading policy + the personal API key the proxy uses.
/// Stacked at the bottom of Connected accounts, mirroring the desktop settings model
/// (`SettingsPage` renders `PrivacySettings` as a second panel inside the Connected
/// accounts section). Remote images are always blocked until requested; the toggle
/// decides whether requested images load privately through the Rails proxy (hiding
/// your IP from the sender). The proxy authenticates with the personal API key
/// entered here, or — when signed in to inbox2 mx — that session token automatically.
// Per-channel open tracking (docs/Open-Tracking.md): a compact toggle + optional
// custom tracking host, wired to the engine's per-account settings. Mail channels
// only (a WhatsApp/Messenger channel can't carry an email pixel).
struct OpenTrackingRow: View {
    let accountKey: String
    let provider: String
    let email: String
    @Environment(\.theme) private var theme
    @EnvironmentObject private var engine: EngineModel
    @EnvironmentObject private var cloud: CloudSession
    private var p: ThemePalette { theme.palette }

    @State private var loaded = false
    @State private var enabled = false
    @State private var custom = false
    @State private var host = ""

    private static let mailProviders = ["gmail", "microsoft", "office365", "outlook", "imap"]
    private var supported: Bool {
        let pv = provider.lowercased()
        return Self.mailProviders.contains { pv.contains($0) }
    }

    // Recommend a subdomain of the channel's OWN sending domain (track.tuli.com for
    // waseem@tuli.com) — same-domain as the From address lowers spam scoring.
    private var suggestedHost: String {
        let domain = email.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
        return domain.isEmpty ? "track.yourdomain.com" : "track.\(domain)"
    }

    var body: some View {
        Group {
            if supported && loaded {
                VStack(alignment: .leading, spacing: Space.s2) {
                    if !cloud.isSignedIn {
                        // Available only with a cloud identity (mx or api token) — that's how the
                        // config is saved/synced across devices (docs/Open-Tracking.md).
                        Text("Sign in to inbox2 to use open tracking. It applies on all your devices.")
                            .font(AppFont.xs2).foregroundStyle(p.textTertiary)
                    } else {
                    Toggle(isOn: Binding(get: { enabled }, set: { setEnabled($0) })) {
                        Label("Open tracking", systemImage: "eye.fill")
                            .font(AppFont.base).foregroundStyle(p.textSecondary)
                    }
                    .tint(p.toggle)

                    if enabled {
                        Picker("", selection: Binding(get: { custom }, set: { pickCustom($0) })) {
                            Text("inbox2 domain").tag(false)
                            Text("Your domain").tag(true)
                        }
                        .pickerStyle(.segmented)

                        if custom {
                            HStack(spacing: Space.s2) {
                                TextField(suggestedHost, text: $host)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .font(AppFont.mono(14)).foregroundStyle(p.textPrimary)
                                    .padding(.horizontal, Space.s3).frame(height: 36)
                                    .background(RoundedRectangle(cornerRadius: Radius.md).fill(p.bgInput))
                                Button("Save") { apply(enabled: true, host: host.trimmed) }
                                    .font(AppFont.sm(.semibold)).foregroundStyle(p.accentViolet)
                                    .disabled(host.trimmed.isEmpty)
                            }
                            Text("Use a subdomain of your sending domain so less mail lands in spam. Point a CNAME at visit.inbox2.com. On Cloudflare, keep the cloud grey.")
                                .font(AppFont.xs3).foregroundStyle(p.textTertiary)
                        }
                    }
                    }
                }
                .padding(.top, Space.s2).padding(.bottom, Space.s2)
            }
        }
        .task(id: accountKey) {
            // Cloud is the source of truth (syncs across devices); mirror into the
            // local engine so the pixel injection honors it, then fall back to the
            // local mirror when offline / signed out.
            var s: (enabled: Bool, trackDomain: String?)? = nil
            if cloud.isSignedIn {
                if let ch = await cloud.channelTracking().first(where: { $0.emailAddress.lowercased() == email.lowercased() }) {
                    engine.setOpenTracking(accountKey: accountKey, enabled: ch.openTrackingEnabled, trackDomain: ch.trackDomain)
                    s = (ch.openTrackingEnabled, ch.trackDomain)
                }
            }
            // `await` can't live inside a `??` autoclosure — use an if-expression.
            let local = if let s { s } else { await engine.openTrackingSettings(accountKey: accountKey) }
            enabled = local.enabled
            host = local.trackDomain ?? ""
            custom = local.trackDomain != nil
            loaded = true
        }
    }

    // Persist locally (drives injection) AND to the cloud (syncs to other devices).
    private func apply(enabled en: Bool, host h: String?) {
        engine.setOpenTracking(accountKey: accountKey, enabled: en, trackDomain: h)
        Task { await cloud.saveChannelTracking(email: email, enabled: en, trackDomain: h) }
    }
    private func setEnabled(_ v: Bool) {
        enabled = v
        apply(enabled: v, host: custom ? host.trimmed : nil)
    }
    private func pickCustom(_ v: Bool) {
        custom = v
        if v {
            if host.isEmpty { host = suggestedHost }
        } else {
            host = ""
            apply(enabled: enabled, host: nil)
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct PrivacyProxySection: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var privacy: PrivacyStore
    @EnvironmentObject private var cloud: CloudSession
    private var p: ThemePalette { theme.palette }

    private let deviceLink = DeviceLinkService()
    @State private var safari: IdentifiableURL?
    @State private var linking = false

    var body: some View {
        Group {
            SettingsHeader(text: "Cloud proxy")
            VStack(spacing: 0) {
                Toggle("Load remote images privately", isOn: $privacy.proxyEnabled)
                    .tint(p.toggle)
                    .font(AppFont.md(.regular)).foregroundStyle(p.textSecondary)
                    .padding(.horizontal, Space.s5).frame(minHeight: 52)
            }
            .settingsGroup()
            Text("Loading an image tells the sender you opened the mail and roughly where you are. When on, inbox2 loads images for you and senders never see your IP. When off, images wait until you tap “Show images”.")
                .font(AppFont.xs2).foregroundStyle(p.textTertiary)
                .padding(.horizontal, Space.s5).padding(.top, Space.s1).padding(.bottom, Space.s2)

            SettingsHeader(text: "inbox2 API key")
            // Recommended path: link this device through the browser instead of pasting
            // a key. Shown only in the no-saved-key entry state (gated like ApiKeyField),
            // above the manual ink_ field — mirrors the web Cloud Proxy panel.
            VStack(spacing: 0) {
                if privacy.apiKey == nil { linkBlock }
                ApiKeyField(savedValue: privacy.apiKey, placeholder: "ink_…",
                            onSave: { privacy.saveApiKey($0) ? nil : "API keys start with “ink_”." },
                            onReset: { privacy.clearApiKey() })
                    .padding(.horizontal, Space.s5)
            }
            .settingsGroup()
            Text(cloud.isSignedIn
                 ? "You’re signed in, so private images already work. Add a key to keep them working after you sign out."
                 : "Paste a personal key (ink_…) to load images privately and get push alerts. Create one in the inbox2 web app under Settings › API keys.")
                .font(AppFont.xs2).foregroundStyle(p.textTertiary)
                .padding(.horizontal, Space.s5).padding(.top, Space.s3)
        }
        .sheet(item: $safari) { SafariView(url: $0.url) }
    }

    /// Primary "Link to inbox2 account" CTA + hint, a separator, then an "or" label —
    /// the subordinate manual ApiKeyField follows beneath.
    private var linkBlock: some View {
        VStack(spacing: Space.s2) {
            Button { startLink() } label: {
                HStack(spacing: Space.s2) {
                    if linking { ProgressView().controlSize(.small).tint(.white) }
                    else { Image(systemName: "link").font(AppFont.base(.semibold)) }
                    Text(linking ? "Waiting for browser…" : "Link to inbox2 account")
                        .font(AppFont.md(.semibold))
                }
                .foregroundStyle(p.keycapLabel(.primary, or: p.onAccent))
                .frame(maxWidth: .infinity).padding(.vertical, Space.s3)
                .keycapSurface(.primary, radius: Radius.lg) {
                    RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                        .fill(p.accentViolet)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                                .fill(LinearGradient(colors: [.bevel(0.18), .clear],
                                                     startPoint: .top, endPoint: .bottom))
                        )
                }
            }
            .buttonStyle(PressableStyle())
            .disabled(linking)

            Text("Recommended. Sign in with your browser and skip the key. You can revoke each device later.")
                .font(AppFont.xs2).foregroundStyle(p.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let err = cloud.lastError {
                Text(err).font(AppFont.xs).foregroundStyle(p.accentDanger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: Space.s2) {
                Rectangle().fill(p.borderSubtle).frame(height: 1)
                Text("or").font(AppFont.xs2).foregroundStyle(p.textTertiary)
                Rectangle().fill(p.borderSubtle).frame(height: 1)
            }
            .padding(.vertical, Space.s1)
        }
        .padding(.horizontal, Space.s5)
        .padding(.bottom, Space.s2)
    }

    /// Run the device-link flow: open the approval page, then adopt the minted token
    /// (which signs the app in). Cancellation/timeout is non-fatal. Mirrors CloudLoginView.
    private func startLink() {
        linking = true
        cloud.lastError = nil
        Task {
            do {
                let token = try await deviceLink.link { url in safari = IdentifiableURL(url: url) }
                safari = nil
                try await cloud.adoptLinkedToken(token)
                linking = false
            } catch {
                safari = nil
                linking = false
                // A user cancel / timeout shouldn't read as an error; adoption failures
                // already set `cloud.lastError`.
                if case OAuthError.cancelled = error { return }
                if error is CancellationError { return }
                if cloud.lastError == nil, let dl = error as? DeviceLinkError {
                    cloud.lastError = dl.errorDescription
                }
            }
        }
    }
}

/// Contacts — the people inbox2 derives from your mail (frequency-ranked). Drives
/// compose autocomplete; "enrichment" (title/company/social) is desktop-managed.
struct EnrichmentPanel: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var engine: EngineModel
    @State private var contacts: [Contact] = []
    private var p: ThemePalette { theme.palette }
    var body: some View {
        SettingsScaffold(title: "Contacts") {
            SettingsHeader(text: contacts.isEmpty ? "No contacts yet" : "\(contacts.count) known contacts")
            VStack(spacing: 0) {
                ForEach(contacts.prefix(25)) { c in
                    HStack(spacing: Space.s3) {
                        Avatar(initials: MailAddress.initials(c.email), size: 30, seed: MailAddress.seed(c.email))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.name.isEmpty ? c.email : c.name).font(AppFont.base).foregroundStyle(p.textSecondary).lineLimit(1)
                            if !c.name.isEmpty { Text(c.email).font(AppFont.xs3).foregroundStyle(p.textTertiary).lineLimit(1) }
                        }
                        Spacer()
                        Text("\(c.total)×").font(AppFont.xs2).foregroundStyle(p.textMuted)
                    }
                    .padding(.horizontal, Space.s5).frame(minHeight: 48)
                    SettingsDivider()
                }
            }
            .settingsGroup()
            Text("Built from your mail on this device. The desktop app adds titles, companies and social links.")
                .font(AppFont.xs2).foregroundStyle(p.textTertiary).padding(.horizontal, Space.s5).padding(.top, Space.s3)
        }
        .task { contacts = await engine.store.read { $0.contacts() } }
    }
}
