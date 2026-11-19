import SwiftUI
import ImageIO

/// Circular avatar with a pink→violet→orange gradient ring (per the design
/// reference) + optional online dot.
struct AvatarRing: View {
    @Environment(\.theme) private var theme
    let initials: String
    var size: CGFloat = 56
    var seed: Int = 0
    var online: Bool = false
    /// Continuously rotates the gradient ring while the message body / attachments
    /// load — the reader's loading affordance (mirrors the desktop avatar spinner).
    var loading: Bool = false
    @State private var spin = false

    private var ring: AngularGradient { theme.palette.ringGradient }

    var icon: String? = nil
    var logoAsset: String? = nil
    /// The person's address: their picture (Gravatar, else their domain's icon)
    /// replaces the initials once it loads. See `AvatarImages`.
    var email: String? = nil
    @State private var photo: UIImage?

    var body: some View {
        // The inbox2 cube is dark — give it a light tile so it reads on dark.
        let unified = logoAsset == "ch-unified"
        return ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(unified ? Color.unifiedLogoTile : theme.palette.bgElevated)
                .overlay(
                    Group {
                        if let photo {
                            Image(uiImage: photo).resizable().scaledToFill().clipShape(Circle())
                        } else if let logoAsset, let ui = BundledImage.named(logoAsset) {
                            Image(uiImage: ui).resizable().scaledToFit().padding(size * (unified ? 0.2 : 0.24))
                        } else if let icon {
                            Image(systemName: icon)
                                .font(AppFont.glyph(size * 0.36, .semibold))
                                .foregroundStyle(theme.palette.textPrimary)
                        } else {
                            Text(initials)
                                .font(AppFont.glyph(size * 0.34, .semibold))
                                .foregroundStyle(theme.palette.textPrimary)
                        }
                    }
                )
                .padding(3)
                .background(
                    Circle().fill(ring)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                )
                .frame(width: size, height: size)

            if online {
                Circle()
                    .fill(theme.palette.accentSuccess)
                    .frame(width: size * 0.2, height: size * 0.2)
                    .overlay(Circle().stroke(theme.palette.bgBase, lineWidth: 2))
            }
        }
        .frame(width: size, height: size)
        // Standard avatar opacity — sits a touch back so it doesn't shout over the
        // content. Lives here so every AvatarRing (rows, activity, reader) matches.
        .opacity(0.8)
        .onAppear { updateSpin(loading) }
        .onChange(of: loading) { _, now in updateSpin(now) }
        .task(id: email) {
            photo = nil
            guard let email else { return }
            let loaded = await AvatarImages.shared.image(for: email)
            if !Task.isCancelled { photo = loaded } // a newer address may have replaced this one
        }
    }

    /// Start (continuous) or stop the ring rotation. One place so every loading
    /// avatar — reader header during enrich, attachment download — spins identically.
    private func updateSpin(_ on: Bool) {
        if on {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true }
        } else {
            withAnimation(.linear(duration: 0.2)) { spin = false }
        }
    }
}

/// The inbox2 cube (`ch-unified`) on a light rounded tile — the standard treatment
/// for the dark brand logo on dark surfaces. Reused as the inbox2 mx empty-state /
/// sign-in icon so those states carry the brand rather than a generic SF Symbol.
struct InboxLogoTile: View {
    var size: CGFloat = 64

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Color.unifiedLogoTile)
            .frame(width: size, height: size)
            .overlay {
                if let ui = BundledImage.named("ch-unified") {
                    Image(uiImage: ui).resizable().scaledToFit().padding(size * 0.2)
                }
            }
    }
}

/// A connected channel/mailbox shown in the top row. The unified inbox is the
/// first entry (an icon); the rest are per-account, labeled with the email.
struct Channel: Identifiable, Hashable {
    let id: String
    let label: String           // "Unified" or the account email
    let initials: String        // circle text when there's no icon/logo
    var icon: String? = nil     // SF Symbol fallback
    var logoAsset: String? = nil // brand logo (ch-gmail / ch-microsoft / ch-imap / ch-unified)
    var avatarURL: String? = nil // provider profile photo, when available
    let seed: Int
    var online: Bool = false

    /// Short display label for a channel from its email address. For standard
    /// consumer providers we show the local part (`alice@gmail.com` →
    /// `alice`); for custom domains the registrable name, dropping the TLD
    /// (`alice@example.com` → `example`, `x@acme.io` → `acme`). Provider matching
    /// is on the first domain label, so international variants count too
    /// (`hotmail.co.uk`, `outlook.de`, `yahoo.fr` → still "standard").
    /// TODO: ideally lives in the shared channel impl (core) so desktop + mobile
    /// derive it identically.
    static func displayLabel(forEmail email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return email }
        let local = String(parts[0])
        let labels = parts[1].lowercased().split(separator: ".")
        guard let first = labels.first.map(String.init) else { return local }
        // Consumer providers — any TLD (gmail.com, hotmail.co.uk, outlook.de, …).
        let providers: Set<String> = [
            "gmail", "googlemail", "outlook", "hotmail", "live", "msn", "windowslive",
            "yahoo", "ymail", "rocketmail", "icloud", "me", "mac",
            "aol", "gmx", "proton", "protonmail", "pm", "yandex", "zoho", "mail",
        ]
        if providers.contains(first) { return local }
        // Custom domain → its registrable name (example.com → example, example.co.uk → example).
        return first
    }
}

/// Circular channel badge for the top tracker: a white tile so the brand PNGs
/// (Gmail / Microsoft / IMAP / Unified cube) read consistently, the brand mark
/// fitted with a little breathing room, the pink→violet→orange gradient ring, and
/// an optional online dot. Separate from `AvatarRing` (which renders person
/// initials in conversation/activity rows on a dark tile).
struct ChannelAvatar: View {
    @Environment(\.theme) private var theme
    let logoAsset: String?
    var icon: String? = nil
    var initials: String = ""
    /// A real channel/account avatar. When set it fills the whole circle with no
    /// backing color (preferred over the brand-logo fallback).
    var avatarImage: UIImage? = nil
    /// Remote account avatar (provider profile photo); loaded async, fills the
    /// circle, falls back to the brand logo while loading / on failure.
    var avatarURL: String? = nil
    var size: CGFloat = 58
    var online: Bool = false
    var selected: Bool = false

    /// Provider → brand logo asset (single source for the switcher + settings).
    static func brandLogo(for provider: String) -> String {
        let p = provider.lowercased()
        if p.contains("gmail") || p.contains("google") { return "ch-gmail" }
        if p.contains("micro") || p.contains("office") || p.contains("outlook") { return "ch-microsoft" }
        // Meta BYOK channels (see docs/Cloud-Push.md Meta).
        if p.contains("whatsapp") { return "ch-whatsapp" }
        if p.contains("messenger") { return "ch-messenger" }
        if p.contains("instagram") { return "ch-instagram" }
        return "ch-imap"
    }

    /// Brand-logo / cube / initials shown when there's no real avatar.
    @ViewBuilder private var fallbackContent: some View {
        if logoAsset == "ch-unified" {
            // The unified box opens (lid lifts, interior glows) when the inbox is
            // selected, and closes again when deselected.
            UnifiedBoxIcon(selected: selected, padding: size * 0.16)
        } else if let logoAsset, let ui = BundledImage.named(logoAsset) {
            Image(uiImage: ui).resizable().scaledToFit().padding(size * 0.16)
        } else if let icon {
            Image(systemName: icon)
                .font(AppFont.glyph(size * 0.36, .semibold))
                .foregroundStyle(theme.palette.bgBase)
        } else {
            Text(initials)
                .font(AppFont.glyph(size * 0.34, .semibold))
                .foregroundStyle(theme.palette.bgBase)
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(Color.unifiedLogoTile)
                .overlay(
                    Group {
                        if let avatarImage {
                            // A real avatar fills the whole circle, no backing color.
                            // The explicit frame bounds scaledToFill to the circle so a
                            // non-square source is center-cropped (not drifted/overflowing).
                            Image(uiImage: avatarImage).resizable().scaledToFill()
                                .frame(width: size, height: size).clipShape(Circle())
                        } else if let avatarURL, let url = URL(string: avatarURL) {
                            // Remote provider photo / domain icon — fills the circle; the
                            // brand logo shows while it loads and if it fails. The frame
                            // bounds scaledToFill so non-square icons center-crop cleanly.
                            AsyncImage(url: url) { phase in
                                if let img = phase.image {
                                    img.resizable().scaledToFill()
                                        .frame(width: size, height: size).clipShape(Circle())
                                } else {
                                    fallbackContent
                                }
                            }
                        } else {
                            fallbackContent
                        }
                    }
                )
                .frame(width: size, height: size)
                // Selection reads as a solid violet ring, not a bloom: a hairline when
                // idle, a 2pt violet band once selected. No outer glow either way.
                .overlay(
                    Circle().strokeBorder(
                        selected ? theme.palette.accentViolet : theme.palette.textTertiary.opacity(0.55),
                        lineWidth: selected ? 2 : 0.5
                    )
                )

            if online {
                Circle()
                    .fill(theme.palette.accentSuccess)
                    .frame(width: size * 0.2, height: size * 0.2)
                    .overlay(Circle().stroke(theme.palette.bgBase, lineWidth: 2))
            }
        }
        .frame(width: size, height: size)
    }
}

/// A small channel mark for the bottom-right corner of a conversation row's
/// sender avatar — shown only in the unified inbox so pooled channels are
/// distinguishable (mirrors the brand logo / provider photo of the channel
/// chip, in miniature). A `bgBase` ring punches it out from the avatar behind,
/// like the online dot.
struct ChannelBadge: View {
    @Environment(\.theme) private var theme
    let channel: Channel
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle().fill(Color.unifiedLogoTile)
            if let avatarURL = channel.avatarURL, let url = URL(string: avatarURL) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill().clipShape(Circle())
                    } else {
                        mark
                    }
                }
            } else {
                mark
            }
        }
        .frame(width: size, height: size)
        // Ring matches the conversation cell surface (not bgBase) so the badge
        // reads as cut into the cell behind the avatar.
        .overlay(Circle().stroke(theme.palette.bgSurface, lineWidth: 2))
    }

    /// Brand logo / icon / initials fallback, matching the channel chip.
    @ViewBuilder private var mark: some View {
        if let logoAsset = channel.logoAsset, let ui = BundledImage.named(logoAsset) {
            Image(uiImage: ui).resizable().scaledToFit().padding(size * 0.18)
        } else if let icon = channel.icon {
            Image(systemName: icon)
                .font(AppFont.glyph(size * 0.5, .semibold))
                .foregroundStyle(theme.palette.bgBase)
        } else {
            Text(channel.initials)
                .font(AppFont.glyph(size * 0.46, .bold))
                .foregroundStyle(theme.palette.bgBase)
        }
    }
}

/// Drives a prebaked frame sequence forward / backward off a Timer. Owned as a
/// `@StateObject` so it survives the row's re-renders when the selection changes
/// (the avatar keeps its identity, the player keeps its frame).
final class BoxFramePlayer: ObservableObject {
    @Published var index = 0
    let frames: [UIImage]
    private var timer: Timer?

    init(frames: [UIImage]) { self.frames = frames }

    /// Snap to an endpoint with no animation (used to seed initial state).
    func jump(toEnd: Bool) {
        timer?.invalidate(); timer = nil
        guard !frames.isEmpty else { return }
        index = toEnd ? frames.count - 1 : 0
    }

    /// Step one frame at a time toward an endpoint — forward when opening,
    /// backward when closing.
    func go(toEnd: Bool, interval: TimeInterval = 0.018) {
        timer?.invalidate(); timer = nil
        guard !frames.isEmpty else { return }
        let target = toEnd ? frames.count - 1 : 0
        guard index != target else { return }
        let step = toEnd ? 1 : -1
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.index += step
            if self.index == target { t.invalidate() }
        }
    }

    deinit { timer?.invalidate() }
}

/// The unified-inbox box as an animated icon. A 6×5 sprite sheet baked from an
/// The unified inbox brand mark: the same `inbox2-rotate-sheet.png` turntable spin
/// Tauri/web use (`UnifiedCubeIcon`) and the launch splash — a 6×5 sheet where
/// frame 0 is the "2" facing front (the resting logo) and the last frame is the
/// cube spun to the side. Selecting the inbox spins it forward; deselecting spins
/// it back. Falls back to the static cube if the sheet is absent.
struct UnifiedBoxIcon: View {
    let selected: Bool
    var padding: CGFloat = 0

    @StateObject private var player = BoxFramePlayer(frames: UnifiedBoxIcon.frames)
    @State private var primed = false

    /// Sliced once and shared across every instance.
    static let frames: [UIImage] = UnifiedBoxIcon.sliceSheet(cols: 6, rows: 5)
    static let fallback: UIImage? = {
        guard let p = Bundle.main.path(forResource: "ch-unified", ofType: "png") else { return nil }
        return UIImage(contentsOfFile: p)
    }()

    var body: some View {
        Group {
            if let img = currentFrame {
                Image(uiImage: img).resizable().scaledToFit().padding(padding)
            }
        }
        .onAppear {
            // Seed the pose for the current selection without animating, once.
            if !primed { player.jump(toEnd: selected); primed = true }
        }
        .onChange(of: selected) { _, now in player.go(toEnd: now) }
    }

    private var currentFrame: UIImage? {
        if player.frames.indices.contains(player.index) { return player.frames[player.index] }
        return Self.fallback
    }

    /// Crop a grid sprite sheet into individual frames (row-major).
    private static func sliceSheet(cols: Int, rows: Int) -> [UIImage] {
        guard let path = Bundle.main.path(forResource: "inbox2-rotate-sheet", ofType: "png"),
              let sheet = UIImage(contentsOfFile: path), let cg = sheet.cgImage else { return [] }
        let w = cg.width / cols, h = cg.height / rows
        guard w > 0, h > 0 else { return [] }
        var out: [UIImage] = []
        out.reserveCapacity(cols * rows)
        for r in 0..<rows {
            for c in 0..<cols {
                let rect = CGRect(x: c * w, y: r * h, width: w, height: h)
                if let sub = cg.cropping(to: rect) {
                    out.append(UIImage(cgImage: sub, scale: sheet.scale, orientation: .up))
                }
            }
        }
        return out
    }
}

/// Horizontal row of channels (connected mailboxes) — replaces the reference's
/// user-avatar stories row. Unified first, then one per channel.
struct ChannelsRow: View {
    @Environment(\.theme) private var theme
    let channels: [Channel]
    @Binding var selection: String

    var body: some View {
        // Unified = all channels, so nothing is "unselected" — keep everything at
        // full opacity. Once an individual channel is selected, fade the others
        // back so the active one stands out.
        let unifiedSelected = selection == "unified"
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Space.s4) {
                ForEach(channels) { ch in
                    let active = ch.id == selection
                    VStack(spacing: Space.s1 + 2) {
                        ChannelAvatar(logoAsset: ch.logoAsset, icon: ch.icon, initials: ch.initials, avatarURL: ch.avatarURL, size: 58, online: ch.online, selected: active)
                        Text(ch.label)
                            .font(AppFont.xs3(active ? .semibold : .regular))
                            .foregroundStyle(active ? theme.palette.textPrimary : theme.palette.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 64)
                    }
                    .opacity(unifiedSelected || active ? 1 : 0.75)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { selection = ch.id } }
                }
            }
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s2)
        }
    }
}

/// Sender pictures from `GET /api/v1/avatars` (Gravatar, else the sender domain's
/// icon — resolved and fetched server-side, so the phone never contacts either).
/// Nil means "draw initials". Images are downsampled to avatar size; only a
/// picture or a confirmed 404 is cached, so a network blip retries next time.
/// ponytail: the cache just empties at `limit` entries; an LRU if that churns.
actor AvatarImages {
    static let shared = AvatarImages()
    private static let limit = 400
    private static let pixels: CGFloat = 160
    private var cache: [String: UIImage?] = [:]
    private var missedAt: [String: Date] = [:] // a miss is re-asked after an hour
    private var inFlight: [String: Task<UIImage??, Never>] = [:]

    func image(for raw: String) async -> UIImage? {
        let email = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard email.contains("@"),
              // The signed-in session first — the token every other API call uses. A
              // stale personal `ink_` key 401'd every avatar (2026-11-19, iPad).
              let token = Keychain.get(CloudSession.tokenKey) ?? ImageProxy.bearer(apiKey: Keychain.get(PrivacyStore.apiKeyAccount))
        else { return nil } // not cached: signing in later should still load it
        if let hit = cache[email], hit != nil || (missedAt[email].map { -$0.timeIntervalSinceNow < 3600 } ?? false) { return hit }
        let task = inFlight[email] ?? Task { await Self.fetch(email, token: token) }
        inFlight[email] = task
        let result = await task.value
        inFlight[email] = nil
        guard let answer = result else { return nil } // transient: retry next time
        if cache.count >= Self.limit { cache.removeAll(); missedAt.removeAll() }
        cache.updateValue(answer, forKey: email)
        if answer == nil { missedAt[email] = Date() }
        return answer
    }

    /// `.some(image)` / `.some(nil)` for a confirmed answer, `nil` for a failure worth retrying.
    private static func fetch(_ email: String, token: String) async -> UIImage?? {
        guard var comps = URLComponents(string: AppConfig.apiBase + "/avatars") else { return nil }
        comps.queryItems = [URLQueryItem(name: "email", value: email)]
        // URLComponents leaves "+" bare, which the server reads as a space.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let status = (resp as? HTTPURLResponse)?.statusCode else { return nil }
        if status == 404 { return .some(nil) }
        guard status == 200 else { return nil }
        return .some(downsample(data))
    }

    /// Decode straight to avatar size — a big domain icon never lands full-size in memory.
    private static func downsample(_ data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: pixels,
              ] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}
