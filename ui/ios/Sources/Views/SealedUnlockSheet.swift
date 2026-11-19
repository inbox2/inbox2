import SwiftUI

/// Opens sealed mail on this phone with the account password. Face ID takes over
/// from the second time on, if the person leaves the switch on.
struct SealedUnlockSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    /// Reads the thread again: the password can be right and this mail still shut.
    let stillLocked: () async -> Bool
    @State private var password = ""
    @State private var remember = true
    @State private var busy = false
    @State private var error: String?
    private let biometry = SealedKeychain.biometryName
    private var p: ThemePalette { theme.palette }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("inbox2 password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit(unlock)
                    if let biometry {
                        Toggle("Use \(biometry) next time", isOn: $remember).tint(p.accentViolet)
                    }
                } footer: {
                    if let error { Text(error).foregroundStyle(p.accentDanger) }
                }
                .listRowBackground(p.bgSurface)
            }
            .scrollContentBackground(.hidden)
            .background(p.bgBase.ignoresSafeArea())
            .navigationTitle("Unlock your key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(p.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { GradientSpinner(size: 18) } else {
                        Button("Unlock", action: unlock).foregroundStyle(p.accentViolet).disabled(password.isEmpty)
                    }
                }
            }
        }
    }

    private func unlock() {
        guard !password.isEmpty, !busy else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                guard let identity = try await MxMirror.shared.unlockIdentity(password: password) else {
                    error = "That password doesn't open your key."
                    return
                }
                guard await MxMirror.shared.unlockSealed(identity: identity) else {
                    error = "Your key didn't open this mail."
                    return
                }
                if await stillLocked() {
                    error = "Your key didn't open this mail."
                    return
                }
                if remember, let biometry, !SealedKeychain.save(identity) {
                    error = "Mail unlocked. \(biometry) not saved."
                    return
                }
                dismiss()
            } catch {
                self.error = "No connection."
            }
        }
    }
}
