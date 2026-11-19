import SwiftUI

/// Folder switcher presented from the hamburger — the channel label up top, then
/// the standard mailboxes (Inbox / Sent / Drafts / Archive / Trash). Selecting one
/// scopes the list and dismisses.
struct FolderSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: MailFolder
    let channelLabel: String
    private var p: ThemePalette { theme.palette }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(MailFolder.allCases) { folder in
                        Button {
                            selection = folder
                            dismiss()
                        } label: {
                            HStack(spacing: Space.s3) {
                                Image(systemName: folder.icon)
                                    .font(AppFont.body)
                                    .foregroundStyle(p.accentViolet)
                                    .frame(width: 26)
                                Text(folder.title).font(AppFont.base).foregroundStyle(p.textPrimary)
                                Spacer()
                                if folder == selection {
                                    Image(systemName: "checkmark").font(AppFont.sm(.semibold))
                                        .foregroundStyle(p.accentViolet)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .listRowBackground(p.bgSurface)
                    }
                } header: {
                    Text(channelLabel).font(AppFont.xs).foregroundStyle(p.textTertiary).textCase(nil)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(p.bgBase.ignoresSafeArea())
            .navigationTitle("Mailboxes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(p.accentViolet)
                }
            }
        }
    }
}
