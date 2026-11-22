import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// A reply/forward/new-message prefill. Reply and Forward seed this from the open
/// conversation; a blank one is a fresh compose.
struct ComposeDraft: Identifiable {
    let id = UUID()
    /// Set when resuming a locally-saved draft, so save/send can update/remove it.
    var savedDraftId: UUID? = nil
    var fromAccountKey: String? = nil
    /// Set for a reply: the thread being answered — marked read once the reply is
    /// accepted. For an inbox2-domain reply it's also the thread the cloud send
    /// attaches to (routing itself keys off the from identity, not this).
    var conversationId: String? = nil
    var fromEmailOverride: String? = nil
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var body = ""
    /// Set for a reply: the local key of the message being replied to. The engine
    /// hydrates In-Reply-To/References (+ Gmail threadId) from it at send time so
    /// the reply threads for us and for every recipient.
    var replyToMessageKey: String? = nil
    /// Attachments to seed the composer with. Forward seeds *pending* ones (a
    /// `download` ref, no bytes) so the sheet opens instantly and ComposeView
    /// downloads them in-screen, showing a spinner and blocking Send until done.
    var attachments: [Attachment] = []

    /// A seeded file: either resolved bytes, or a `download` ref to fetch
    /// in-screen. `forward(...)` builds the pending variant.
    struct Attachment: Identifiable {
        let id = UUID()
        let filename: String
        let mimeType: String?
        var data: Data? = nil
        var download: Download? = nil

        struct Download {
            let accountKey: String
            let messageKey: String
            let attachmentId: String
        }

        /// A pending forward whose bytes haven't been downloaded yet.
        static func pending(filename: String, mimeType: String?, download: Download) -> Attachment {
            Attachment(filename: filename, mimeType: mimeType, data: nil, download: download)
        }
    }
}

/// Compose sheet — From (account picker) / To / Cc / Bcc / Subject / body +
/// attachments. Ported from the desktop ComposePopup; Send goes through the
/// engine's outbox (durable). cc/bcc/attachments are real, for end-to-end testing.
struct ComposeView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var engine: EngineModel
    @EnvironmentObject private var cloud: CloudSession
    @EnvironmentObject private var chrome: ChromeModel
    /// The identity last sent from — the From default on the Unified inbox.
    @AppStorage("compose.lastFromKey") private var lastFromKey = ""

    @State private var fromAccountKey: String?
    @State private var conversationId: String?
    @State private var fromEmailOverride: String?
    @State private var replyToMessageKey: String?
    @State private var to: String
    @State private var cc: String
    @State private var bcc: String
    @State private var subject: String
    @State private var messageBody: String
    @State private var showCcBcc: Bool
    @State private var attachments: [PickedAttachment] = []
    @State private var importing = false
    /// Photo-library picks. `PhotosPicker` runs out-of-process, so it needs no
    /// photo-library permission (and no NSPhotoLibraryUsageDescription).
    @State private var pickingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var capturing = false
    @State private var sending = false
    @State private var sendError: String?
    @State private var allContacts: [Contact] = []
    @State private var draftId: UUID
    @State private var showSaveDialog = false
    /// Set by every explicit exit (save/discard/send) so the onDisappear autosave
    /// only fires for the implicit ones — swipe-down, parent tearing the sheet down.
    @State private var resolved = false
    @State private var showSchedule = false
    @State private var scheduleDate = Date().addingTimeInterval(3600)
    @EnvironmentObject private var draftStore: DraftStore

    init(draft: ComposeDraft = ComposeDraft()) {
        // A new message from an address folder you can reply as starts From that address.
        let folderFrom = draft.fromAccountKey == nil && draft.fromEmailOverride == nil ? AddressFolderStore.shared.replyAs : nil
        _fromAccountKey = State(initialValue: draft.fromAccountKey ?? folderFrom?.orgId)
        _conversationId = State(initialValue: draft.conversationId)
        _fromEmailOverride = State(initialValue: draft.fromEmailOverride ?? folderFrom?.address)
        _replyToMessageKey = State(initialValue: draft.replyToMessageKey)
        _to = State(initialValue: draft.to)
        _cc = State(initialValue: draft.cc)
        _bcc = State(initialValue: draft.bcc)
        _subject = State(initialValue: draft.subject)
        _messageBody = State(initialValue: draft.body)
        _showCcBcc = State(initialValue: !draft.cc.isEmpty || !draft.bcc.isEmpty)
        _draftId = State(initialValue: draft.savedDraftId ?? UUID())
        // Forward seeds files up-front (bytes downloaded before the sheet opened).
        _attachments = State(initialValue: draft.attachments.map {
            PickedAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data, download: $0.download)
        })
    }

    private var hasContent: Bool {
        !(to + cc + bcc + subject + messageBody).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var p: ThemePalette { theme.palette }

    /// A file on the draft: user-picked ones carry `data` immediately; forwarded
    /// ones start pending (a `download` ref) and ComposeView fills `data` in-screen.
    private struct PickedAttachment: Identifiable {
        let id = UUID()
        let filename: String
        let mimeType: String?
        var data: Data? = nil
        var download: ComposeDraft.Attachment.Download? = nil
        var failed = false
        /// Bytes still downloading — Send stays blocked while any chip is pending.
        var pending: Bool { data == nil && download != nil && !failed }
    }

    /// A sendable "from" identity: an offline channel account, or an inbox2-domain
    /// address (`username@org.domain`, mirroring the web's useFromIdentities). A
    /// domain identity's key is the `org_…` id, which routes the send to the API.
    private struct FromIdentity: Identifiable, Hashable {
        let id: String
        let email: String
        let label: String
        /// Provider slug for the channel logo ("gmail", "microsoft", …); empty
        /// for a domain identity, which wears the inbox2 mark.
        var provider: String = ""
        var isDomain: Bool { AccountKey.isDomain(id) }
    }

    private var identities: [FromIdentity] {
        let offline = engine.accounts.map {
            FromIdentity(id: $0.id, email: $0.email, label: $0.email, provider: $0.provider)
        }
        var domain: [FromIdentity] = []
        if cloud.isSignedIn, let u = cloud.user {
            for org in cloud.orgs {
                // The server's send-as list (all share the org key); older
                // payloads lack it → username@ the org's domain.
                if let list = org.fromAddresses {
                    for email in list { domain.append(FromIdentity(id: org.id, email: email, label: org.name)) }
                    continue
                }
                guard let orgDomain = org.domain, !orgDomain.isEmpty else { continue }
                domain.append(FromIdentity(id: org.id, email: "\(u.username)@\(orgDomain)", label: org.name))
            }
        }
        return offline + domain
    }

    /// Domain (inbox2) compose: the from-account key is an `org_…` id; the send
    /// routes through the cloud API.
    private var isDomain: Bool { AccountKey.isDomain(resolvedFromKey) }

    /// Explicit (a reply, or picked) → the account the inbox is filtered to → the
    /// one last sent from → the first. Each must still be a sendable identity.
    private var resolvedFromKey: String? {
        if let k = fromAccountKey { return k }
        let ids = Set(identities.map(\.id))
        return [chrome.inboxAccountKey, lastFromKey].compactMap { $0 }.first(where: ids.contains)
            ?? engine.accounts.first?.id ?? identities.first?.id
    }
    private var fromEmail: String {
        // A reply carries the exact receiving address; otherwise use the identity.
        if let o = fromEmailOverride, !o.isEmpty { return o }
        return identities.first(where: { $0.id == resolvedFromKey })?.email ?? ""
    }
    private var canSend: Bool {
        !to.trimmingCharacters(in: .whitespaces).isEmpty && resolvedFromKey != nil && !sending
            && !attachments.contains(where: { $0.pending })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Space.s3) {
                    accountPicker
                    RecipientTokenField(label: "To", text: $to, contacts: contactSuggestions, palette: p)
                    // "Add Cc/Bcc" isn't here — it rides the trailing end of the
                    // attach row below, so it costs no vertical space of its own.
                    if showCcBcc {
                        RecipientTokenField(label: "Cc", text: $cc, contacts: contactSuggestions, palette: p)
                        RecipientTokenField(label: "Bcc", text: $bcc, contacts: contactSuggestions, palette: p)
                    }
                    field("Subject", text: $subject)
                    attachmentBar
                    bodyEditor
                    if let sendError {
                        Text(sendError).font(AppFont.xs).foregroundStyle(p.accentDanger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(Space.s4)
            }
            // Light mode: one flat white sheet — the body editor melts into it.
            .background((p.isDark ? p.bgBase : p.bgElevated).ignoresSafeArea())
            .navigationTitle("New message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        if hasContent { showSaveDialog = true } else { discardDraft() }
                    }.foregroundStyle(p.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if sending {
                        ProgressView()
                    } else if isDomain {
                        // Domain supports scheduled send (the server defers delivery).
                        Menu {
                            Button { send() } label: { Label("Send now", systemImage: "paperplane.fill") }
                            Button { showSchedule = true } label: { Label("Schedule send…", systemImage: "clock") }
                        } label: { sendLabel }
                        .disabled(!canSend)
                    } else {
                        Button { send() } label: { sendLabel }
                            .disabled(!canSend)
                    }
                }
            }
            .sheet(isPresented: $showSchedule) {
                NavigationStack {
                    Form {
                        DatePicker("Send at", selection: $scheduleDate, in: Date()...,
                                   displayedComponents: [.date, .hourAndMinute])
                    }
                    .scrollContentBackground(.hidden)
                    .background(p.bgBase.ignoresSafeArea())
                    .navigationTitle("Schedule send")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Cancel") { showSchedule = false }.foregroundStyle(p.accentViolet)
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Schedule") { showSchedule = false; scheduleSend() }.foregroundStyle(p.accentViolet)
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                addAttachments(result)
            }
            .photosPicker(isPresented: $pickingPhotos, selection: $photoItems, matching: .any(of: [.images, .videos]))
            .fullScreenCover(isPresented: $capturing) {
                CameraPicker { data in
                    let name = "photo-\(Int(Date().timeIntervalSince1970)).jpg"
                    attachments.append(PickedAttachment(filename: name, mimeType: "image/jpeg", data: data))
                    Log.action.info("attached \(name) (\(data.count) bytes) from the camera")
                }
                .ignoresSafeArea()
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                // Clear the selection only *after* the bytes are in: the items are
                // vended by the picker session that this binding keeps alive, so
                // emptying it first invalidates them and loadTransferable returns nil.
                Task { await addPhotos(items); photoItems = [] }
            }
            .task { allContacts = await engine.store.read { $0.contacts() } }
            .task { await downloadPendingAttachments() }
            .confirmationDialog("Save this draft?", isPresented: $showSaveDialog, titleVisibility: .visible) {
                Button("Save draft") { saveDraft() }
                Button("Discard", role: .destructive) { discardDraft() }
                Button("Keep editing", role: .cancel) {}
            }
            // Swipe-down with content behaves like Cancel: the gesture is refused and
            // the same dialog asks what to do.
            .interactiveDismissDisabled(hasContent)
            .background(DismissAttemptHook { showSaveDialog = true })
            // The presenter tearing the sheet down (nav from a notification, …) has
            // no gesture to refuse — keep the text instead of losing it.
            .onDisappear { if !resolved && hasContent { persistDraft() } }
        }
    }

    private func persistDraft() {
        draftStore.save(SavedDraft(id: draftId, fromAccountKey: resolvedFromKey,
                                   to: to, cc: cc, bcc: bcc, subject: subject, body: messageBody))
    }

    /// Every explicit exit goes through here so the autosave stays quiet.
    private func close() {
        resolved = true
        dismiss()
    }

    private func saveDraft() {
        persistDraft()
        close()
    }

    /// Drop the draft (delete it if it was a resumed saved draft) and close.
    private func discardDraft() {
        draftStore.delete(id: draftId)
        close()
    }

    /// Recency-weighted-frequency-ranked contacts, mapped to the shared recipient
    /// field's contact type (the field keeps the incoming order).
    private var contactSuggestions: [ShareBridge.Contact] {
        allContacts.map { ShareBridge.Contact(name: $0.name, email: $0.email) }
    }

    private var selectedIdentity: FromIdentity? {
        identities.first(where: { $0.id == resolvedFromKey })
    }

    /// The channel's mark: its brand logo, or the inbox2 tile for a domain address.
    @ViewBuilder private func identityAvatar(_ ident: FromIdentity, size: CGFloat) -> some View {
        if ident.isDomain {
            InboxLogoTile(size: size)
        } else {
            ChannelAvatar(logoAsset: ChannelAvatar.brandLogo(for: ident.provider),
                          initials: String(ident.email.prefix(2)).uppercased(),
                          size: size)
        }
    }

    /// Menu rows render their icon through the system's own sizing, which ignores
    /// a sized view — an Image is the only thing UIKit will draw there.
    @ViewBuilder private func identityLogo(_ ident: FromIdentity) -> some View {
        if let ui = BundledImage.named(ident.isDomain ? "ch-unified" : ChannelAvatar.brandLogo(for: ident.provider)) {
            Image(uiImage: ui).renderingMode(.original)
        } else {
            Image(systemName: "person.crop.circle")
        }
    }

    @ViewBuilder private var accountPicker: some View {
        HStack(spacing: Space.s2) {
            Text("From").font(AppFont.sm).foregroundStyle(p.textTertiary)
                .frame(width: 64, alignment: .leading)
            Menu {
                // By email: an org's own and shared addresses share one org key.
                ForEach(identities, id: \.email) { ident in
                    Button {
                        fromAccountKey = ident.id
                        // A domain identity's exact address (the org key alone
                        // can't tell username@ from a shared info@).
                        fromEmailOverride = ident.isDomain ? ident.email : nil
                    } label: {
                        // A menu Label carries the channel logo into the row, so
                        // the list reads as channels rather than a wall of
                        // addresses (same as the desktop From picker).
                        Label {
                            Text(ident.isDomain ? "\(ident.email)  ·  \(ident.label)" : ident.email)
                        } icon: {
                            identityLogo(ident)
                        }
                    }
                }
            } label: {
                HStack(spacing: Space.s2) {
                    if let ident = selectedIdentity { identityAvatar(ident, size: 18) }
                    Text(fromEmail.isEmpty ? "Select account" : fromEmail)
                        .font(AppFont.sm).foregroundStyle(p.textPrimary).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(AppFont.xs3(.regular)).foregroundStyle(p.textTertiary)
                    Spacer()
                }
            }
        }
        .padding(.vertical, Space.s2)
        .composeRow(p)
    }

    /// Send: accent glyph, or a lavender dome keycap under Groovebox.
    private var sendLabel: some View {
        let dome = p.primaryKeycap != nil
        return Label("Send", systemImage: "paperplane.fill")
            .foregroundStyle(p.keycapLabel(.primary, or: canSend ? p.accentViolet : p.textMuted))
            .padding(.horizontal, dome ? Space.s3 : 0).padding(.vertical, dome ? Space.s1 + 2 : 0)
            .keycapSurface(.primary, radius: Radius.full)
            .opacity(dome && !canSend ? 0.5 : 1)
    }

    /// Attach / Add Cc-Bcc: accent text links, or dark keycaps under Groovebox.
    private func secondaryButton<L: View>(_ label: L) -> some View {
        let key = p.secondaryKeycap != nil
        return label
            .font(AppFont.sm).foregroundStyle(p.keycapLabel(.secondary, or: p.accentViolet))
            .padding(.horizontal, key ? Space.s3 : 0).padding(.vertical, key ? Space.s1 + 2 : 0)
            .keycapSurface(.secondary, radius: 9)
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
        .background(p.isDark ? p.bgInput : .clear)
        .overlay(RoundedRectangle(cornerRadius: wellRadius, style: .continuous)
            .stroke(p.isDark ? p.borderDefault : .clear, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: wellRadius, style: .continuous))
    }

    /// Body editor + attachment rows: Groovebox wells are rounder.
    private var wellRadius: CGFloat { p.panelRadius != nil ? 14 : Radius.md }

    private var attachmentBar: some View {
        VStack(spacing: Space.s2) {
            ForEach(attachments) { att in
                HStack(spacing: Space.s2) {
                    if att.pending {
                        ProgressView().controlSize(.small).tint(p.accentViolet)
                    } else {
                        Image(systemName: "paperclip").font(AppFont.xs).foregroundStyle(p.textTertiary)
                    }
                    Text(att.filename).font(AppFont.xs).foregroundStyle(p.textSecondary).lineLimit(1)
                    if let data = att.data {
                        Text(byteLabel(data.count)).font(AppFont.xs3).foregroundStyle(p.textMuted)
                    } else if att.failed {
                        Text("failed").font(AppFont.xs3).foregroundStyle(p.textMuted)
                    }
                    Spacer()
                    Button { attachments.removeAll { $0.id == att.id } } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(p.textTertiary)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, Space.s3).padding(.vertical, Space.s2)
                .background(p.panelRadius != nil ? p.bgRaised : p.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: wellRadius, style: .continuous))
                .opacity(att.pending ? 0.75 : 1)
            }
            // One row for both secondary actions: attach on the lead, Cc/Bcc on the
            // trail. The Cc/Bcc reveal is one-way, so once it's open the row is just
            // the attach menu again.
            HStack(spacing: Space.s2) {
                Menu {
                    Button { importing = true } label: { Label("Files", systemImage: "folder") }
                    Button { pickingPhotos = true } label: { Label("Photos", systemImage: "photo.on.rectangle") }
                    // Hidden where there's no camera to open (the simulator, mainly).
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { capturing = true } label: { Label("Camera", systemImage: "camera") }
                    }
                } label: {
                    secondaryButton(Label("Attach", systemImage: "paperclip"))
                }
                Spacer()
                if !showCcBcc {
                    Button { withAnimation { showCcBcc = true } } label: {
                        secondaryButton(Text("Add Cc/Bcc"))
                    }.buttonStyle(.plain)
                }
            }
        }
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
        .composeRow(p)
    }

    /// Resolve pending forward attachments in-screen: download each one's bytes
    /// (cached in EngineModel) and fill it in. The chip shows a spinner and Send
    /// stays blocked (`canSend`) until every pending attachment lands.
    private func downloadPendingAttachments() async {
        for att in attachments where att.pending {
            guard let dl = att.download else { continue }
            let data = await engine.downloadAttachment(accountKey: dl.accountKey, messageKey: dl.messageKey, attachmentId: dl.attachmentId)
            guard let idx = attachments.firstIndex(where: { $0.id == att.id }) else { continue }
            if let data {
                attachments[idx].data = data
                attachments[idx].download = nil
            } else {
                attachments[idx].failed = true
            }
        }
    }

    private func addAttachments(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                Log.action.error("attach: failed to read \(url.lastPathComponent)")
                continue
            }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            attachments.append(PickedAttachment(filename: url.lastPathComponent, mimeType: mime, data: data))
            Log.action.info("attached \(url.lastPathComponent) (\(data.count) bytes)")
        }
    }

    /// Load picked photos/videos into attachment chips. Each item is transferred as
    /// raw `Data` and named from the picker's `supportedContentTypes` (the library's
    /// own filename isn't exposed), so the recipient gets a sane extension.
    private func addPhotos(_ items: [PhotosPickerItem]) async {
        for (i, item) in items.enumerated() {
            let type = item.supportedContentTypes.first { $0.preferredFilenameExtension != nil }
            let ext = type?.preferredFilenameExtension ?? "jpg"
            let name = "photo-\(Int(Date().timeIntervalSince1970))-\(i + 1).\(ext)"
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw CocoaError(.fileReadUnknown)
                }
                await MainActor.run {
                    attachments.append(PickedAttachment(filename: name,
                                                        mimeType: type?.preferredMIMEType ?? "image/jpeg",
                                                        data: data))
                }
                Log.action.info("attached \(name) (\(data.count) bytes)")
            } catch {
                // A picked photo that silently never appears is the worst outcome —
                // say so on the sheet.
                await MainActor.run { sendError = "Couldn't attach that photo. Try again." }
                Log.action.error("attach: failed to load photo item — \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func send() {
        guard let key = resolvedFromKey, canSend else { return }
        lastFromKey = key
        sending = true
        sendError = nil
        // Domain (inbox2) send → cloud API (attachments via the draft-upload flow).
        if isDomain {
            let domainAtts = attachments.compactMap { att in
                att.data.map { OutgoingAttachment(filename: att.filename, mimeType: att.mimeType ?? "application/octet-stream", data: $0) }
            }
            Task {
                let ok = await cloud.send(conversationId: conversationId, from: fromEmail, to: to,
                                          cc: cc.isEmpty ? nil : cc,
                                          subject: subject.isEmpty ? nil : subject, bodyPlain: messageBody,
                                          attachments: domainAtts, orgId: key)
                await MainActor.run {
                    sending = false
                    if ok { draftStore.delete(id: draftId); markThreadRead(); close() }
                    else { sendError = "Couldn't send the message." }
                }
            }
            return
        }
        let ffiAtts = attachments.compactMap { att in
            att.data.map { FfiAttachment(filename: att.filename, mimeType: att.mimeType, data: $0) }
        }
        Task {
            let (ok, status) = await engine.send(
                accountKey: key, from: fromEmail, to: to,
                cc: cc.isEmpty ? nil : cc, bcc: bcc.isEmpty ? nil : bcc,
                subject: subject.isEmpty ? nil : subject, bodyPlain: messageBody, attachments: ffiAtts,
                replyToMessageKey: replyToMessageKey
            )
            await MainActor.run {
                sending = false
                if ok {
                    draftStore.delete(id: draftId)   // sent — drop any saved draft
                    markThreadRead()
                    close()
                } else { sendError = "Couldn't send (\(status))." }
            }
        }
    }

    /// Answering a thread means you've read it — every message in it. Routed through
    /// the shared action router (cloud for domain, engine write-back for channels).
    private func markThreadRead() {
        guard let cid = conversationId, let key = resolvedFromKey else { return }
        Task { await engine.perform(accountKey: key, conversationKeys: [cid], action: .markRead, cloud: cloud) }
    }

    /// Schedule a domain message for `scheduleDate` (create draft + schedule).
    private func scheduleSend() {
        guard isDomain, canSend else { return }
        sending = true
        sendError = nil
        let atts = attachments.compactMap { att in
            att.data.map { OutgoingAttachment(filename: att.filename, mimeType: att.mimeType ?? "application/octet-stream", data: $0) }
        }
        Task {
            let ok = await cloud.scheduleSend(conversationId: conversationId, from: fromEmail, to: to,
                                              cc: cc.isEmpty ? nil : cc,
                                              subject: subject.isEmpty ? nil : subject, bodyPlain: messageBody,
                                              attachments: atts, at: scheduleDate, orgId: resolvedFromKey)
            await MainActor.run {
                sending = false
                if ok { draftStore.delete(id: draftId); markThreadRead(); close() }
                else { sendError = "Couldn't schedule the message." }
            }
        }
    }

    private func byteLabel(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.0f KB", Double(n) / 1024) }
        return String(format: "%.1f MB", Double(n) / (1024 * 1024))
    }
}

/// Attach → Camera. SwiftUI has no camera picker (`PhotosPicker` only reads the
/// library), so this is the UIKit one; the shot is handed back JPEG-encoded.
private struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // 0.85 keeps a phone photo around 1–3 MB — attachable without a resize step.
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.85) {
                parent.onCapture(data)
            } else {
                Log.action.error("attach: camera returned no usable image")
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// Reports the swipe-down a sheet refused (`interactiveDismissDisabled`) — SwiftUI
/// has no callback for it, UIKit does.
private struct DismissAttemptHook: UIViewControllerRepresentable {
    let onAttempt: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ vc: Controller, context: Context) { vc.onAttempt = onAttempt }

    final class Controller: UIViewController, UIAdaptivePresentationControllerDelegate {
        var onAttempt: () -> Void = {}
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            parent?.presentationController?.delegate = self
        }
        func presentationControllerDidAttemptToDismiss(_ pc: UIPresentationController) { onAttempt() }
    }
}
