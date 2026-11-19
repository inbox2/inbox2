import SwiftUI
import UniformTypeIdentifiers

/// The compose UI shown inside the share sheet — a faithful, self-contained port of the
/// app's `ComposeView` (same `Theme` tokens), with no engine/cloud env-objects. On Send:
/// a domain (mx) identity sends straight through the reused `CloudClient`; a connected
/// channel (Gmail/IMAP/Microsoft) is enqueued for the app to deliver from its outbox.
struct ShareComposeView: View {
    let identities: [ShareBridge.Identity]
    let context: ShareBridge.Context
    let sendId: String
    /// Called when the share is done (sent or queued) or cancelled — completes the
    /// extension request. `true` = composed/queued, `false` = cancelled.
    let onFinish: (Bool) -> Void

    @State private var fromKey: String?
    @State private var to: String
    @State private var cc = ""
    @State private var bcc = ""
    @State private var subject: String
    @State private var messageBody: String
    @State private var showCcBcc = false
    @State private var attachments: [ShareBridge.Attachment]
    @State private var nextIndex: Int        // monotonic, so removals never reuse a path
    @State private var importing = false
    @State private var sending = false
    @State private var error: String?

    private let p = ThemePalette.dark

    init(identities: [ShareBridge.Identity], context: ShareBridge.Context, sendId: String,
         attachments: [ShareBridge.Attachment], subject: String, body: String,
         onFinish: @escaping (Bool) -> Void) {
        self.identities = identities
        self.context = context
        self.sendId = sendId
        self.onFinish = onFinish
        _fromKey = State(initialValue: identities.first?.key)
        _to = State(initialValue: "")
        _subject = State(initialValue: subject)
        _messageBody = State(initialValue: body)
        _attachments = State(initialValue: attachments)
        _nextIndex = State(initialValue: attachments.count)
    }

    private var selected: ShareBridge.Identity? { identities.first { $0.key == fromKey } }
    private var canSend: Bool {
        selected != nil && !to.trimmingCharacters(in: .whitespaces).isEmpty && !sending
    }

    var body: some View {
        ZStack {
            p.bgBase.ignoresSafeArea()
            if identities.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    header
                    ScrollView {
                        VStack(spacing: Space.s3) {
                            fromRow
                            RecipientTokenField(label: "To", text: $to, contacts: context.contacts, palette: p)
                            if showCcBcc {
                                RecipientTokenField(label: "Cc", text: $cc, contacts: context.contacts, palette: p)
                                RecipientTokenField(label: "Bcc", text: $bcc, contacts: context.contacts, palette: p)
                            } else {
                                Button { withAnimation { showCcBcc = true } } label: {
                                    Text("Add Cc/Bcc").font(AppFont.xs).foregroundStyle(p.accentViolet)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                }.buttonStyle(.plain)
                            }
                            field("Subject", text: $subject)
                            bodyEditor
                            attachmentBar
                            if let error {
                                Text(error).font(AppFont.xs).foregroundStyle(p.accentDanger)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(Space.s4)
                    }
                }
            }
        }
        .tint(p.accentViolet)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Button("Cancel") { onFinish(false) }
                .font(AppFont.sm).foregroundStyle(p.textSecondary).disabled(sending)
            Spacer()
            Text("New message").font(AppFont.md).foregroundStyle(p.textPrimary)
            Spacer()
            if sending {
                ProgressView().controlSize(.small)
            } else {
                Button("Send") { send() }
                    .font(AppFont.md).foregroundStyle(canSend ? p.accentViolet : p.textMuted)
                    .disabled(!canSend)
            }
        }
        .padding(.horizontal, Space.s4).padding(.vertical, Space.s3)
        .background(p.bgPanel)
        .overlay(alignment: .bottom) { Rectangle().fill(p.borderSubtle).frame(height: 1) }
    }

    private var fromRow: some View {
        HStack(spacing: Space.s2) {
            Text("From").font(AppFont.sm).foregroundStyle(p.textTertiary)
                .frame(width: 64, alignment: .leading)
            Menu {
                ForEach(identities, id: \.key) { id in
                    Button { fromKey = id.key } label: {
                        Text(id.isDomain ? "\(id.email)  ·  \(id.label)" : id.email)
                    }
                }
            } label: {
                HStack(spacing: Space.s1) {
                    Text(selected?.email ?? "Select account")
                        .font(AppFont.sm).foregroundStyle(p.textPrimary).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(AppFont.xs3(.regular)).foregroundStyle(p.textTertiary)
                    Spacer()
                }
            }
        }
        .padding(.vertical, Space.s2)
        .overlay(alignment: .bottom) { Rectangle().fill(p.borderSubtle).frame(height: 1) }
    }

    private var attachmentBar: some View {
        VStack(spacing: Space.s2) {
            ForEach(attachments) { att in
                HStack(spacing: Space.s2) {
                    Image(systemName: "paperclip").font(AppFont.xs).foregroundStyle(p.textTertiary)
                    Text(att.filename).font(AppFont.xs).foregroundStyle(p.textSecondary).lineLimit(1)
                    Text(byteLabel(att.size)).font(AppFont.xs3).foregroundStyle(p.textMuted)
                    Spacer()
                    Button { attachments.removeAll { $0.id == att.id } } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(p.textTertiary)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, Space.s3).padding(.vertical, Space.s2)
                .background(p.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
            Button { importing = true } label: {
                Label("Attach file", systemImage: "paperclip")
                    .font(AppFont.sm).foregroundStyle(p.accentViolet)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            addAttachments(result)
        }
    }

    private var bodyEditor: some View {
        ZStack(alignment: .topLeading) {
            if messageBody.isEmpty {
                Text("Write a message…")
                    .font(AppFont.base).foregroundStyle(p.textTertiary)
                    .padding(.horizontal, Space.s1 + 1).padding(.vertical, Space.s2)
            }
            TextEditor(text: $messageBody)
                .font(AppFont.base).foregroundStyle(p.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 200)
        }
        .padding(Space.s2)
        .background(p.bgInput)
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).stroke(p.borderDefault, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    /// Human-readable byte size (mirrors ComposeView).
    private func byteLabel(_ bytes: Int) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
        if bytes >= 1_000 { return "\(bytes / 1_000) KB" }
        return "\(bytes) B"
    }

    /// Copy newly-picked files into this send's staging dir + append them.
    private func addAttachments(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let dir = ShareBridge.sendDir(id: sendId) else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            if let att = ShareBridge.copyIn(url, mimeType: mime, index: nextIndex, into: dir) {
                attachments.append(att)
                nextIndex += 1
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.s3) {
            Image(systemName: "tray.and.arrow.down").font(AppFont.glyph(34)).foregroundStyle(p.textTertiary)
            Text("Open Inbox2 once to enable sharing")
                .font(AppFont.md).foregroundStyle(p.textSecondary).multilineTextAlignment(.center)
            Button("Close") { onFinish(false) }
                .font(AppFont.sm).foregroundStyle(p.accentViolet)
        }
        .padding(Space.s6)
    }

    private func field(_ label: String, text: Binding<String>, isEmail: Bool = false) -> some View {
        HStack(spacing: Space.s2) {
            Text(label).font(AppFont.sm).foregroundStyle(p.textTertiary)
                .frame(width: 64, alignment: .leading)
            TextField("", text: text)
                .font(AppFont.sm).foregroundStyle(p.textPrimary)
                .textInputAutocapitalization(isEmail ? .never : .sentences)
                .autocorrectionDisabled(isEmail)
                .keyboardType(isEmail ? .emailAddress : .default)
        }
        .padding(.vertical, Space.s2)
        .overlay(alignment: .bottom) { Rectangle().fill(p.borderSubtle).frame(height: 1) }
    }

    // MARK: Send

    private func send() {
        guard let id = selected, canSend else { return }
        sending = true
        error = nil
        let ccVal = cc.trimmingCharacters(in: .whitespaces).isEmpty ? nil : cc
        let bccVal = bcc.trimmingCharacters(in: .whitespaces).isEmpty ? nil : bcc
        let subjVal = subject.trimmingCharacters(in: .whitespaces).isEmpty ? nil : subject

        if id.isDomain, let token = context.token {
            Task {
                let ok = await sendDomain(orgId: id.key, from: id.email, token: token,
                                          cc: ccVal, subject: subjVal)
                await MainActor.run {
                    if ok {
                        ShareBridge.discard(id: sendId)
                        onFinish(true)
                    } else {
                        // Couldn't reach the API — queue it so the app delivers it later.
                        enqueue(id: id, cc: ccVal, bcc: bccVal, subject: subjVal)
                        onFinish(true)
                    }
                }
            }
        } else {
            // Connected channel (or domain w/o token): the app delivers from its outbox.
            enqueue(id: id, cc: ccVal, bcc: bccVal, subject: subjVal)
            onFinish(true)
        }
    }

    /// Domain send via the reused CloudClient (create draft → upload → send → cleanup).
    private func sendDomain(orgId: String, from: String, token: String,
                            cc: String?, subject: String?) async -> Bool {
        let client = CloudClient()
        await client.setToken(token)
        let items = ShareBridge.loadAttachments(id: sendId, attachments)
        do {
            if items.isEmpty {
                _ = try await client.send(orgId: orgId, conversationId: nil, from: from, to: to,
                                          cc: cc, subject: subject, bodyPlain: messageBody, bodyHtml: nil)
            } else {
                let draft = try await client.createDraft(orgId: orgId, from: from, to: to, cc: cc,
                                                          subject: subject, bodyPlain: messageBody, conversationId: nil)
                var keys: [String] = []
                for it in items {
                    keys.append(try await client.uploadAttachment(orgId: orgId, messageId: draft.id,
                                                                   filename: it.filename,
                                                                   mimeType: it.mimeType ?? "application/octet-stream",
                                                                   data: it.data))
                }
                _ = try await client.send(orgId: orgId, conversationId: nil, from: from, to: to,
                                          cc: cc, subject: subject, bodyPlain: messageBody, bodyHtml: nil,
                                          attachmentKeys: keys)
                await client.deleteDraft(orgId: orgId, draftId: draft.id)
            }
            return true
        } catch {
            return false
        }
    }

    private func enqueue(id: ShareBridge.Identity, cc: String?, bcc: String?, subject: String?) {
        ShareBridge.enqueue(.init(
            id: sendId, isDomain: id.isDomain, accountKey: id.key, fromEmail: id.email,
            to: to, cc: cc, bcc: bcc, subject: subject, bodyPlain: messageBody,
            conversationId: nil, attachments: attachments
        ))
    }
}
