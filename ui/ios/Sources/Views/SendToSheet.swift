import SwiftUI

/// Send a Lore item to another app through its MCP server (web `SendToDialog`,
/// docs/MCP-Client.md). Draft-only: fields are prefilled and editable, and nothing
/// reaches the other app until the person presses Create. The server's text is shown
/// as plain text and never opens anything.
struct SendToSheet: View {
    let convo: Conversation
    let onSent: (LoreSentRef) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    private var p: ThemePalette { theme.palette }

    @State private var connections: [McpConnection]?
    @State private var presets: [McpPreset] = []
    @State private var selected: McpConnection?
    @State private var drafts: [McpDraft]?
    @State private var draftIndex = 0
    @State private var error: String?
    @State private var busy = false
    @State private var result: String?
    @State private var connecting: McpPreset?
    @State private var showConnect = false
    @StateObject private var signIn = McpSignIn()

    private var draft: McpDraft? { drafts.flatMap { $0.indices.contains(draftIndex) ? $0[draftIndex] : nil } }
    private var missing: Bool {
        guard let draft else { return true }
        return draft.fields.contains { $0.required && $0.kind != "boolean" && (draft.values[$0.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(convo.subject).font(AppFont.sm).foregroundStyle(p.textSecondary) }
                if let result {
                    Section("Sent") { Text(result).font(AppFont.sm).textSelection(.enabled) }
                } else {
                    destinations
                    form
                }
                if let error {
                    Section { Text(error).font(AppFont.sm).foregroundStyle(p.accentDanger) }
                }
            }
            .navigationTitle("Send to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(result == nil ? "Cancel" : "Done") { dismiss() } }
                if result == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Create") { create() }.disabled(missing || busy || selected == nil)
                    }
                }
            }
            .sheet(item: $signIn.safari, onDismiss: { signIn.browserClosed() }) { SafariView(url: $0.url) }
            .sheet(item: $connecting) { preset in
                McpConnectSheet(preset: preset) { token, clientId, clientSecret in
                    connecting = nil
                    connect(preset, token: token, clientId: clientId, clientSecret: clientSecret)
                }
            }
            .task { await load() }
        }
    }

    // MARK: - Sections

    @ViewBuilder private var destinations: some View {
        if let connections, !connections.isEmpty {
            Section("Send to") {
                ForEach(connections) { c in
                    Button {
                        Task { await choose(c) }
                    } label: {
                        HStack {
                            Text(c.name).foregroundStyle(p.textPrimary)
                            Spacer()
                            if c.id == selected?.id { Image(systemName: "checkmark").foregroundStyle(p.accentViolet) }
                        }
                        .frame(minHeight: 36)
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { Task { await remove(c) } }
                    }
                }
                Button("Connect another app") { showConnect.toggle() }
            }
        }
        if connections?.isEmpty == true || showConnect {
            Section("Connect an app") {
                ForEach(presets) { preset in
                    Button {
                        if preset.auth == "oauth" { connect(preset) } else { connecting = preset }
                    } label: {
                        Text(preset.name).foregroundStyle(p.textPrimary).frame(minHeight: 36)
                    }
                    .disabled(busy)
                }
            }
        }
        if connections == nil { Section { ProgressView() } }
    }

    @ViewBuilder private var form: some View {
        if let selected, selected.needsAuth {
            Section {
                Button("Sign in again to \(selected.name)") { reauth(selected) }.disabled(busy)
            }
        }
        if selected != nil, drafts == nil, !(selected?.needsAuth ?? false) {
            Section { ProgressView() }
        }
        if let drafts, !drafts.isEmpty, let draft {
            if drafts.count > 1 {
                Section("Action") {
                    Picker("Action", selection: $draftIndex) {
                        ForEach(drafts.indices, id: \.self) { i in Text(drafts[i].name).tag(i) }
                    }
                    .labelsHidden()
                }
            }
            Section("Details") {
                ForEach(draft.fields, id: \.key) { field in fieldRow(field) }
            }
        } else if drafts?.isEmpty == true {
            Section { Text("This app has no actions.").font(AppFont.sm).foregroundStyle(p.textSecondary) }
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { drafts?[draftIndex].values[key] ?? "" },
                set: { drafts?[draftIndex].values[key] = $0 })
    }

    @ViewBuilder private func fieldRow(_ f: McpField) -> some View {
        let label = f.required ? "\(f.label) *" : f.label
        switch f.kind {
        case "boolean":
            Toggle(label, isOn: Binding(get: { binding(f.key).wrappedValue == "true" },
                                        set: { binding(f.key).wrappedValue = $0 ? "true" : "" }))
        case "enum":
            Picker(label, selection: binding(f.key)) {
                Text("—").tag("")
                ForEach(f.options, id: \.self) { Text($0).tag($0) }
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(AppFont.xs).foregroundStyle(p.textSecondary)
                TextField("", text: binding(f.key), axis: f.kind == "json" || f.key.lowercased().contains("desc") || f.key.lowercased().contains("body") ? .vertical : .horizontal)
                    .font(AppFont.sm)
                    .keyboardType(f.kind == "number" || f.kind == "integer" ? .decimalPad : .default)
                if !f.description.isEmpty {
                    Text(f.description).font(AppFont.xs2).foregroundStyle(p.textTertiary)
                }
            }
        }
    }

    // MARK: - Calls

    private func load() async {
        do {
            presets = try McpClient.decode([McpPreset].self, try await McpClient.run { try $0.mcpPresetsJson() })
            try await reloadConnections()
        } catch { connections = []; self.error = text(error) }
    }

    private func reloadConnections() async throws {
        let rows = try McpClient.decode([McpConnection].self, try await McpClient.run { try $0.mcpConnectionsJson() })
        connections = rows
        if let first = rows.first(where: { !$0.needsAuth }) ?? rows.first, selected.map({ s in rows.contains(where: { $0.id == s.id }) }) != true {
            await choose(first)
        }
    }

    private func choose(_ c: McpConnection) async {
        selected = c
        drafts = nil
        draftIndex = 0
        error = nil
        guard !c.needsAuth else { return }
        do {
            let itemJson = String(data: try JSONEncoder().encode(McpItem(convo)), encoding: .utf8) ?? "{}"
            let json = try await McpClient.run { try $0.mcpDraftsJson(id: c.id, itemJson: itemJson) }
            drafts = try McpClient.decode([McpDraft].self, json)
        } catch {
            drafts = []
            self.error = text(error)
        }
    }

    private func connect(_ preset: McpPreset, token: String? = nil, clientId: String? = nil, clientSecret: String? = nil) {
        busy = true
        error = nil
        Task {
            do {
                try await signIn.run { redirect in
                    try McpClient.decode(McpBegun.self, try await McpClient.run { try $0.mcpBeginConnect(name: preset.name, url: preset.url, token: token, clientId: clientId, clientSecret: clientSecret, redirectUri: redirect) })
                }
                selected = nil
                try await reloadConnections()
                showConnect = false
            } catch { self.error = text(error) }
            busy = false
        }
    }

    private func reauth(_ c: McpConnection) {
        busy = true
        error = nil
        Task {
            do {
                try await signIn.run { redirect in
                    try McpClient.decode(McpBegun.self, try await McpClient.run { try $0.mcpBeginReauth(id: c.id, token: nil, redirectUri: redirect) })
                }
                try await reloadConnections()
                await choose(connections?.first { $0.id == c.id } ?? c)
            } catch { self.error = text(error) }
            busy = false
        }
    }

    private func remove(_ c: McpConnection) async {
        do {
            try await McpClient.run { try $0.mcpRemoveConnection(id: c.id) }
            selected = nil
            drafts = nil
            try await reloadConnections()
        } catch { self.error = text(error) }
    }

    /// The person pressed Create: the one place a tool runs.
    private func create() {
        guard let selected, let draft else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let valuesJson = String(data: try JSONEncoder().encode(draft.values), encoding: .utf8) ?? "{}"
                let json = try await McpClient.run { try $0.mcpCreate(id: selected.id, tool: draft.name, valuesJson: valuesJson) }
                let outcome = try McpClient.decode(McpOutcome.self, json)
                if outcome.isError {
                    error = outcome.summary.isEmpty ? "\(draft.name) reported an error." : outcome.summary
                    return
                }
                result = outcome.summary.isEmpty ? "Created." : outcome.summary
                let summary = outcome.summary
                let row = try await McpClient.run { try $0.loreSentAdd(itemKey: LoreSentRef.key(for: convo), connectionName: selected.name, summary: summary) }
                onSent(try McpClient.decode(LoreSentRef.self, row))
            } catch {
                self.error = text(error)
                if text(error).contains("needs_auth") {
                    try? await reloadConnections()
                }
            }
        }
    }

    private func text(_ e: Error) -> String {
        let s = (e as? LocalizedError)?.errorDescription ?? String(describing: e)
        return s.contains("needs_auth") ? "Sign in again to continue." : s.replacingOccurrences(of: "Engine(message: \"", with: "").replacingOccurrences(of: "\")", with: "")
    }
}

private struct McpOutcome: Decodable {
    let summary: String
    let isError: Bool
    enum CodingKeys: String, CodingKey { case summary; case isError = "is_error" }
}

/// `mcp_begin_*`: finished (a token or an open server) or a sign-in to open.
struct McpBegun: Decodable {
    let connected: McpConnection?
    let state: String?
    let authorizeUrl: String?
    enum CodingKeys: String, CodingKey { case connected, state; case authorizeUrl = "authorize_url" }
}

/// Token or OAuth client entry for the presets that need one.
private struct McpConnectSheet: View {
    let preset: McpPreset
    let onConnect: (String?, String?, String?) -> Void
    @State private var token = ""
    @State private var clientId = ""
    @State private var clientSecret = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if preset.auth == "token" {
                    Section("Access token") { SecureField("Token", text: $token) }
                } else {
                    Section("Your app's OAuth client") {
                        TextField("Client ID", text: $clientId).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Client secret (optional)", text: $clientSecret)
                    }
                }
            }
            .navigationTitle(preset.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Connect") {
                        onConnect(token.isEmpty ? nil : token, clientId.isEmpty ? nil : clientId, clientSecret.isEmpty ? nil : clientSecret)
                    }
                    .disabled(preset.auth == "token" ? token.isEmpty : clientId.isEmpty)
                }
            }
        }
    }
}

/// The browser half of sign-in: a loopback port, the provider's page in Safari, one
/// redirect back (the device-link pattern). The core keeps the PKCE verifier.
@MainActor
final class McpSignIn: ObservableObject {
    @Published var safari: IdentifiableURL?
    private var server: LoopbackServer?
    private static let timeout: UInt64 = 300_000_000_000

    func browserClosed() { server?.cancel() }

    /// `begin(redirectUri)` asks the core to start; a server that needed no sign-in stops here.
    func run(_ begin: @escaping (String) async throws -> McpBegun) async throws {
        let server = try LoopbackServer()
        self.server = server
        let port = await server.start()
        defer { server.cancel(); self.server = nil; safari = nil }
        let begun = try await begin("http://127.0.0.1:\(port)/cb")
        guard begun.connected == nil else { return }
        guard let state = begun.state, let raw = begun.authorizeUrl, let url = URL(string: raw) else { throw McpFailure.stateMismatch }
        safari = IdentifiableURL(url: url)
        let timeout = Task { try? await Task.sleep(nanoseconds: Self.timeout); server.cancel() }
        defer { timeout.cancel() }
        let (code, returned) = try await server.awaitCallback()
        safari = nil
        guard returned == state else { throw McpFailure.stateMismatch }
        _ = try await McpClient.run { try $0.mcpFinishConnect(state: state, code: code) }
    }
}
