import SwiftUI

/// Settings → "Triage & sync": shows how far the background worker has gotten
/// classifying + summarizing in-window mail, and lets the user widen/narrow how
/// far back that processing reaches.
struct TriageSyncPanel: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var engine: EngineModel
    private var p: ThemePalette { theme.palette }

    private var window: ProcessingWindow {
        ProcessingWindow(rawValue: engine.processingWindow) ?? .default
    }

    var body: some View {
        SettingsScaffold(title: "Triage & sync") {
            SettingsHeader(text: "Progress")
            progressCard

            SettingsHeader(text: "Labels")
            NavigationLink { TriageLabelsView() } label: {
                SettingsMenuRow(icon: "tag", title: "Labels")
            }
            .buttonStyle(.plain)
            .settingsGroup()

            SettingsHeader(text: "How far back to sort")
            windowCard

            Text("New mail gets sorted first. A longer window sorts older mail in the background too.")
                .font(AppFont.xs2)
                .foregroundStyle(p.textTertiary)
                .padding(.horizontal, Space.s5)
                .padding(.top, Space.s3)
        }
    }

    private var progressCard: some View {
        let t = engine.triage
        return VStack(alignment: .leading, spacing: Space.s3) {
            TriageProgressBar(progress: t.fraction, caption: progressCaption(t), trailing: triageDate)
            HStack {
                Text(t.isActive ? "Working…" : "Up to date")
                    .font(AppFont.xs(.medium))
                    .foregroundStyle(t.isActive ? p.textSecondary : p.accentSuccess)
                Spacer()
                Text("\(t.done) / \(t.inWindow)")
                    .font(AppFont.xs.monospacedDigit())
                    .foregroundStyle(p.textTertiary)
            }
        }
        .padding(Space.s4)
        .insetCard()
        .padding(.horizontal, Space.s5)
    }

    private var windowCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(ProcessingWindow.allCases.enumerated()), id: \.element.id) { idx, w in
                Button {
                    engine.setProcessingWindow(w)
                } label: {
                    HStack {
                        Text(w.label)
                            .font(AppFont.md(.regular))
                            .foregroundStyle(p.textSecondary)
                        Spacer()
                        if w == window {
                            Image(systemName: "checkmark")
                                .font(AppFont.sm(.semibold))
                                .foregroundStyle(p.accentViolet)
                        }
                    }
                    .padding(.horizontal, Space.s4)
                    .frame(minHeight: 50)
                    .contentShape(Rectangle())
                    .settingsSelected(w == window)
                }
                .buttonStyle(.plain)
                if idx != ProcessingWindow.allCases.count - 1 { SettingsDivider() }
            }
        }
        .insetCard()
        .padding(.horizontal, Space.s5)
    }

    /// The date the worker is currently at (newest-first); nil when drained.
    private var triageDate: String? {
        engine.triage.currentDate?.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private func progressCaption(_ t: TriageState) -> String {
        if t.inWindow == 0 { return "Nothing to process yet" }
        if !t.isActive { return "All \(t.inWindow) conversations sorted" }
        return "Sorting \(t.done) of \(t.inWindow)"
    }
}
