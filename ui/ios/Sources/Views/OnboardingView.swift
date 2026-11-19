import SwiftUI

/// First-run onboarding — shown when there are no connected accounts and no
/// signed-in domain (the same condition that previously fell back to mock
/// channels). Mirrors the desktop setup wizard: the inbox2 hero, then the two
/// ways to get started — sign in to your inbox2 domain (MX), or connect an
/// external mailbox (Gmail / Office 365 / IMAP).
///
/// Gmail / Office 365 start the OAuth consent flow immediately (this screen IS
/// the provider picker, so there's no second list); IMAP opens its form. Once the
/// engine reports an account — or the cloud session signs in — `RootTabs` swaps
/// this out for the main tabs, where more accounts can be added in Settings.
struct OnboardingView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var engine: EngineModel
    @EnvironmentObject private var launch: LaunchState
    @State private var playHeroSpin = false
    @State private var heroSpinScheduled = false
    @State private var showCloudLogin = false
    @State private var showIMAP = false
    @State private var safari: IdentifiableURL?
    @State private var connectingProvider: OAuthProvider?
    @State private var oauthTask: Task<Void, Never>?
    @State private var error: String?
    private let oauth = OAuthService()
    private var p: ThemePalette { theme.palette }

    private enum Kind {
        case oauth(OAuthProvider)
        case imap
    }

    /// One external-provider row. Mirrors the desktop copy verbatim.
    private struct Provider {
        let logoAsset: String
        let label: String
        let desc: String
        let kind: Kind
    }

    private let providers: [Provider] = [
        Provider(logoAsset: "ch-gmail", label: "Gmail",
                 desc: "Google Workspace and personal Gmail accounts",
                 kind: .oauth(.google)),
        Provider(logoAsset: "ch-microsoft", label: "Office 365",
                 desc: "Microsoft 365 and Outlook accounts",
                 kind: .oauth(.microsoft)),
        Provider(logoAsset: "ch-imap", label: "IMAP",
                 desc: "Any provider, like Fastmail, Yahoo or your own server",
                 kind: .imap),
    ]

    private var busy: Bool { connectingProvider != nil }

    var body: some View {
        ZStack {
            p.bgBase.ignoresSafeArea()
            ScrollView {
                VStack(spacing: Space.s5) {
                    hero

                    // Each group is one outer card (the standard inbox card surface),
                    // holding its inner row cards.
                    VStack(alignment: .leading, spacing: Space.s2) {
                        SectionLabel(text: "Your domain")
                        VStack(spacing: Space.s3) {
                            Button { showCloudLogin = true } label: { mxCard }
                                .buttonStyle(PressableStyle())
                                .disabled(busy)
                        }
                        .padding(Space.s3)
                        .insetCard()
                    }

                    VStack(alignment: .leading, spacing: Space.s2) {
                        SectionLabel(text: "External accounts")
                        VStack(spacing: Space.s3) {
                            ForEach(providers, id: \.label) { provider in
                                Button { tap(provider) } label: { card(provider) }
                                    .buttonStyle(PressableStyle())
                                    .disabled(busy)
                            }
                        }
                        .padding(Space.s3)
                        .insetCard()

                        // Connecting / error feedback sits directly under the providers.
                        if let connectingProvider {
                            VStack(spacing: Space.s2) {
                                HStack(spacing: Space.s2) {
                                    ProgressView()
                                    Text("Connecting to \(connectingProvider.displayName)…")
                                        .font(AppFont.sm).foregroundStyle(p.textSecondary)
                                }
                                Button("Cancel") { cancelOAuth() }
                                    .font(AppFont.sm)
                                    .foregroundStyle(p.accentViolet)
                                    .buttonStyle(PressableStyle())
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, Space.s1)
                        }
                        if let error {
                            Text(error)
                                .font(AppFont.xs).foregroundStyle(p.accentDanger)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, Space.s3)
                        }
                    }

                    Text("You can connect more accounts later in Settings.")
                        .font(AppFont.xs)
                        .foregroundStyle(p.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, Space.s1)
                }
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s8)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showCloudLogin) { CloudLoginView() }
        .sheet(isPresented: $showIMAP) {
            IMAPConnectView { req in await req.connect(via: engine) }
        }
        .sheet(item: $safari) { SafariView(url: $0.url) }
    }

    private func tap(_ provider: Provider) {
        switch provider.kind {
        case .oauth(let p): startOAuth(p)
        case .imap: showIMAP = true
        }
    }

    /// Run the loopback OAuth flow inline: consent in Safari, then store the
    /// account. Success repopulates `engine.accounts`, which flips the RootTabs
    /// gate to the inbox automatically.
    private func startOAuth(_ provider: OAuthProvider) {
        connectingProvider = provider
        error = nil
        oauthTask = Task {
            do {
                let tokens = try await oauth.connect(provider: provider) { url in
                    safari = IdentifiableURL(url: url)
                }
                safari = nil
                let result = await engine.addAccount(
                    providerType: provider.providerType, email: tokens.email, displayName: tokens.email,
                    authMethod: "xoauth2", accessToken: tokens.accessToken, refreshToken: tokens.refreshToken)
                connectingProvider = nil
                if !result.ok { error = result.value }
            } catch is CancellationError {
                resetOAuth()
            } catch OAuthError.cancelled {
                resetOAuth()
            } catch {
                resetOAuth()
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    /// User-initiated abort: cancels the in-flight flow (tears down the loopback
    /// listener) and clears the connecting state.
    private func cancelOAuth() {
        oauthTask?.cancel()
        resetOAuth()
    }

    private func resetOAuth() {
        safari = nil
        connectingProvider = nil
    }

    /// Play the hero spin once the splash is gone (screen actually visible) plus a
    /// ~1s beat. Driven from both `onAppear` and the splash-finished change so it
    /// fires whichever happens last (cold launch → splash dismiss; later appearances
    /// → already finished).
    private func scheduleHeroSpin() {
        guard launch.splashFinished, !heroSpinScheduled else { return }
        heroSpinScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            playHeroSpin = true
        }
    }

    private var hero: some View {
        VStack(spacing: Space.s4) {
            // The brand cube on its light badge, playing the same turntable spin as
            // the launch splash — but only once this screen is actually visible (the
            // splash has dismissed) plus a ~1s beat, so it isn't missed behind the
            // splash. Tap it to replay.
            SpinningCubeBadge(diameter: 96, play: playHeroSpin)
                .padding(.bottom, Space.s1)
                .onChange(of: launch.splashFinished) { _, _ in scheduleHeroSpin() }
                .onAppear { scheduleHeroSpin() }
            Text("Welcome to inbox2")
                .font(AppFont.display)
                .foregroundStyle(p.textPrimary)
            Text("Sign in to your domain, or connect an email account to get started.")
                .font(AppFont.sm)
                .foregroundStyle(p.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .padding(.bottom, Space.s3)
    }

    private var mxCard: some View {
        InboxCard {
            HStack(spacing: Space.s3) {
                InboxLogoTile(size: 40)
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text("Sign in to inbox2")
                        .font(AppFont.md)
                        .foregroundStyle(p.textPrimary)
                    Text("Your domain's inbox, shared with your team")
                        .font(AppFont.xs)
                        .foregroundStyle(p.textTertiary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: Space.s2)
                Image(systemName: "chevron.right")
                    .font(AppFont.xs2(.semibold))
                    .foregroundStyle(p.textTertiary)
            }
        }
    }

    private func card(_ provider: Provider) -> some View {
        InboxCard {
            HStack(spacing: Space.s3) {
                ChannelAvatar(logoAsset: provider.logoAsset, size: 40)
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(provider.label)
                        .font(AppFont.md)
                        .foregroundStyle(p.textPrimary)
                    Text(provider.desc)
                        .font(AppFont.xs)
                        .foregroundStyle(p.textTertiary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: Space.s2)
                Image(systemName: "chevron.right")
                    .font(AppFont.xs2(.semibold))
                    .foregroundStyle(p.textTertiary)
            }
        }
    }
}
