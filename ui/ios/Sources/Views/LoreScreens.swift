import SwiftUI

/// Lore's pushed screens (docs/plans/lore.md §3–4) — the phone's versions of the
/// desktop's org/person pages and Disk notes pages. Read-mostly: an entity page lists
/// what is open with them, who they are, what the miner learned and what was done;
/// a notes page renders its markdown (editing stays on desktop/web).

// MARK: - Organization / person page

struct LoreEntityView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var engine: EngineModel
    @EnvironmentObject private var cloud: CloudSession
    let ref: LoreEntityRef
    /// Open Lore threads and recently archived ones (History), from LoreView's loaders.
    let open: [Conversation]
    let done: [Conversation]
    let onDone: ([Conversation]) -> Void
    @State private var facts: [LoreFact] = []
    @State private var loadingFacts = true

    private var p: ThemePalette { theme.palette }

    private var isOrg: Bool { if case .org = ref { return true } else { return false } }
    private func matches(_ c: Conversation) -> Bool {
        switch ref {
        case .org(let domain): return LoreText.orgDomain(c.email) == domain
        case .person(let address, _): return c.email.lowercased() == address
        }
    }
    private var name: String {
        switch ref {
        case .org(let domain): return LoreText.domainLabel(domain)
        case .person(let address, let name): return name.isEmpty ? address : name
        }
    }
    private var subtitle: String {
        switch ref {
        case .org(let domain): return domain
        case .person(let address, _): return address
        }
    }

    var body: some View {
        let mine = open.filter(matches)
        let openWork = mine.filter { LoreBucket.forLabel($0.triageLabel) != .handled }
        let recent = Array(done.filter(matches).prefix(10))
        let people = Self.people(in: mine + recent)
        let personDomain: String? = { if case .person(let a, _) = ref { return LoreText.orgDomain(a) } else { return nil } }()
        List {
            VStack(alignment: .leading, spacing: Space.s2) {
                if case .org(let domain) = ref {
                    LoreLogo(domain: domain, size: 56)
                } else {
                    Avatar(initials: MailAddress.initials(name), size: 56, seed: MailAddress.seed(subtitle))
                }
                Text(name).font(AppFont.title).foregroundStyle(p.textPrimary)
                Text(isOrg ? "Organization · \(subtitle)" : "Person · \(subtitle)")
                    .font(AppFont.sm).foregroundStyle(p.textTertiary)
                if let personDomain {
                    NavigationLink(value: LoreRoute.entity(.org(domain: personDomain))) {
                        Label("Works at \(LoreText.domainLabel(personDomain))", systemImage: "building.2")
                            .font(AppFont.sm(.semibold)).foregroundStyle(p.accentViolet)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Space.s4)
            .plainListRow()

            section("Open work", count: openWork.count)
            if openWork.isEmpty { muted("Nothing open with \(name).") }
            ForEach(openWork) { c in
                NavigationLink(value: c) { threadRow(c) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button { onDone([c]) } label: { Label("Done", systemImage: "checkmark") }.tint(p.accentSuccess)
                    }
                    .listRowBackground(Color.clear)
            }

            if isOrg && !people.isEmpty {
                section("People", count: people.count)
                ForEach(people, id: \.address) { person in
                    NavigationLink(value: LoreRoute.entity(.person(address: person.address, name: person.name))) {
                        HStack(spacing: Space.s3) {
                            Avatar(initials: MailAddress.initials(person.name), size: 32, seed: MailAddress.seed(person.address))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(person.name).font(AppFont.base).foregroundStyle(p.textPrimary)
                                Text(person.address).font(AppFont.xs2).foregroundStyle(p.textTertiary)
                            }
                            Spacer()
                            Text("\(person.count) \(person.count == 1 ? "thread" : "threads")")
                                .font(AppFont.xs2).foregroundStyle(p.textTertiary)
                        }
                        .padding(.vertical, Space.s1)
                    }
                    .listRowBackground(Color.clear)
                }
            }

            section("Learned from mail", rule: "Mined from your email")
            if facts.isEmpty { muted(loadingFacts ? "Loading…" : "Nothing mined yet for this one.") }
            ForEach(facts, id: \.self) { f in
                VStack(alignment: .leading, spacing: 3) {
                    Text(f.line).font(AppFont.sm(.semibold)).foregroundStyle(p.textPrimary)
                    if let q = f.quote, !q.isEmpty {
                        Text("“\(q)”").font(AppFont.xs).italic().foregroundStyle(p.textSecondary)
                    }
                }
                .padding(.vertical, Space.s1)
                .listRowBackground(Color.clear)
            }

            section("Recently done", rule: "Archived from Lore or the inbox")
            if recent.isEmpty { muted("Nothing archived recently.") }
            ForEach(recent) { c in
                NavigationLink(value: c) {
                    HStack(spacing: Space.s2) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(p.accentSuccess)
                        Text(LoreText.clean(c.subject)).font(AppFont.sm).foregroundStyle(p.textSecondary).lineLimit(1)
                        Spacer()
                        Text(c.time).font(AppFont.xs2).foregroundStyle(p.textTertiary)
                    }
                }
                .listRowBackground(Color.clear)
            }
            Color.clear.frame(height: 100).plainListRow()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(p.bgBase.ignoresSafeArea())
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: ref) { await loadFacts() }
    }

    private func loadFacts() async {
        loadingFacts = true
        let (kind, domain, address): (String, String?, String?) = {
            switch ref {
            case .org(let d): return ("organization", d, nil)
            case .person(let a, _): return ("person", nil, a)
            }
        }()
        async let local = engine.loreFacts(kind: kind, domain: domain, address: address)
        async let remote = cloud.loreFacts(kind: kind, domain: domain, address: address)
        var seen = Set<String>()
        facts = (await local + remote)
            .filter { seen.insert("\($0.kind)|\($0.name)|\($0.value ?? "")|\($0.related?.name ?? "")").inserted }
            .sorted { ($0.confidence ?? 0) > ($1.confidence ?? 0) }
        loadingFacts = false
    }

    /// Distinct senders, most threads first (web `entitiesFrom().people`).
    static func people(in convos: [Conversation]) -> [(address: String, name: String, count: Int)] {
        var by: [String: (name: String, count: Int)] = [:]
        for c in convos where !c.email.isEmpty {
            let key = c.email.lowercased()
            by[key] = (by[key]?.name ?? c.sender, (by[key]?.count ?? 0) + 1)
        }
        return by.map { (address: $0.key, name: $0.value.name, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    private func threadRow(_ c: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(LoreText.clean(c.subject)).font(AppFont.base).foregroundStyle(p.textPrimary).lineLimit(1)
                Spacer(minLength: 0)
                Text(c.time).font(AppFont.xs2).foregroundStyle(p.textTertiary)
            }
            Text(c.preview).font(AppFont.xs).foregroundStyle(p.textSecondary).lineLimit(2)
        }
        .padding(.vertical, Space.s1)
    }

    private func section(_ title: String, count: Int? = nil, rule: String? = nil) -> some View {
        HStack(spacing: Space.s2) {
            Text(title).font(AppFont.section(13)).foregroundStyle(p.textSecondary)
            if let count { Text("\(count)").font(AppFont.xs2).foregroundStyle(p.textTertiary) }
            if let rule { Text(rule).font(AppFont.xs2).foregroundStyle(p.textTertiary) }
            Spacer()
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s4)
        .plainListRow()
    }

    private func muted(_ text: String) -> some View {
        Text(text).font(AppFont.sm).foregroundStyle(p.textTertiary)
            .padding(.horizontal, Space.s4).padding(.vertical, Space.s1)
            .plainListRow()
    }
}

// MARK: - Notes page (read-only)

struct LorePageView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var cloud: CloudSession
    let orgId: String
    let page: LorePageRef
    @State private var markdown: String?
    @State private var error: String?

    private var p: ThemePalette { theme.palette }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text(page.name).font(AppFont.title).foregroundStyle(p.textPrimary)
                Text("Edit this page in Lore on your computer.")
                    .font(AppFont.xs).foregroundStyle(p.textTertiary)
                    .padding(.bottom, Space.s2)
                if let error {
                    Text("Can't open this page. \(error)").font(AppFont.sm).foregroundStyle(p.accentDanger)
                    Button("Try again") { Task { await load() } }.font(AppFont.sm(.semibold)).foregroundStyle(p.accentViolet)
                } else if let markdown {
                    if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Nothing here yet. Add notes on your computer.").font(AppFont.sm).foregroundStyle(p.textTertiary)
                    }
                    ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        block(line)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(Space.s4)
            .padding(.bottom, 100)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(p.bgBase.ignoresSafeArea())
        .navigationTitle(page.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        error = nil
        do { markdown = try await cloud.lorePageMarkdown(orgId: orgId, id: page.id) }
        catch { self.error = error.localizedDescription }
    }

    /// One markdown line: headings, to-dos, bullets, quotes, else a paragraph with inline marks.
    // ponytail: line-by-line, no tables/code fences; a real renderer when pages need them on the phone.
    @ViewBuilder private func block(_ raw: String) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            Color.clear.frame(height: Space.s1)
        } else if line.hasPrefix("#") {
            let level = line.prefix { $0 == "#" }.count
            inline(String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces))
                .font(level == 1 ? AppFont.title2 : AppFont.lg(.semibold))
                .foregroundStyle(p.textPrimary)
                .padding(.top, Space.s2)
        } else if let rest = Self.strip(line, ["- [ ] ", "* [ ] "]) {
            row(icon: "circle", tint: p.textTertiary, text: rest)
        } else if let rest = Self.strip(line, ["- [x] ", "- [X] ", "* [x] "]) {
            row(icon: "checkmark.circle.fill", tint: p.accentSuccess, text: rest, done: true)
        } else if let rest = Self.strip(line, ["- ", "* ", "+ "]) {
            row(icon: "circle.fill", tint: p.textTertiary, text: rest, small: true)
        } else if let rest = Self.strip(line, ["> "]) {
            inline(rest).font(AppFont.sm).italic().foregroundStyle(p.textSecondary)
                .padding(.leading, Space.s3)
                .overlay(alignment: .leading) { Rectangle().fill(p.borderStrong).frame(width: 2) }
        } else {
            inline(line).font(AppFont.base).foregroundStyle(p.textPrimary)
        }
    }

    private static func strip(_ line: String, _ prefixes: [String]) -> String? {
        prefixes.first(where: line.hasPrefix).map { String(line.dropFirst($0.count)) }
    }

    private func row(icon: String, tint: Color, text: String, done: Bool = false, small: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Image(systemName: icon).font(small ? AppFont.glyph(5, .regular) : AppFont.sm).foregroundStyle(tint)
            inline(text).font(AppFont.base)
                .foregroundStyle(done ? p.textTertiary : p.textPrimary)
                .strikethrough(done)
        }
    }

    private func inline(_ s: String) -> Text {
        let attr = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        return Text(attr)
    }
}

// MARK: - Organization logo

/// An organization's icon by domain (`/brands/:domain`, fetched through the image
/// proxy — never from the site itself), cached for the session; initials until it
/// loads or when there is none.
struct LoreLogo: View {
    @EnvironmentObject private var cloud: CloudSession
    let domain: String
    var size: CGFloat = 22
    @State private var image: UIImage?

    @MainActor private static var cache: [String: UIImage?] = [:]

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                Avatar(initials: MailAddress.initials(LoreText.domainLabel(domain)), size: size, seed: MailAddress.seed(domain))
            }
        }
        .accessibilityHidden(true)
        .task(id: domain) { image = await Self.load(domain, cloud) }
    }

    @MainActor private static func load(_ domain: String, _ cloud: CloudSession) async -> UIImage? {
        if let hit = cache[domain] { return hit }
        var out: UIImage?
        if let brand = try? await cloud.mailClient().brand(domain: domain),
           let path = brand.iconURL,
           let remote = URLComponents(string: path)?.queryItems?.first(where: { $0.name == "url" })?.value ?? (path.hasPrefix("http") ? path : nil),
           let uri = await ImageProxy.fetchDataURI(remote, apiKey: Keychain.get(PrivacyStore.apiKeyAccount)),
           let comma = uri.firstIndex(of: ","),
           let data = Data(base64Encoded: String(uri[uri.index(after: comma)...])) {
            out = UIImage(data: data)
        }
        // Only hits are kept: a miss (server not ready, proxy blip) is asked again next time.
        if let out { cache[domain] = .some(out) }
        return out
    }
}
