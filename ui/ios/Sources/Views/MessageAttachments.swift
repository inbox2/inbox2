import SwiftUI
import QuickLook
import UIKit
import UniformTypeIdentifiers

/// A minimal exportable document wrapping raw attachment bytes, for the
/// "Save to Files…" `fileExporter` on attachment chips.
struct AttachmentDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Attachment download / Quick Look preview / "Save to Files…" export state for a
/// `MessageCard`, split out of the view so the download-in-flight indicator, the
/// preview URL and the export sheet don't each have to be separate `@State` on the
/// card. Same observation pattern as `EngineModel` (`@MainActor` + `ObservableObject`
/// + `@Published`); the two fetches run on the main actor, matching the original
/// `await MainActor.run` bodies.
@MainActor
final class AttachmentInteraction: ObservableObject {
    @Published var downloadingId: String?
    @Published var previewURL: URL?
    // "Save to Files…" export state for an attachment.
    @Published var exportDoc: AttachmentDocument?
    @Published var exportName = ""
    @Published var exportType: UTType = .data
    @Published var showExport = false

    /// Download the attachment to a temp file and hand it to Quick Look.
    func open(_ att: AttachmentInfo, engine: EngineModel, accountKey: String, messageKey: String) {
        guard downloadingId == nil else { return }
        downloadingId = att.attachmentId
        Task {
            let data = await engine.downloadAttachment(accountKey: accountKey, messageKey: messageKey, attachmentId: att.attachmentId)
            downloadingId = nil
            guard let data else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(att.filename)
            do {
                try data.write(to: url, options: .atomic)
                previewURL = url
            } catch {
                Log.action.error("attachment write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Save this file to the Files app: download its bytes, then present the
    /// system export sheet (defaults to the original filename).
    func save(_ att: AttachmentInfo, engine: EngineModel, accountKey: String, messageKey: String) {
        guard downloadingId == nil else { return }
        downloadingId = att.attachmentId
        Task {
            let data = await engine.downloadAttachment(accountKey: accountKey, messageKey: messageKey, attachmentId: att.attachmentId)
            downloadingId = nil
            guard let data else { return }
            exportDoc = AttachmentDocument(data: data)
            exportType = UTType(filenameExtension: (att.filename as NSString).pathExtension) ?? .data
            exportName = (att.filename as NSString).deletingPathExtension
            showExport = true
        }
    }
}

/// The attachment chips on a `MessageCard` (tap = Quick Look; long-press = Open /
/// Forward / Save to Files…) and the forward-one-file path. Split from the card so
/// the invite/body code doesn't share a file with the download plumbing.
extension MessageCard {
    var attachmentList: some View {
        VStack(spacing: Space.s2) {
            ForEach(attachments) { att in
                Button { download.open(att, engine: engine, accountKey: accountKey, messageKey: message.id) } label: {
                    HStack(spacing: Space.s2) {
                        AttachmentFileIcon(filename: att.filename, fallback: att.icon, tint: p.accentViolet)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(att.filename).font(AppFont.xs).foregroundStyle(p.textPrimary).lineLimit(1)
                            Text(att.sizeLabel).font(AppFont.xs3).foregroundStyle(p.textTertiary)
                        }
                        Spacer()
                        if download.downloadingId == att.attachmentId {
                            ProgressView().controlSize(.small).tint(p.accentViolet)
                        } else {
                            Image(systemName: "arrow.down.circle").font(AppFont.md(.regular)).foregroundStyle(p.textTertiary)
                        }
                    }
                    .padding(.horizontal, Space.s3).padding(.vertical, Space.s2)
                    .background(p.bgRaised)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(download.downloadingId != nil)
                .contextMenu {
                    Button { download.open(att, engine: engine, accountKey: accountKey, messageKey: message.id) } label: { Label("Open", systemImage: "arrow.up.right.square") }
                    Button { forwardAttachment(att) } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                    Divider()
                    Button { download.save(att, engine: engine, accountKey: accountKey, messageKey: message.id) } label: { Label("Save to Files…", systemImage: "square.and.arrow.down") }
                }
            }
        }
        // Match the surrounding sections' top-only rhythm (details block / details
        // bar both use Space.s2) so the attachments sit with equal margin above and
        // below, rather than the old top s1 / bottom s3.
        .padding(.horizontal, Space.s3)
        .padding(.top, Space.s2)
    }

    /// Forward just this file: open the composer immediately with a pending
    /// placeholder (its metadata is already known); ComposeView downloads the
    /// bytes in-screen and blocks Send until they land.
    private func forwardAttachment(_ att: AttachmentInfo) {
        composeDraft = ComposeDraft(
            fromAccountKey: accountKey,
            fromEmailOverride: fromEmailOverride,
            attachments: [.pending(filename: att.filename, mimeType: att.mimeType,
                                   download: .init(accountKey: accountKey, messageKey: message.id, attachmentId: att.attachmentId))]
        )
    }
}

/// The native iOS document icon for a file's type (PDF, DOCX, ZIP, …) — the mobile
/// equivalent of the desktop's OS-native file-type icons (`get_file_type_icon`).
/// `UIDocumentInteractionController` resolves a filename's extension to the system
/// icon set without needing the file on disk; we cache per extension and fall back to
/// the SF Symbol glyph when the system offers nothing.
private enum FileTypeIconCache {
    private static var cache: [String: UIImage?] = [:]
    static func icon(for filename: String) -> UIImage? {
        let ext = (filename as NSString).pathExtension.lowercased()
        let key = ext.isEmpty ? "·" : ext
        if let cached = cache[key] { return cached }
        let controller = UIDocumentInteractionController()
        controller.name = filename.isEmpty ? "file" : filename
        let image = controller.icons.max(by: { $0.size.width < $1.size.width })
        cache[key] = image
        return image
    }
}

/// Renders the native file-type icon for an attachment, falling back to the SF Symbol
/// kind glyph (`AttachmentInfo.icon`) when the system has no icon for the type.
private struct AttachmentFileIcon: View {
    let filename: String
    let fallback: String
    let tint: Color
    var body: some View {
        if let image = FileTypeIconCache.icon(for: filename) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: fallback)
                .font(AppFont.base)
                .foregroundStyle(tint)
                .frame(width: 24)
        }
    }
}
