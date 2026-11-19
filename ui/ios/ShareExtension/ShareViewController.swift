import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// The "Send to Inbox2" share-sheet target. It hosts the app's compose UI right in the
/// share sheet (`ShareComposeView`) — Gmail-style, no app launch — and sends from here:
/// domain (mx) identities go straight through the reused `CloudClient`; connected channels
/// are queued into the App Group for the app to deliver from its outbox.
///
/// Shared files are COPIED (not read into memory): a share extension's ~120 MB limit means
/// a shared video read via `Data(contentsOf:)` would get the extension killed.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        Task { await loadThenPresent() }
    }

    private func loadThenPresent() async {
        let context = ShareBridge.readContext() ?? ShareBridge.Context(identities: [], token: nil, apiBase: "https://api.inbox2.com/api/v1")
        // Make the reused CloudClient resolve the same API base the app uses.
        UserDefaults.standard.set(context.apiBase, forKey: AppConfig.baseURLKey)

        var atts: [ShareBridge.Attachment] = []
        var text: String?
        var sendId = ""

        if let (id, dir) = ShareBridge.newSendDir() {
            sendId = id
            var index = 0
            for item in (extensionContext?.inputItems as? [NSExtensionItem]) ?? [] {
                if let s = item.attributedContentText?.string, !s.isEmpty { text = s }
                for provider in item.attachments ?? [] {
                    if let att = await copyFile(provider, into: dir, index: index) {
                        atts.append(att); index += 1
                    } else if let t = await loadText(provider) {
                        text = t
                    } else if let url = await loadURL(provider) {
                        text = [text, url.absoluteString].compactMap { $0 }.joined(separator: "\n")
                    }
                }
            }
        }

        let staged = atts
        let stagedText = text ?? ""
        let stagedId = sendId
        await MainActor.run {
            present(context: context, sendId: stagedId, attachments: staged, subject: "", body: stagedText)
        }
    }

    @MainActor private func present(context: ShareBridge.Context, sendId: String,
                                    attachments: [ShareBridge.Attachment], subject: String, body: String) {
        let root = ShareComposeView(
            identities: context.identities, context: context, sendId: sendId,
            attachments: attachments, subject: subject, body: body
        ) { [weak self] composed in
            // If the user cancelled, drop the staged files so they don't linger.
            if !composed { ShareBridge.discard(id: sendId) }
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: self.view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    // MARK: Item loading

    /// Copy any data-bearing provider (file/image/movie/pdf) into the send dir. Skips
    /// plain text / URLs — those become body text instead.
    private func copyFile(_ provider: NSItemProvider, into dir: URL, index: Int) async -> ShareBridge.Attachment? {
        let typeId = provider.registeredTypeIdentifiers.first { id in
            guard let t = UTType(id) else { return false }
            return t.conforms(to: .data) && !t.conforms(to: .plainText) && t != .url && t != .fileURL
        } ?? (provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ? UTType.fileURL.identifier : nil)
        guard let typeId else { return nil }

        return await withCheckedContinuation { cont in
            provider.loadFileRepresentation(forTypeIdentifier: typeId) { url, _ in
                guard let url else { cont.resume(returning: nil); return }
                let mime = UTType(typeId)?.preferredMIMEType
                    ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                cont.resume(returning: ShareBridge.copyIn(url, mimeType: mime, index: index, into: dir))
            }
        }
    }

    private func loadText(_ provider: NSItemProvider) async -> String? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) else { return nil }
        return await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                cont.resume(returning: item as? String)
            }
        }
    }

    private func loadURL(_ provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
              !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                cont.resume(returning: item as? URL)
            }
        }
    }
}
