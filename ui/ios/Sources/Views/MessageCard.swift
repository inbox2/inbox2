import SwiftUI
import QuickLook
import UIKit
import UniformTypeIdentifiers

/// One message in the thread: a tappable identity header (avatar, sender, time —
/// sentiment/intent badges live on the AI Summary panel, not here) over the
/// self-sizing body. Newest message starts expanded; older ones collapse to a
/// one-line preview.
struct MessageCard: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject var engine: EngineModel
    @EnvironmentObject var cloud: CloudSession
    @EnvironmentObject private var privacy: PrivacyStore
    @EnvironmentObject var chrome: ChromeModel
    let message: Message
    let isLast: Bool
    let threadCount: Int
    let accountKey: String
    let mayHaveAttachments: Bool
    /// Domain threads compose from the domain address (no engine account to derive it).
    let fromEmailOverride: String?
    /// The body web view reported a new measured height. Bodies size asynchronously, so
    /// the reader needs this to re-anchor its open-on-last-message scroll — until the
    /// heights land the thread is too short and `scrollTo` clamps short of the target.
    var onBodyResize: (() -> Void)? = nil
    /// An RSVP on this card's invite landed: the reader archives the thread (answering
    /// an invite is done with the mail, as on web/desktop). Nil where it stays put.
    var onInviteAnswered: (() -> Void)? = nil
    @State private var expanded: Bool
    @State private var bodyHeight: CGFloat = 60
    /// False until the body web view reports its document finished loading — drives
    /// the rendering spinner so the reserved body area never reads as blank/frozen.
    @State private var bodyLoaded = false
    @State var attachments: [AttachmentInfo] = []
    @State private var enrichedBody: String?
    @State private var didEnrich = false
    @State private var blockedCount = 0
    @State private var showImages = false
    /// Proxied image fetches the upstream host refused (bot-managed CDNs).
    @State private var proxyFailedCount = 0
    /// Explicit per-message consent to load just those images directly.
    @State private var loadFailedDirect = false
    @State private var enriching = false
    /// Attachment download / preview / export state.
    @StateObject var download = AttachmentInteraction()
    @State private var showSource = false
    @State private var showDetails = false
    /// Open tracking (docs/Open-Tracking.md): opens for a sent tracked message.
    @State private var showOpens = false
    @State private var opens: [MessageOpen] = []
    /// Recipient lists cap at 3 tokens until the "+N more" token expands them.
    @State private var showAllRecipients = false
    @State var composeDraft: ComposeDraft?
    /// Meeting invite (Accept/Tentative/Decline banner). MX invites arrive on
    /// `message.invite`; local-channel ones are resolved lazily from the calendar
    /// attachment when the card expands. `inviteStatus` is the recorded / just-chosen
    /// RSVP (nil = unanswered → no highlight).
    @State var localInvite: ClientInvite?
    @State var inviteStatus: String?
    @State var inviteBusy = false
    /// "Add to calendar" (non-REQUEST ICS): the created event's key once added, so the
    /// banner flips to a confirmation that deep-links to it.
    @State var addedEventKey: String?
    /// Why the add failed, straight from the engine — shown as-is under the button.
    @State var addError: String?
    /// Once answered we collapse to "You accepted · Change"; Change re-opens the buttons.
    @State var inviteChanging = false
    /// "Around this time": the device's calendar events within ±2h of the invite, so a
    /// conflict (or the meeting already being there) shows before you act. Mirrors the
    /// desktop `InviteSchedule`.
    @State var nearbyEvents: [CalendarEvent] = []
    /// Meet-link booking request (MX): the answer once given (nil = still pending),
    /// the decline sheet + its optional reason, and the server's refusal if any.
    @State var requestAnswer: String?
    @State var requestBusy = false
    @State var requestError: String?
    @State var showDecline = false
    @State var declineReason = ""
    var p: ThemePalette { theme.palette }

    /// The provider-enriched body (inline cid images as data URIs) once fetched,
    /// else the locally stored body.
    private var displayBody: String { enrichedBody ?? message.bodyForReader }

    /// Whether the locally stored body already has something to render. Microsoft/
    /// Gmail channels don't sync bodies — they're fetched on open — so this is false
    /// until `enrichIfNeeded()` returns, which is when we show the loading indicator.
    private var hasStoredBody: Bool {
        (message.bodyHTML?.isEmpty == false) || (message.bodyPlain?.isEmpty == false)
    }

    /// A proxy bearer is available (personal API key, or the signed-in MX session).
    private var hasToken: Bool { privacy.apiKey != nil || cloud.isSignedIn }
    /// Load images privately through the Rails proxy — mirrors `shouldProxyImages`:
    /// (auto via the privacy pref, OR the user tapped "Show images") AND a bearer is
    /// available. Auto-loads when the pref is on, so trusted readers never see the
    /// banner.
    private var proxyMode: Bool { (privacy.proxyEnabled || showImages) && hasToken }
    /// Direct (IP-leaking) load — the no-bearer fallback, only on an explicit tap.
    private var directMode: Bool { showImages && !hasToken }
    /// The user already consented (a previous visit) to load THIS email's proxy-refused
    /// images directly — remembered so reopening it doesn't re-prompt.
    private var directConsented: Bool { privacy.isDirectConsented(message.id) }

    init(message: Message, isLast: Bool, threadCount: Int, accountKey: String,
         mayHaveAttachments: Bool, fromEmailOverride: String? = nil,
         onBodyResize: (() -> Void)? = nil, onInviteAnswered: (() -> Void)? = nil) {
        self.message = message
        self.isLast = isLast
        self.threadCount = threadCount
        self.accountKey = accountKey
        self.mayHaveAttachments = mayHaveAttachments
        self.fromEmailOverride = fromEmailOverride
        self.onBodyResize = onBodyResize
        self.onInviteAnswered = onInviteAnswered
        _expanded = State(initialValue: isLast)
    }

    /// The one-line collapsed preview. The stored "plain" part frequently carries raw
    /// HTML/CSS (HTML-only senders), which rendered verbatim here — "* { font-family:
    /// Arial… }". Strip it to readable text the same way the inbox list snippet and the
    /// read-aloud path do, before clipping.
    private var preview: String {
        let raw = (message.bodyPlain?.isEmpty == false ? message.bodyPlain : message.bodyHTML) ?? ""
        let text = MessageView.plainText(from: raw)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(140))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: { header }
            .buttonStyle(.plain)
            // Tap & hold the sender → copy their address (desktop: right-click).
            .contextMenu {
                if !message.isDraft && !message.email.isEmpty {
                    CopyAddressButtons(name: message.sender, email: message.email)
                }
            }

            if expanded {
                Rectangle().fill(p.borderSubtle).frame(height: 1)
                if let invite { meetingInviteBar(invite) }
                if let request = message.meetingRequest { meetingRequestBar(request) }
                detailsBlock
                if !attachments.isEmpty {
                    attachmentList
                }
                detailsBar
                if showDetails {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        dateRow
                        if !message.subject.isEmpty { LabeledRow("Subject", message.subject, labelWidth: 52) }
                    }
                    .padding(.horizontal, Space.s3).padding(.bottom, Space.s2)
                }
                Rectangle().fill(p.borderSubtle).frame(height: 1)
                if blockedCount > 0 && !proxyMode && !directMode {
                    showImagesBar
                }
                if proxyMode && proxyFailedCount > 0 && !loadFailedDirect && !directConsented {
                    proxyFailedBar
                }
                if enriching && enrichedBody == nil && !hasStoredBody {
                    bodyLoadingIndicator
                } else {
                    MessageBodyWebView(html: displayBody, height: $bodyHeight,
                                       showRemoteImages: directMode,
                                       proxyImages: proxyMode,
                                       apiKey: privacy.apiKey,
                                       onBlockedCount: { blockedCount = $0 },
                                       directFallback: loadFailedDirect || directConsented,
                                       onProxyFailed: { proxyFailedCount = $0 },
                                       onLoaded: { bodyLoaded = true })
                        .frame(height: bodyHeight)
                        .frame(maxWidth: .infinity)
                        .overlay { if !bodyLoaded { bodyRenderingIndicator } }
                }
            } else {
                Text(preview)
                    .font(AppFont.xs)
                    .foregroundStyle(p.textTertiary)
                    .lineLimit(1)
                    .padding(.horizontal, Space.s3)
                    .padding(.bottom, Space.s3)
            }
        }
        .insetCard()
        .onChange(of: bodyHeight) { onBodyResize?() }
        .task(id: expanded) { await enrichIfNeeded() }
        .quickLookPreview($download.previewURL)
        .fileExporter(isPresented: $download.showExport, document: download.exportDoc, contentType: download.exportType, defaultFilename: download.exportName) { _ in }
        .sheet(isPresented: $showSource) { MessageSourceView(message: message) }
        .sheet(isPresented: $showOpens) { MessageOpensView(opens: opens) }
        .sheet(item: $composeDraft) { draft in ComposeView(draft: draft) }
    }

    /// Always-visible headers: people as tappable tokens (mirrors the desktop
    /// RecipientChip + ContactPopup: new message / search mail / copy address), not
    /// raw header strings. Recipient lists show 3 tokens with a "+N more" expander.
    @ViewBuilder private var detailsBlock: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            addressRow("From", MailAddress.parseList(message.fromAddress))
            addressRow("To", MailAddress.parseList(message.toAddress))
            if let cc = message.ccAddress, !cc.isEmpty {
                addressRow("Cc", MailAddress.parseList(cc))
            }
        }
        .padding(.horizontal, Space.s3).padding(.top, Space.s2)
    }

    /// "Details" disclosure under the address tokens — reveals the date row; when
    /// open, a `{}` view-source button sits far right.
    private var detailsBar: some View {
        HStack(spacing: Space.s2) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { showDetails.toggle() } } label: {
                HStack(spacing: 4) {
                    Text(showDetails ? "Hide details" : "Details").font(AppFont.xs)
                    Image(systemName: showDetails ? "chevron.up" : "chevron.down").font(AppFont.xs3(.semibold))
                }
                .foregroundStyle(p.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if showDetails {
                Button { showSource = true } label: {
                    Image(systemName: "curlybraces").font(AppFont.sm(.semibold)).foregroundStyle(p.accentViolet)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Space.s3).padding(.vertical, Space.s2)
    }

    /// "Wed, Jun 10, 2026 at 9:33 AM" — date and time in the code font, "at" normal.
    private var dateRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Text("Date").font(AppFont.xs3).foregroundStyle(p.textTertiary)
                .frame(width: 52, alignment: .leading)
            if let parts = RelativeTime.longParts(message.createdAt) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(parts.date).font(AppFont.mono(11)).foregroundStyle(p.textSecondary)
                    Text("at").font(AppFont.xs2).foregroundStyle(p.textTertiary)
                    Text(parts.time).font(AppFont.mono(11)).foregroundStyle(p.textSecondary)
                }
            } else {
                Text(message.createdAt).font(AppFont.mono(11)).foregroundStyle(p.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func addressRow(_ label: String, _ people: [(name: String, email: String)]) -> some View {
        if !people.isEmpty {
            HStack(alignment: .top, spacing: Space.s2) {
                Text(label).font(AppFont.xs3).foregroundStyle(p.textTertiary)
                    .frame(width: 52, alignment: .leading)
                    .padding(.top, 4)   // optically align with the token text
                FlowRow(spacing: Space.s1 + 2) {
                    let visible = showAllRecipients ? people : Array(people.prefix(3))
                    ForEach(visible, id: \.email) { person in
                        AddressToken(name: person.name, email: person.email,
                                     onCompose: { compose(to: person.email) },
                                     onSearch: { chrome.pendingSearch = person.email })
                    }
                    if !showAllRecipients && people.count > 3 {
                        PillButton(title: "+\(people.count - 3) more", tint: p.accentViolet) {
                            withAnimation(.easeInOut(duration: 0.15)) { showAllRecipients = true }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func compose(to email: String) {
        composeDraft = ComposeDraft(fromAccountKey: accountKey,
                                    fromEmailOverride: fromEmailOverride,
                                    to: email)
    }

    /// Privacy banner: the sender's remote images (often tracking pixels) are blocked
    /// until the user opts in — mirrors the desktop remote-image policy. With a proxy
    /// bearer the tap loads privately (no IP leak); without one it's a direct load and
    /// the label says so.
    private var showImagesBar: some View {
        Button { withAnimation { showImages = true } } label: {
            HStack(spacing: Space.s2) {
                Image(systemName: hasToken ? "lock.shield" : "eye.slash").font(AppFont.xs2)
                Text("\(blockedCount) remote image\(blockedCount == 1 ? "" : "s") blocked")
                    .font(AppFont.xs)
                Spacer()
                Text(hasToken ? "Load privately" : "Show images").font(AppFont.xs(.semibold))
            }
            .foregroundStyle(p.accentAmber)
            .padding(.horizontal, Space.s3).padding(.vertical, Space.s2)
            .background(p.accentAmber.opacity(0.12))
        }
        .buttonStyle(.plain)
    }

    /// Graceful degradation: some image hosts (bot-managed CDNs) refuse the
    /// server-side proxy outright. Offer an explicit direct load of just those
    /// images — the only path that reveals the reader's IP, and only to the hosts
    /// that blocked the proxy.
    private var proxyFailedBar: some View {
        Button {
            withAnimation { loadFailedDirect = true }
            privacy.setDirectConsented(message.id)   // remember per-email, so revisiting won't re-prompt
        } label: {
            HStack(spacing: Space.s2) {
                Image(systemName: "exclamationmark.triangle").font(AppFont.xs2)
                Text("\(proxyFailedCount) image\(proxyFailedCount == 1 ? "" : "s") couldn't load privately")
                    .font(AppFont.xs)
                Spacer()
                Text("Load directly").font(AppFont.xs(.semibold))
            }
            .foregroundStyle(p.accentAmber)
            .padding(.horizontal, Space.s3).padding(.vertical, Space.s2)
            .background(p.accentAmber.opacity(0.12))
        }
        .buttonStyle(.plain)
    }

    /// Tap-to-open attachment rows (icon, name, size, download spinner). Fetched
    /// lazily from the provider the first time the message expands.
    /// Shown while the on-demand provider fetch is in flight and there's no stored
    /// body yet to render — keeps an image-heavy first-open from looking blank/broken.
    private var bodyLoadingIndicator: some View {
        HStack(spacing: Space.s2) {
            ProgressView()
                .controlSize(.small)
                .tint(p.accentWarmBright)
            Text("Loading message…")
                .font(AppFont.sm)
                .foregroundStyle(p.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, Space.s6)
    }

    /// Overlaid on the body web view between mount and first paint: the WKWebView is
    /// transparent and zero-content until its document finishes, so without this the
    /// reserved area looks blank/frozen. A bare spinner (no label) keeps it light.
    private var bodyRenderingIndicator: some View {
        ProgressView()
            .controlSize(.small)
            .tint(p.accentWarmBright)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Enrich the open message from the provider (once): swap in the richer body
    /// (inline images as data URIs) and list its attachments. The stored body shows
    /// immediately; this upgrades it when the fetch returns.
    private func enrichIfNeeded() async {
        guard expanded, !didEnrich else { return }
        didEnrich = true
        enriching = true
        let result = await engine.fetchMessage(accountKey: accountKey, messageKey: message.id)
        attachments = result.attachments
        if let html = result.bodyHtml, !html.isEmpty { enrichedBody = html }
        enriching = false
        await resolveInvite()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Space.s3) {
            AvatarRing(initials: message.initials, size: 42, seed: message.seed,
                       loading: enriching || download.downloadingId != nil, email: message.email)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.s2) {
                    Text(message.sender)
                        .font(AppFont.sm(.semibold))
                        .foregroundStyle(p.textSender)
                        .lineLimit(1)
                    Spacer(minLength: Space.s2)
                    if isTracked { openedBadge }
                    Text(message.time).font(AppFont.xs2).foregroundStyle(p.textTertiary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(AppFont.xs3(.semibold))
                        .foregroundStyle(p.textTertiary)
                }
                Text(message.isDraft ? "Draft" : message.email)
                    .font(AppFont.xs)
                    .foregroundStyle(p.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(Space.s3)
        .contentShape(Rectangle())
    }

    /// True for a sent message that carries a tracking pixel (docs/Open-Tracking.md).
    private var isTracked: Bool {
        guard !message.isInbound, !message.isDraft else { return false }
        let html = message.bodyHTML ?? ""
        return html.contains("/o/") && html.contains(".gif")
    }

    private var realOpens: [MessageOpen] { opens.filter { !$0.proxied } }

    // Compact "opened / not opened" pill; tap opens the who/when/where history.
    private var openedBadge: some View {
        let opened = !realOpens.isEmpty
        return Button {
            Task { opens = await engine.messageOpens(messageKey: message.id); showOpens = true }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: opened ? "eye.fill" : "eye.slash")
                Text(opened ? (realOpens.count > 1 ? "Opened \(realOpens.count)×" : "Opened") : "Sent")
            }
            .font(AppFont.xs3)
            .foregroundStyle(opened ? p.accentSuccess : p.textTertiary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill((opened ? p.accentSuccess : p.textTertiary).opacity(0.14)))
        }
        .buttonStyle(.plain)
        .task(id: message.id) {
            // Prefetch so the badge reflects real opens without a tap.
            opens = await engine.messageOpens(messageKey: message.id)
        }
    }
}

/// Copy address / Copy name and address — the tap menu on an address token and
/// the long-press menu on the card's sender header.
struct CopyAddressButtons: View {
    let name: String
    let email: String

    var body: some View {
        Button { UIPasteboard.general.string = email } label: {
            Label("Copy address", systemImage: "doc.on.doc")
        }
        if !name.isEmpty && name != email {
            Button { UIPasteboard.general.string = "\(name) <\(email)>" } label: {
                Label("Copy name and address", systemImage: "person.text.rectangle")
            }
        }
    }
}

/// One person in the Details block as a tappable pill. The tap opens a menu titled
/// with the address: New message / Search mail / Copy address — the same actions as
/// the desktop ContactPopup.
private struct AddressToken: View {
    @Environment(\.theme) private var theme
    let name: String
    let email: String
    let onCompose: () -> Void
    let onSearch: () -> Void
    private var p: ThemePalette { theme.palette }

    var body: some View {
        Menu {
            Section(email) {
                Button(action: onCompose) { Label("New message", systemImage: "square.and.pencil") }
                Button(action: onSearch) { Label("Search mail", systemImage: "magnifyingglass") }
                CopyAddressButtons(name: name, email: email)
            }
        } label: {
            Text(name.isEmpty ? email : name)
                .font(AppFont.xs2)
                .foregroundStyle(p.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, Space.s2 + 2).padding(.vertical, 3)
                .background(Capsule().fill(p.bgRaised))
                .overlay(Capsule().stroke(p.borderSubtle, lineWidth: 1))
        }
    }
}
