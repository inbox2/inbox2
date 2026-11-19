import SwiftUI

/// Sign in to an inbox2 domain (the API-backed "MX" team pool). Username + password,
/// with a TOTP step when the account has 2FA. Presented as a sheet from Settings.
struct CloudLoginView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var cloud: CloudSession
    private var p: ThemePalette { theme.palette }

    @State private var username = ""
    @State private var password = ""
    @State private var totp = ""
    @State private var working = false
    @AppStorage(AppConfig.baseURLKey) private var apiBase = AppConfig.defaultBase
    @State private var showAdvanced = false

    private let deviceLink = DeviceLinkService()
    @State private var safari: IdentifiableURL?
    @State private var linking = false

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !working
            && (!cloud.pending2FA || !totp.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Space.s5) {
                    VStack(spacing: Space.s2) {
                        InboxLogoTile(size: 60)
                        Text("Sign in to inbox2")
                            .font(AppFont.lg).foregroundStyle(p.textPrimary)
                        Text("Open your domain's inbox, shared with your team. Your Gmail, Outlook and IMAP accounts stay on this device.")
                            .font(AppFont.xs).foregroundStyle(p.textTertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, Space.s4)

                    // Credentials — one card, fields as plain rows (no inner cards).
                    VStack(spacing: 0) {
                        FormRow {
                            TextField("Username", text: $username)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .textContentType(.username)
                                .disabled(cloud.pending2FA)
                        }
                        SettingsDivider()
                        FormRow {
                            SecureField("Password", text: $password)
                                .textContentType(.password)
                                .disabled(cloud.pending2FA)
                        }
                        if cloud.pending2FA {
                            SettingsDivider()
                            FormRow {
                                TextField("2FA code", text: $totp)
                                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
                            }
                        }
                    }
                    .insetCard()

                    if let err = cloud.lastError {
                        Text(err).font(AppFont.sm).foregroundStyle(p.accentDanger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Space.s4)
                    }

                    // Passwordless alternative: approve this device from a browser
                    // where you're already signed in to inbox2 (OAuth-style device link).
                    linkSection

                    // "Advanced" reads as a link; tapping it reveals a separate,
                    // labelled Server URL section.
                    VStack(alignment: .leading, spacing: Space.s3) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showAdvanced.toggle() }
                        } label: {
                            HStack(spacing: Space.s1) {
                                Text("Advanced")
                                Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                                    .font(AppFont.xs3(.semibold))
                            }
                            .font(AppFont.sm)
                            .foregroundStyle(p.accentViolet)
                        }
                        .buttonStyle(PressableStyle())
                        .padding(.leading, Space.s3)

                        if showAdvanced {
                            VStack(alignment: .leading, spacing: Space.s2) {
                                SectionLabel(text: "Server URL")
                                VStack(spacing: 0) {
                                    FormRow {
                                        TextField("https://…/api/v1", text: $apiBase)
                                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                                            .keyboardType(.URL).font(AppFont.sm)
                                    }
                                }
                                .insetCard()
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, Space.s4)
                .padding(.bottom, Space.s8)
            }
            .background(p.bgBase.ignoresSafeArea())
            .navigationTitle("inbox2 mx")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(p.accentViolet)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if working { ProgressView() }
                    else {
                        Button(cloud.pending2FA ? "Verify" : "Sign in") { submit() }
                            .disabled(!canSubmit)
                            .foregroundStyle(canSubmit ? p.accentViolet : p.textTertiary)
                    }
                }
            }
            .onChange(of: cloud.state) { _, s in if s == .signedIn { dismiss() } }
            .sheet(item: $safari) { SafariView(url: $0.url) }
        }
    }

    /// "or — Link to inbox2 account": the device-link flow. Disabled while a
    /// password sign-in is in flight, and vice versa.
    private var linkSection: some View {
        VStack(spacing: Space.s3) {
            HStack(spacing: Space.s2) {
                Rectangle().fill(p.borderSubtle).frame(height: 1)
                Text("or").font(AppFont.xs).foregroundStyle(p.textTertiary)
                Rectangle().fill(p.borderSubtle).frame(height: 1)
            }
            Button { startLink() } label: {
                HStack(spacing: Space.s2) {
                    if linking { ProgressView().controlSize(.small) }
                    else { Image(systemName: "qrcode.viewfinder").font(AppFont.base(.semibold)) }
                    Text(linking ? "Waiting for approval…" : "Link to inbox2 account")
                        .font(AppFont.base)
                }
                .foregroundStyle(p.accentViolet)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.s3)
                .insetCard()
            }
            .buttonStyle(PressableStyle())
            .disabled(linking || working || cloud.pending2FA)

            Text("Approve this device in a browser where you're signed in. You won't need a password.")
                .font(AppFont.xs).foregroundStyle(p.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
    }

    /// Run the device-link flow: open the approval page, then adopt the minted token
    /// (which signs the app in). Cancellation/timeout is non-fatal — the sheet stays.
    private func startLink() {
        linking = true
        cloud.lastError = nil
        Task {
            do {
                let token = try await deviceLink.link { url in safari = IdentifiableURL(url: url) }
                safari = nil
                try await cloud.adoptLinkedToken(token)
                linking = false
                dismiss()
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

    private func submit() {
        working = true
        Task {
            let ok = await cloud.login(
                username: username.trimmingCharacters(in: .whitespaces),
                password: password,
                totp: cloud.pending2FA ? totp.trimmingCharacters(in: .whitespaces) : nil)
            await MainActor.run {
                working = false
                if ok { dismiss() }
            }
        }
    }
}
