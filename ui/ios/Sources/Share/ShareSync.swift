import Foundation

/// App side of the "Send to Inbox2" hand-off (`ShareBridge`). The share extension hosts
/// its own compose and sends domain (mx) mail itself, but it can't reach the engine's
/// connected-channel credentials — so it leaves those as durable queued sends. This:
///
/// - **mirrors** the From-identity list + domain session token into the App Group so the
///   extension's picker + direct domain send work, and
/// - **drains** the queued sends via the engine outbox (connected channels) or the cloud
///   API (domain fallback), on foreground + background refresh.
@MainActor
enum ShareSync {
    /// Mirror the current identities + domain token for the extension's compose picker.
    static func writeContext(engine: EngineModel, cloud: CloudSession) {
        var ids: [ShareBridge.Identity] = engine.accounts.map {
            .init(key: $0.id, email: $0.email, label: $0.email, isDomain: false)
        }
        if cloud.isSignedIn, let u = cloud.user {
            for org in cloud.orgs {
                guard let d = org.domain, !d.isEmpty else { continue }
                ids.append(.init(key: org.id, email: "\(u.username)@\(d)", label: org.name, isDomain: true))
            }
        }
        // Top contacts for To/Cc/Bcc autocomplete (frequency-ranked; capped so the
        // mirrored JSON stays small).
        let contacts = engine.store.contacts().prefix(1500).map {
            ShareBridge.Contact(name: $0.name, email: $0.email)
        }
        ShareBridge.writeContext(.init(identities: ids,
                                       token: Keychain.get(CloudSession.tokenKey),
                                       apiBase: AppConfig.apiBase,
                                       contacts: Array(contacts)))
    }

    /// Deliver every queued share-compose send via its matching path; drop each on success.
    static func drain(engine: EngineModel, cloud: CloudSession) async {
        ShareBridge.gcOrphans()
        for job in ShareBridge.pending() {
            let items = ShareBridge.loadAttachments(id: job.id, job.attachments)
            let ok: Bool
            if job.isDomain {
                let atts = items.map {
                    OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType ?? "application/octet-stream", data: $0.data)
                }
                ok = await cloud.send(conversationId: job.conversationId, from: job.fromEmail, to: job.to,
                                      cc: job.cc, subject: job.subject, bodyPlain: job.bodyPlain ?? "",
                                      attachments: atts)
            } else {
                let ffi = items.map { FfiAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) }
                let (sent, _) = await engine.send(accountKey: job.accountKey, from: job.fromEmail, to: job.to,
                                                  cc: job.cc, bcc: job.bcc, subject: job.subject,
                                                  bodyPlain: job.bodyPlain ?? "", attachments: ffi,
                                                  replyToMessageKey: nil)
                ok = sent
            }
            if ok {
                ShareBridge.remove(job.id)
                Log.action.info("share: delivered queued send \(job.id, privacy: .public)")
            } else {
                Log.action.error("share: queued send \(job.id, privacy: .public) failed; will retry")
            }
        }
    }
}
