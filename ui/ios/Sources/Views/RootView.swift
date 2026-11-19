import SwiftUI

struct RootView: View {
    @EnvironmentObject var engine: EngineModel

    var body: some View {
        NavigationStack {
            List {
                Section("Shared Rust core") {
                    LabeledContent("InboxEngine", value: engine.status)
                    LabeledContent("Events received", value: "\(engine.eventCount)")
                    LabeledContent("Last event", value: engine.lastEvent)
                }

                Section("Connected accounts (\(engine.accounts.count))") {
                    if engine.accounts.isEmpty {
                        Text("No accounts connected yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(engine.accounts) { acct in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(acct.email).font(AppFont.body)
                                Text("\(acct.provider) · \(acct.status)")
                                    .font(AppFont.xs)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Shared email-body rendering") {
                    NavigationLink {
                        ReaderView(html: SampleEmail.html)
                            .navigationTitle("Re: Q3 pipeline")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("Open sample thread", systemImage: "envelope.open")
                    }
                }
            }
            .navigationTitle("Inbox2")
            .refreshable { engine.refreshAccounts() }
        }
    }
}

/// A realistic sample message: a short reply, a remote tracking pixel (blocked),
/// a Gmail-style quoted original, and a signature — to exercise the shared
/// `@inbox2/email-body` collapse + privacy logic in the iOS WebView.
enum SampleEmail {
    static let html = """
    <div>Thanks — that works for me. Let's lock Friday 10:00 and I'll send an invite.</div>
    <p>Best,<br>Sam</p>
    <img src="https://tracker.example.com/open.gif?id=abc123" width="1" height="1" alt="">
    <div class="gmail_signature">Sam Rivera<br>Head of Ops, Acme<br>+1 555 0142</div>
    <div class="gmail_quote">
      On Mon, Jun 2, 2026 at 9:14 AM Dana Lee &lt;dana@partner.com&gt; wrote:
      <blockquote type="cite">
        Hi Sam, can we move the Q3 pipeline review to later this week? Wednesday or
        Friday morning both work on my end. Also attaching the latest numbers.
      </blockquote>
    </div>
    """
}
