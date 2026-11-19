import SwiftUI

/// The component / style guide — the approval surface. Showcases the ported design
/// tokens and primitives, with a live appearance switch (System / Dark / Light).
struct StyleGuideView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.theme) private var theme
    @State private var sampleText = "billing@acme.com"
    @State private var toggleOn = true

    private var p: ThemePalette { theme.palette }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s6) {
                appearanceSwitcher
                colorsSection
                typographySection
                buttonsSection
                inputsSection
                tagsSection
                gradientsSection
                avatarsBadgesSection
                cardSection
            }
            .padding(Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(p.bgBase.ignoresSafeArea())
    }

    // MARK: sections

    private var appearanceSwitcher: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("INBOX2 STYLE GUIDE")
                .font(AppFont.xs3)
                .tracking(1)
                .foregroundStyle(p.textTertiary)
            Picker("Appearance", selection: $themeManager.appearance) {
                ForEach(Appearance.allCases) { a in Text(a.label).tag(a) }
            }
            .pickerStyle(.segmented)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(AppFont.xs(.semibold))
            .tracking(0.5)
            .foregroundStyle(p.textSecondary)
    }

    private var colorsSection: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            sectionHeader("Colors")
            swatchRow("Surfaces", [
                ("base", p.bgBase), ("panel", p.bgPanel), ("surface", p.bgSurface),
                ("raised", p.bgRaised), ("elevated", p.bgElevated), ("input", p.bgInput),
            ])
            swatchRow("Text", [
                ("primary", p.textPrimary), ("secondary", p.textSecondary),
                ("tertiary", p.textTertiary), ("link", p.textLink), ("warm", p.textWarm),
            ])
            swatchRow("Accent", [
                ("violet", p.accentViolet), ("primary", p.accentPrimary), ("success", p.accentSuccess),
                ("warning", p.accentWarning), ("danger", p.accentDanger), ("purple", p.accentPurple),
                ("amber", p.accentAmber), ("teal", p.accentTeal),
            ])
            swatchRow("Status", [
                ("open", p.statusOpen), ("pending", p.statusPending), ("archived", p.statusArchived),
                ("snoozed", p.statusSnoozed), ("urgent", p.statusUrgent), ("ai", p.statusAI),
            ])
        }
    }

    private func swatchRow(_ label: String, _ colors: [(String, Color)]) -> some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            Text(label).font(AppFont.xs2).foregroundStyle(p.textTertiary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s2), count: 4), spacing: Space.s2) {
                ForEach(colors, id: \.0) { name, color in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                            .fill(color)
                            .frame(height: 34)
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                                    .stroke(p.borderDefault, lineWidth: 1)
                            )
                        Text(name).font(AppFont.xs3(.regular)).foregroundStyle(p.textTertiary)
                    }
                }
            }
        }
    }

    private var typographySection: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            sectionHeader("Typography · SF Pro")
            Group {
                typeRow("display / 26 semibold", AppFont.display)
                typeRow("title / 22 semibold", AppFont.title)
                typeRow("title2 / 19 semibold", AppFont.title2)
                typeRow("title3 / 17 semibold", AppFont.title3)
                typeRow("xl / 20 semibold", AppFont.xl)
                typeRow("lg / 18 semibold", AppFont.lg)
            }
            Group {
                typeRow("body / 17", AppFont.body)
                typeRow("md / 16 medium", AppFont.md)
                typeRow("base / 15", AppFont.base)
                typeRow("sm / 14", AppFont.sm)
                typeRow("xs / 13", AppFont.xs)
                typeRow("2xs / 12", AppFont.xs2)
            }
        }
    }

    private func typeRow(_ label: String, _ font: Font) -> some View {
        HStack {
            Text("The quick brown fox").font(font).foregroundStyle(p.textPrimary)
            Spacer()
            Text(label).font(AppFont.xs3(.regular)).foregroundStyle(p.textTertiary)
        }
    }

    private var buttonsSection: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            sectionHeader("Icon buttons")
            HStack(spacing: Space.s4) {
                IconButton("magnifyingglass", tint: p.textSecondary) {}
                IconButton("bell.fill", tint: LinearGradient(colors: p.ringColors, startPoint: .topLeading, endPoint: .bottomTrailing)) {}
                IconButton("plus", tint: p.accentViolet) {}
            }
        }
    }

    private var inputsSection: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            sectionHeader("Inputs")
            InboxTextField(placeholder: "Search or enter address", text: $sampleText)
            Toggle(isOn: $toggleOn) {
                Text("Remote image privacy").font(AppFont.sm).foregroundStyle(p.textPrimary)
            }
            .tint(p.accentWarmBright)
        }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            sectionHeader("Tags & status")
            FlowRow(spacing: Space.s2) {
                InboxTag(text: "Open", color: p.statusOpen)
                InboxTag(text: "Pending", color: p.statusPending)
                InboxTag(text: "Urgent", color: p.statusUrgent)
                InboxTag(text: "AI", color: p.statusAI)
                InboxTag(text: "Invoices", color: p.accentAmber)
                InboxTag(text: "Archived", color: p.statusArchived)
            }
        }
    }

    private var gradientsSection: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            sectionHeader("Gradients")
            // Brand ring (avatars + Bridge orb) and the per-channel hue ramp.
            Capsule()
                .fill(p.ringGradient)
                .frame(height: 18)
            Text("Brand ring · palette.ringGradient").font(AppFont.xs2).foregroundStyle(p.textTertiary)
            HStack(spacing: Space.s2) {
                ForEach(Array(ChannelColor.gradients.enumerated()), id: \.offset) { _, stops in
                    Circle()
                        .fill(LinearGradient(colors: stops, startPoint: .top, endPoint: .bottom))
                        .frame(width: 26, height: 26)
                }
            }
            Text("Channel colors · ChannelColor").font(AppFont.xs2).foregroundStyle(p.textTertiary)
        }
    }

    private var avatarsBadgesSection: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            sectionHeader("Avatars & AI badges")
            HStack(spacing: Space.s3) {
                AvatarRing(initials: "DL", size: 48, seed: 1)
                AvatarRing(initials: "", size: 48, online: true, icon: "person.fill")
                Avatar(initials: "WS", size: 44, seed: 2)
            }
            FlowRow(spacing: Space.s2) {
                AIBadge.sentiment(positive: true, theme: theme)
                AIBadge.sentiment(positive: false, theme: theme)
                AIBadge.intent(.question, theme: theme)
                AIBadge.intent(.scheduling, theme: theme)
            }
        }
    }

    private var cardSection: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            sectionHeader("Card")
            InboxCard {
                VStack(alignment: .leading, spacing: Space.s2) {
                    HStack {
                        Text("Dana Lee").font(AppFont.sm(.semibold)).foregroundStyle(p.textSender)
                        Spacer()
                        Text("9:14 AM").font(AppFont.xs2).foregroundStyle(p.textTertiary)
                    }
                    Text("Re: Q3 pipeline review").font(AppFont.sm).foregroundStyle(p.textPrimary)
                    Text("Can we move the review to later this week? Wednesday or Friday morning both work…")
                        .font(AppFont.xs).foregroundStyle(p.textSecondary).lineLimit(2)
                    HStack(spacing: Space.s2) {
                        InboxTag(text: "Open", color: p.statusOpen)
                        InboxTag(text: "AI", color: p.statusAI)
                    }
                }
            }
        }
    }
}
