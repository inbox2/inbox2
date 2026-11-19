import SwiftUI

/// Bridge voice settings — pick a lane per capability (Voice input / Voice output /
/// Brief writing) and store an optional OpenAI key. Each capability offers up to three
/// lanes: **On-device** (the OS engine — free, private, hidden where the device can't
/// do it), the **named free model** (a downloadable open model — shown with a download /
/// delete row; Brief writing splits this lane into its two variants, Gemma and Qwen,
/// each its own pill), and **OpenAI** (the user's key — enabled once a key is saved). The core
/// (`bridge/models`) is the source of truth for which lanes exist and which is actually
/// used; this screen only renders + persists the preference.
struct BridgeVoicePanel: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var voice: VoiceEngineManager
    @EnvironmentObject private var engine: EngineModel
    private var p: ThemePalette { theme.palette }

    var body: some View {
        SettingsScaffold(title: "On-device AI") {
            SettingsHeader(text: "OpenAI account")
            panel { openAISection }

            SettingsHeader(text: "Jev by TypeSafe")
            panel { jevSection }

            SettingsHeader(text: "HuggingFace token")
            panel { hfTokenSection }

            SettingsHeader(text: "What runs where")
            ForEach(BridgeCapability.allCases) { cap in
                panel { capabilityBody(cap) }
            }

            Text("On-device is free and private. A named model downloads a better engine. OpenAI uses your key and sends mail off the phone. If a choice isn't ready, another takes over.")
                .font(AppFont.xs2).foregroundStyle(p.textTertiary)
                .padding(.horizontal, Space.s5).padding(.top, Space.s2).padding(.bottom, Space.s5)
        }
    }

    /// The app's standard panel surface (`.insetCard()` — same as onboarding cards,
    /// the reader panes, and the IMAP form): bgSurface with a soft top glow and a
    /// top-bright gradient border, applying the shared horizontal inset itself.
    @ViewBuilder
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.s4)
            .insetCard()
            .padding(.bottom, Space.s3)
    }

    // MARK: - OpenAI key

    private var openAISection: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            // Shared key field (same component as the inbox2 image-proxy key). Save IS
            // the test: the key is validated against OpenAI and only persisted to the
            // Keychain when it checks out; an invalid key surfaces the error inline.
            ApiKeyField(savedValue: voice.hasKey ? voice.openAIKey : nil,
                        placeholder: "OpenAI API key (sk-…)",
                        onSave: { key in
                            if let err = await engine.bridgeValidateOpenAI(key) { return err }
                            voice.openAIKey = key
                            voice.keyValidated = true
                            return nil
                        },
                        onReset: { voice.removeKey() })

            Text(voice.hasKey
                ? "Key saved and checked. You can pick OpenAI below."
                : "Optional. Without a key, everything runs on this phone.")
                .font(AppFont.xs2).foregroundStyle(p.textTertiary)
        }
    }

    // MARK: - Jev (TypeSafe) key — local-channel triage

    private var jevSection: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            // Save IS the test (validate_jev_key makes one real call); only a key
            // that checks out lands in the Keychain and the engine.
            ApiKeyField(savedValue: engine.hasJevKey ? engine.jevKey : nil,
                        placeholder: "TypeSafe API key",
                        onSave: { key in
                            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let err = await engine.validateJevKey(trimmed) { return err }
                            engine.jevKey = trimmed
                            return nil
                        },
                        onReset: { engine.jevKey = "" })

            if engine.hasJevKey && engine.triage.jevStatus == "unauthorized" {
                Label("TypeSafe rejected this key. Triage is paused until you add a valid one.",
                      systemImage: "exclamationmark.triangle")
                    .font(AppFont.xs2).foregroundStyle(p.accentDanger)
            }

            Text(engine.hasJevKey
                ? "Key saved and checked. Jev labels, ranks and files your mail into Spaces. It sends each thread's recent messages (up to ~12 KB) to TypeSafe. They don't train on it."
                : "Optional. Without a key, only your rules add labels and there's no priority. With one, each thread's recent messages (up to ~12 KB) go to TypeSafe. They don't train on it.")
                .font(AppFont.xs2).foregroundStyle(p.textTertiary)
        }
    }

    // MARK: - HuggingFace token (gated model downloads — the Gemma variant)

    private var hfTokenSection: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            // Gemma lives in a gated HuggingFace repo — its download 401s without a
            // bearer token. The token is stored in the Keychain and handed to the core
            // downloader; there's no separate validation call (Save just persists it).
            // Every other model (Qwen, Kokoro) downloads anonymously.
            ApiKeyField(savedValue: engine.hasHFToken ? engine.hfToken : nil,
                        placeholder: "HuggingFace token (hf_…)",
                        onSave: { token in
                            engine.hfToken = token
                            return nil
                        },
                        onReset: { engine.hfToken = "" })

            Text(engine.hasHFToken
                ? "Saved. Gemma can now download below."
                : "Only Gemma needs this. Accept the Gemma license at huggingface.co, then add your token here.")
                .font(AppFont.xs2).foregroundStyle(p.textTertiary)
        }
    }

    // MARK: - Per-capability lane picker

    private func capabilityBody(_ cap: BridgeCapability) -> some View {
        // Re-reading observes engine.modelDownloads (published) so the row refreshes
        // as a download progresses or completes. Cheap (disk stat only).
        let lanes = engine.modelLanes(cap.rawValue, hasKey: voice.canUseOpenAI)
        let byLane = Dictionary(uniqueKeysWithValues: lanes.compactMap { info in
            BridgeLane(rawValue: info.lane).map { ($0, info) }
        })
        // Surface why a lane is dimmed — primarily the On-device (native) lane, since
        // "why is On-device greyed out?" is the common question. The OpenAI lane's
        // "add a key" case is already explained by the account panel above.
        let dimmedReason = [BridgeLane.native, .free]
            .compactMap { byLane[$0] }
            .first { !$0.available && $0.reason != nil }?
            .reason

        return VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                Image(systemName: cap.icon).font(AppFont.base).foregroundStyle(p.textSecondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(cap.title).font(AppFont.md(.regular)).foregroundStyle(p.textPrimary)
                    Text(cap.subtitle).font(AppFont.xs2).foregroundStyle(p.textTertiary)
                }
                Spacer(minLength: 0)
            }

            laneControl(cap, byLane: byLane)

            // Show why an unavailable lane is dimmed (e.g. On-device brief writing
            // needs Apple Intelligence), independent of which lane is selected.
            if let reason = dimmedReason {
                Label(reason, systemImage: "info.circle")
                    .font(AppFont.xs2).foregroundStyle(p.accentAmber)
            }

            // The On-device lane is exposed on capable hardware (iOS 26+) rather than
            // pre-flighting Apple Intelligence, which reported unavailable too eagerly.
            // Note the requirement so a user on a device without it knows why it may
            // fall back at runtime.
            if voice.pref(cap) == .native {
                Label("Needs Apple Intelligence. Turn it on in Settings › Apple Intelligence & Siri.",
                      systemImage: "sparkles")
                    .font(AppFont.xs2).foregroundStyle(p.textTertiary)
            }

            // The downloadable model — short name + size, with download / delete.
            // Brief writing's two variants (Gemma / Qwen) are picked via their own
            // lane pills above; the rows here just manage their downloads. The
            // other capabilities have a single free model.
            if let free = byLane[.free], free.available {
                if cap == .nlu {
                    ForEach(Self.nluVariants, id: \.id) { variantCard($0) }
                } else {
                    freeModelCard(free)
                }
            }

            // Voice output → per-lane voice selection. Kokoro: pick the speaker once the
            // model is on disk. OpenAI: pick the tts-1 voice once a key is saved.
            if cap == .tts, voice.pref(.tts) == .free, let free = byLane[.free],
               free.id == BridgeModelIDs.kokoro, isInstalled(free) {
                kokoroVoicePicker
            }
            if cap == .tts, voice.pref(.tts) == .openai, voice.canUseOpenAI {
                openAIVoicePicker
            }
            if cap == .tts, voice.pref(.tts) == .native {
                appleVoicePicker
            }
        }
    }

    private func isInstalled(_ info: FfiLaneInfo) -> Bool {
        info.state == "installed" || (engine.modelDownloads[info.id]?.isInstalled ?? false)
    }

    /// Voice selectors for the Kokoro TTS lane — applied per-utterance (no model
    /// reload). Two surfaces: the Bridge dialog, and the read-aloud reader (which
    /// follows the Bridge voice unless given its own).
    private var kokoroVoicePicker: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            voiceCard(title: "Bridge voice",
                      subtitle: KokoroVoice.named(voice.kokoroVoiceId).descriptor,
                      selectedName: KokoroVoice.named(voice.kokoroVoiceId).name) {
                ForEach(KokoroVoice.catalog) { v in
                    Button { withAnimation(.easeOut(duration: 0.15)) { voice.kokoroVoiceId = v.id } } label: {
                        if v.id == voice.kokoroVoiceId { Label(v.label, systemImage: "checkmark") } else { Text(v.label) }
                    }
                }
            }
            readerVoiceCard(
                subtitle: voice.readerKokoroVoiceId == nil
                    ? "email summaries · follows Bridge"
                    : "email summaries · \(KokoroVoice.named(voice.kokoroVoiceId(for: .reader)).descriptor)",
                selectedName: voice.readerKokoroVoiceId == nil
                    ? "Same as Bridge"
                    : KokoroVoice.named(voice.kokoroVoiceId(for: .reader)).name,
                isFollowing: voice.readerKokoroVoiceId == nil,
                onFollow: { voice.readerKokoroVoiceId = nil }
            ) {
                ForEach(KokoroVoice.catalog) { v in
                    Button { withAnimation(.easeOut(duration: 0.15)) { voice.readerKokoroVoiceId = v.id } } label: {
                        if v.id == voice.readerKokoroVoiceId { Label(v.label, systemImage: "checkmark") } else { Text(v.label) }
                    }
                }
            }
        }
    }

    /// The read-aloud surface's voice card: "Same as Bridge" leads the menu, then the
    /// lane's own catalog as overrides.
    private func readerVoiceCard<MenuItems: View>(
        subtitle: String,
        selectedName: String,
        isFollowing: Bool,
        onFollow: @escaping () -> Void,
        @ViewBuilder catalog: () -> MenuItems
    ) -> some View {
        voiceCard(title: "Read-aloud voice", icon: "text.bubble",
                  subtitle: subtitle, selectedName: selectedName) {
            Button { withAnimation(.easeOut(duration: 0.15)) { onFollow() } } label: {
                if isFollowing { Label("Same as Bridge", systemImage: "checkmark") } else { Text("Same as Bridge") }
            }
            Divider()
            catalog()
        }
    }

    /// Voice selectors for the OpenAI TTS lane (tts-1 voices) — Bridge + read-aloud.
    private var openAIVoicePicker: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            voiceCard(title: "Bridge voice",
                      subtitle: OpenAIVoice.named(voice.openAIVoice).descriptor,
                      selectedName: OpenAIVoice.named(voice.openAIVoice).name) {
                ForEach(OpenAIVoice.catalog) { v in
                    Button { withAnimation(.easeOut(duration: 0.15)) { voice.openAIVoice = v.id } } label: {
                        if v.id == voice.openAIVoice { Label(v.label, systemImage: "checkmark") } else { Text(v.label) }
                    }
                }
            }
            readerVoiceCard(
                subtitle: voice.readerOpenAIVoice == nil
                    ? "email summaries · follows Bridge"
                    : "email summaries · \(OpenAIVoice.named(voice.openAIVoice(for: .reader)).descriptor)",
                selectedName: voice.readerOpenAIVoice == nil
                    ? "Same as Bridge"
                    : OpenAIVoice.named(voice.openAIVoice(for: .reader)).name,
                isFollowing: voice.readerOpenAIVoice == nil,
                onFollow: { voice.readerOpenAIVoice = nil }
            ) {
                ForEach(OpenAIVoice.catalog) { v in
                    Button { withAnimation(.easeOut(duration: 0.15)) { voice.readerOpenAIVoice = v.id } } label: {
                        if v.id == voice.readerOpenAIVoice { Label(v.label, systemImage: "checkmark") } else { Text(v.label) }
                    }
                }
            }
        }
    }

    /// Voice selector for the Apple on-device lane. Lists installed voices (Automatic
    /// first) with quality hints, and a tip on downloading better voices + how
    /// Automatic handles other languages.
    private var appleVoicePicker: some View {
        let options = AppleVoices.installed()
        let current = options.first { $0.id == voice.appleVoiceId } ?? AppleVoices.automatic
        let subtitle = current.isAuto
            ? "best installed · switches per language"
            : "\(current.language)\(current.qualityTag.isEmpty ? "" : " · \(current.qualityTag)")"
        let readerCurrent = options.first { $0.id == voice.appleVoiceId(for: .reader) } ?? AppleVoices.automatic
        return VStack(alignment: .leading, spacing: Space.s2) {
            voiceCard(title: "Bridge voice", subtitle: subtitle,
                      selectedName: current.isAuto ? "Automatic" : current.name) {
                ForEach(options) { v in
                    Button { withAnimation(.easeOut(duration: 0.15)) { voice.appleVoiceId = v.id } } label: {
                        if v.id == voice.appleVoiceId { Label(v.label, systemImage: "checkmark") } else { Text(v.label) }
                    }
                }
            }
            readerVoiceCard(
                subtitle: voice.readerAppleVoiceId == nil
                    ? "email summaries · follows Bridge"
                    : "email summaries · \(readerCurrent.isAuto ? "best installed" : readerCurrent.language)",
                selectedName: voice.readerAppleVoiceId == nil
                    ? "Same as Bridge"
                    : (readerCurrent.isAuto ? "Automatic" : readerCurrent.name),
                isFollowing: voice.readerAppleVoiceId == nil,
                onFollow: { voice.readerAppleVoiceId = nil }
            ) {
                ForEach(options) { v in
                    Button { withAnimation(.easeOut(duration: 0.15)) { voice.readerAppleVoiceId = v.id } } label: {
                        if v.id == voice.readerAppleVoiceId { Label(v.label, systemImage: "checkmark") } else { Text(v.label) }
                    }
                }
            }
            Text("Premium and Enhanced voices sound most natural. Get them in Settings › Accessibility › Spoken Content › Voices. Automatic picks a voice that matches each language.")
                .font(AppFont.xs3).foregroundStyle(p.textTertiary)
        }
    }

    /// Shared chrome for a voice picker row (styled like `freeModelCard`): a label +
    /// the selected voice's descriptor, with a trailing menu of choices.
    private func voiceCard<MenuItems: View>(
        title: String = "Voice",
        icon: String = "person.wave.2",
        subtitle: String,
        selectedName: String,
        @ViewBuilder menu: () -> MenuItems
    ) -> some View {
        HStack(spacing: Space.s2) {
            Image(systemName: icon).font(AppFont.md(.regular)).foregroundStyle(p.accentViolet).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(AppFont.sm(.medium)).foregroundStyle(p.textPrimary)
                Text(subtitle).font(AppFont.xs3).foregroundStyle(p.textTertiary)
            }
            Spacer(minLength: 0)
            Menu(content: menu) {
                HStack(spacing: Space.s1) {
                    Text(selectedName).font(AppFont.sm(.semibold)).foregroundStyle(p.accentViolet)
                    Image(systemName: "chevron.up.chevron.down").font(AppFont.xs3(.regular)).foregroundStyle(p.textTertiary)
                }
            }
        }
        .padding(.horizontal, Space.s3).padding(.vertical, Space.s2 + 2)
        .background(p.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).stroke(p.borderSubtle, lineWidth: 1))
    }

    /// One selectable pill in the lane bar. Brief writing splits the free lane into
    /// its two model variants (Gemma / Qwen) so either is directly selectable as the
    /// default engine; `variant` is the manifest id that pill selects.
    private struct LanePill: Identifiable {
        let lane: BridgeLane
        let variant: String?
        let label: String
        var id: String { variant ?? lane.rawValue }
    }

    private func lanePills(_ cap: BridgeCapability, byLane: [BridgeLane: FfiLaneInfo]) -> [LanePill] {
        if cap == .nlu {
            return [
                .init(lane: .native, variant: nil, label: "On-device"),
                .init(lane: .free, variant: BridgeModelIDs.gemma, label: "Gemma"),
                .init(lane: .free, variant: BridgeModelIDs.qwen, label: "Qwen"),
                .init(lane: .openai, variant: nil, label: "OpenAI"),
            ]
        }
        // Only lanes the core manifest exposes for this capability/platform — e.g.
        // STT has no free lane (SpeechAnalyzer made the Whisper download redundant).
        return BridgeLane.allCases
            .filter { byLane[$0] != nil }
            .map { .init(lane: $0, variant: nil, label: laneLabel(cap, $0, byLane: byLane)) }
    }

    /// The lane pills, styled after `SegmentedTabs`. The free pill shows the model's
    /// short name; Brief writing shows one pill per variant (4 items). Unavailable
    /// lanes are dimmed + non-tappable; the reason shows below.
    private func laneControl(_ cap: BridgeCapability, byLane: [BridgeLane: FfiLaneInfo]) -> some View {
        let selected = voice.pref(cap)
        return HStack(spacing: Space.s1) {
            ForEach(lanePills(cap, byLane: byLane)) { pill in
                let info = byLane[pill.lane]
                let available = info?.available ?? false
                let active = pill.lane == selected && (pill.variant == nil || pill.variant == voice.freeNluModel)
                Text(pill.label)
                    .font(AppFont.xs(active ? .bold : .medium))
                    .foregroundStyle(active ? p.keycapLabel(.selected, or: p.textPrimary) : (available ? p.textTertiary : p.textMuted))
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.s2)
                    .background {
                        if active, let key = p.selectKeycap {
                            Color.clear.keycap(key, radius: Radius.full)
                        } else if active {
                            Capsule(style: .continuous)
                                .fill(p.bgRaised)
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(LinearGradient(colors: p.ringColors, startPoint: .leading, endPoint: .trailing), lineWidth: 1.5)
                                )
                                .shadow(color: p.accentViolet.opacity(0.30), radius: 7, y: 2)
                        }
                    }
                    .contentShape(Capsule())
                    .opacity(available ? 1 : 0.45)
                    .onTapGesture {
                        guard available else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            if let variant = pill.variant { voice.freeNluModel = variant }
                            voice.setPref(cap, pill.lane)
                        }
                    }
            }
        }
        .padding(Space.s1 + 1)
        .background(
            Capsule(style: .continuous)
                .fill(p.bgBase.opacity(0.6))
                .overlay(Capsule(style: .continuous).stroke(p.borderDefault, lineWidth: 1))
        )
    }

    /// The NLU free lane's two model variants — each gets its own lane pill above;
    /// these rows manage the downloads. Display metadata mirrors the core manifest
    /// (`models.json`) — ids must match `BridgeModelIDs`. Gemma first: it's the
    /// iPhone default (Qwen's 1.6 GB .task loads and generates slower).
    private struct FreeVariant {
        let id: String
        let name: String
        let detail: String
        let bytes: UInt64
    }

    private static let nluVariants: [FreeVariant] = [
        .init(id: BridgeModelIDs.gemma, name: "Gemma", detail: "Fast on iPhone · English-only", bytes: 722_016_246),
        .init(id: BridgeModelIDs.qwen, name: "Qwen", detail: "Best quality · multilingual · slower", bytes: 1_598_556_720),
    ]

    /// One NLU variant download row: name + trade-off + size, and the same
    /// download/progress/delete trailing control as `freeModelCard`. Which variant
    /// the lane *runs* is picked via the lane pills above, not here. Gemma's
    /// download is gated on the HF token.
    private func variantCard(_ v: FreeVariant) -> some View {
        let dl = engine.modelDownloads[v.id]
        let installed = engine.modelPath(v.id) != nil || (dl?.isInstalled ?? false)
        let active = dl?.isActive ?? false
        let selected = voice.freeNluModel == v.id

        return VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s2) {
                Image(systemName: installed ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(AppFont.md(.regular))
                    .foregroundStyle(installed ? p.accentSuccess : p.accentViolet)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(v.name).font(AppFont.sm(.medium)).foregroundStyle(p.textPrimary)
                    Text("\(v.detail) · \(sizeLabel(v.bytes))").font(AppFont.xs3).foregroundStyle(p.textTertiary)
                }
                Spacer(minLength: 0)
                if v.id == BridgeModelIDs.gemma && !installed && !active && !engine.hasHFToken {
                    // Gemma is gated — disable the download until a HF token is set.
                    Text("Needs token").font(AppFont.xs(.semibold)).foregroundStyle(p.textMuted)
                } else if active {
                    Text(percentLabel(dl)).font(AppFont.xs3).foregroundStyle(p.textTertiary).monospacedDigit()
                } else if installed {
                    Button { engine.deleteModel(v.id) } label: {
                        Image(systemName: "trash").font(AppFont.base).foregroundStyle(p.textTertiary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button { engine.downloadModel(v.id) } label: {
                        Text("Download").font(AppFont.xs(.semibold))
                            .foregroundStyle(p.keycapLabel(.secondary, or: p.accentViolet))
                            // Keycap padding only where the theme draws one (Groovebox).
                            .padding(.horizontal, p.secondaryKeycap == nil ? 0 : Space.s3)
                            .padding(.vertical, p.secondaryKeycap == nil ? 0 : Space.s1 + 1)
                            .keycapSurface(.secondary, radius: Radius.md)
                    }
                    .buttonStyle(.plain)
                }
            }
            if active, let frac = dl?.fraction {
                ProgressView(value: frac).tint(p.accentViolet)
            } else if active {
                ProgressView().controlSize(.small).tint(p.accentViolet)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let err = dl?.error, dl?.state == "failed" {
                Text(err).font(AppFont.xs3).foregroundStyle(p.accentDanger).lineLimit(2)
            }
            if selected && voice.pref(.nlu) == .free && !installed {
                Text("Not downloaded yet. Another model fills in until it's ready.")
                    .font(AppFont.xs3).foregroundStyle(p.accentAmber)
            }
        }
        .padding(.horizontal, Space.s3).padding(.vertical, Space.s2 + 2)
        .background(p.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).stroke(p.borderSubtle, lineWidth: 1))
    }

    /// The downloadable model row, as an inner panel: short name + size, with a
    /// download button, a live progress bar, or a delete control once installed.
    private func freeModelCard(_ info: FfiLaneInfo) -> some View {
        let dl = engine.modelDownloads[info.id]
        let installed = info.state == "installed" || (dl?.isInstalled ?? false)
        let active = dl?.isActive ?? (info.state == "downloading")

        return VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s2) {
                Image(systemName: installed ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(AppFont.md(.regular))
                    .foregroundStyle(installed ? p.accentSuccess : p.accentViolet)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(modelShortName(info.id)).font(AppFont.sm(.medium)).foregroundStyle(p.textPrimary)
                    Text(sizeLabel(info.totalBytes)).font(AppFont.xs3).foregroundStyle(p.textTertiary)
                }
                Spacer(minLength: 0)
                trailingControl(info, installed: installed, active: active)
            }
            if active, let frac = dl?.fraction {
                ProgressView(value: frac).tint(p.accentViolet)
            } else if active {
                ProgressView().controlSize(.small).tint(p.accentViolet)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let err = dl?.error, dl?.state == "failed" {
                Text(err).font(AppFont.xs3).foregroundStyle(p.accentDanger).lineLimit(2)
            }
        }
        .padding(.horizontal, Space.s3).padding(.vertical, Space.s2 + 2)
        .background(p.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).stroke(p.borderSubtle, lineWidth: 1))
    }

    @ViewBuilder
    private func trailingControl(_ info: FfiLaneInfo, installed: Bool, active: Bool) -> some View {
        if active {
            Text(percentLabel(engine.modelDownloads[info.id]))
                .font(AppFont.xs3).foregroundStyle(p.textTertiary).monospacedDigit()
        } else if installed {
            Button { engine.deleteModel(info.id) } label: {
                Image(systemName: "trash").font(AppFont.base).foregroundStyle(p.textTertiary)
            }
            .buttonStyle(.plain)
        } else {
            Button { engine.downloadModel(info.id) } label: {
                Text("Download").font(AppFont.xs(.semibold))
                    .foregroundStyle(p.keycapLabel(.secondary, or: p.accentViolet))
                    // Keycap padding only where the theme draws one (Groovebox).
                    .padding(.horizontal, p.secondaryKeycap == nil ? 0 : Space.s3)
                    .padding(.vertical, p.secondaryKeycap == nil ? 0 : Space.s1 + 1)
                    .keycapSurface(.secondary, radius: Radius.md)
            }
            .buttonStyle(.plain)
        }
    }

    /// The free model's short, friendly name (the marketing/common name, not the id).
    private func modelShortName(_ id: String) -> String {
        switch id {
        case BridgeModelIDs.kokoro: return "Kokoro"
        case BridgeModelIDs.qwen: return "Qwen"
        case BridgeModelIDs.gemma: return "Gemma"
        default: return "Open model"
        }
    }

    /// The lane pill label — the free lane shows the model's short name. (Brief
    /// writing never reaches here: its pills are built per-variant in `lanePills`.)
    private func laneLabel(_ cap: BridgeCapability, _ lane: BridgeLane, byLane: [BridgeLane: FfiLaneInfo]) -> String {
        switch lane {
        case .native: return "On-device"
        case .free: return byLane[.free].map { modelShortName($0.id) } ?? "Open model"
        case .openai: return "OpenAI"
        }
    }

    private func sizeLabel(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func percentLabel(_ dl: ModelDownload?) -> String {
        guard let frac = dl?.fraction else { return "…" }
        return "\(Int(frac * 100))%"
    }
}
