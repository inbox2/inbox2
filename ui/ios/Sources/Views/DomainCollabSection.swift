import SwiftUI

/// The team-pool collaboration header for a domain (inbox2 MX) conversation: the
/// tag chips + palette menu, the assignee bar + member picker, and the internal
/// notes thread with an inline add-note field. Self-contained — it owns its own
/// state and fetches its own data (the thread's tags/assignees/notes plus the org
/// tag/member palettes) — so the reader (`MessageView`) just drops it in for domain
/// threads and stays focused on rendering the message stack.
///
/// It issues its own `cloud.thread` fetch (one extra round-trip alongside the
/// reader's message fetch); domain threads are the cloud path and the collab payload
/// is small, so the clean separation is worth it.
struct DomainCollabSection: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var cloud: CloudSession
    let convo: Conversation

    @State private var domainTags: [CloudTag] = []
    @State private var orgTags: [CloudTag] = []
    @State private var domainAssignees: [CloudMember] = []
    @State private var orgMembers: [CloudMember] = []
    @State private var domainNotes: [CloudNote] = []
    @State private var newNote = ""
    @State private var showNoteField = false
    @State private var askLabelName = false
    @State private var newLabel = ""

    private var p: ThemePalette { theme.palette }

    var body: some View {
        Group {
            tagsBar
            assigneesBar
            notesSection
        }
        .task(id: convo.id) { await load() }
    }

    /// Fetch the thread's collaboration data + the org tag/member palettes.
    private func load() async {
        let t = await cloud.thread(conversationId: convo.id, orgId: convo.mxOrgId)
        let palette = await cloud.orgTags(orgId: convo.mxOrgId)
        let members = await cloud.orgMembers(orgId: convo.mxOrgId)
        domainTags = t.tags
        domainAssignees = t.assignees
        domainNotes = t.notes
        orgTags = palette
        orgMembers = members
    }

    @ViewBuilder private var tagsBar: some View {
        HStack(spacing: Space.s2) {
            Image(systemName: "tag").font(AppFont.xs2).foregroundStyle(p.textTertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if domainTags.isEmpty {
                        Text("No tags").font(AppFont.xs2).foregroundStyle(p.textTertiary)
                    } else {
                        ForEach(domainTags) { tag in
                            HStack(spacing: 2) {
                                if tag.isPrivate == true {
                                    Image(systemName: "lock.fill").font(AppFont.glyph(9)).foregroundStyle(p.textTertiary)
                                }
                                InboxTag(text: tag.name, color: tag.color.map { Color(hex: $0) })
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Menu {
                if orgTags.isEmpty {
                    Text("No tags in this domain")
                } else {
                    ForEach(orgTags) { tag in
                        let on = domainTags.contains(where: { $0.id == tag.id })
                        Button { toggleTag(tag) } label: {
                            Label(tag.isPrivate == true ? "\(tag.name) (only you)" : tag.name,
                                  systemImage: on ? "checkmark.circle.fill" : (tag.isPrivate == true ? "lock" : "circle"))
                        }
                    }
                }
                Divider()
                Button { newLabel = ""; askLabelName = true } label: {
                    Label("New label just for you…", systemImage: "plus")
                }
            } label: {
                Image(systemName: "plus.circle").font(AppFont.md(.regular)).foregroundStyle(p.accentViolet)
            }
        }
        .padding(.horizontal, Space.s4)
        .alert("New label", isPresented: $askLabelName) {
            TextField("Name", text: $newLabel)
            Button("Cancel", role: .cancel) {}
            Button("Add") { createLabel() }
        } message: {
            Text("Only you see this label.")
        }
    }

    /// Makes a private label and puts it on this thread.
    private func createLabel() {
        let name = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Log.action.info("domain private label create on \(convo.id, privacy: .public)")
        Task {
            guard let tag = await cloud.createPrivateLabel(name: name, orgId: convo.mxOrgId) else { return }
            await MainActor.run { orgTags.append(tag) }
            await MainActor.run { toggleTag(tag) }
        }
    }

    /// Who the domain thread is assigned to, with a member-picker menu to change it.
    @ViewBuilder private var assigneesBar: some View {
        HStack(spacing: Space.s2) {
            Image(systemName: "person.crop.circle").font(AppFont.xs2).foregroundStyle(p.textTertiary)
            Text("Assigned").font(AppFont.xs2).foregroundStyle(p.textTertiary)
            Text(domainAssignees.isEmpty ? "No one" : domainAssignees.map { $0.user?.label ?? "?" }.joined(separator: ", "))
                .font(AppFont.xs).foregroundStyle(domainAssignees.isEmpty ? p.textTertiary : p.textSecondary).lineLimit(1)
            Spacer(minLength: 0)
            Menu {
                if orgMembers.isEmpty {
                    Text("No members")
                } else {
                    ForEach(orgMembers) { m in
                        let on = domainAssignees.contains { $0.id == m.id }
                        Button { toggleAssignee(m) } label: {
                            Label(m.user?.label ?? "?", systemImage: on ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
            } label: {
                Image(systemName: "person.crop.circle.badge.plus").font(AppFont.base).foregroundStyle(p.accentViolet)
            }
        }
        .padding(.horizontal, Space.s4)
    }

    private func toggleAssignee(_ m: CloudMember) {
        var ids = Set(domainAssignees.map(\.id))
        if ids.contains(m.id) { ids.remove(m.id) } else { ids.insert(m.id) }
        Log.action.info("domain assignee toggle \(m.id, privacy: .public) on \(convo.id, privacy: .public)")
        Task {
            if let updated = await cloud.setAssignees(conversationId: convo.id, memberIds: Array(ids), orgId: convo.mxOrgId) {
                await MainActor.run { withAnimation { domainAssignees = updated } }
            }
        }
    }

    /// Internal team notes on the domain thread, with an inline add-note field.
    @ViewBuilder private var notesSection: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s2) {
                Image(systemName: "note.text").font(AppFont.xs2).foregroundStyle(p.accentAmber)
                Text("Internal notes").font(AppFont.xs(.semibold)).foregroundStyle(p.textSecondary)
                Spacer()
                Button { withAnimation { showNoteField.toggle() } } label: {
                    Image(systemName: "plus.circle").font(AppFont.base).foregroundStyle(p.accentViolet)
                }.buttonStyle(.plain)
            }
            if showNoteField {
                HStack(alignment: .bottom, spacing: Space.s2) {
                    TextField("Add a note…", text: $newNote, axis: .vertical)
                        .font(AppFont.sm).foregroundStyle(p.textPrimary)
                        .padding(Space.s2).background(p.bgSurface)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                    Button("Save") { saveNote() }
                        .font(AppFont.xs(.semibold))
                        .foregroundStyle(newNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? p.textTertiary : p.accentViolet)
                        .disabled(newNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if domainNotes.isEmpty && !showNoteField {
                Text("No notes yet").font(AppFont.xs2).foregroundStyle(p.textTertiary)
            }
            ForEach(domainNotes) { note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.body).font(AppFont.sm).foregroundStyle(p.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let who = note.author?.user?.label {
                        Text(who).font(AppFont.xs3).foregroundStyle(p.textTertiary)
                    }
                }
                .padding(Space.s2 + 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(p.accentAmber.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
        }
        .padding(.horizontal, Space.s4)
    }

    private func saveNote() {
        let body = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        Log.action.info("domain add-note on \(convo.id, privacy: .public)")
        Task {
            if let note = await cloud.addNote(conversationId: convo.id, body: body, orgId: convo.mxOrgId) {
                await MainActor.run { withAnimation { domainNotes.append(note); newNote = ""; showNoteField = false } }
            }
        }
    }

    private func toggleTag(_ tag: CloudTag) {
        var ids = Set(domainTags.map(\.id))
        if ids.contains(tag.id) { ids.remove(tag.id) } else { ids.insert(tag.id) }
        withAnimation { domainTags = orgTags.filter { ids.contains($0.id) } }
        Log.action.info("domain tag toggle \(tag.name) on \(convo.id, privacy: .public)")
        Task { _ = await cloud.setTags(conversationId: convo.id, tagIds: Array(ids), orgId: convo.mxOrgId) }
    }
}
