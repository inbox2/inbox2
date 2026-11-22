import FileProvider
import UniformTypeIdentifiers

/// Maps the engine's ids onto File Provider's: the engine calls the root "root".
enum Ids {
    static func rust(_ id: NSFileProviderItemIdentifier) -> String {
        switch id {
        case .rootContainer: return "root"
        case .trashContainer: return "trash"
        case .workingSet: return "working-set"
        default: return id.rawValue
        }
    }

    static func system(_ id: String) -> NSFileProviderItemIdentifier {
        id == "root" ? .rootContainer : NSFileProviderItemIdentifier(id)
    }
}

/// One Disk node as Finder sees it.
final class Item: NSObject, NSFileProviderItem {
    let disk: DiskItem

    init(_ disk: DiskItem) {
        self.disk = disk
    }

    var itemIdentifier: NSFileProviderItemIdentifier { Ids.system(disk.id) }
    var parentItemIdentifier: NSFileProviderItemIdentifier { Ids.system(disk.parentId) }
    var filename: String { disk.filename }

    var isDriveRoot: Bool { disk.parentId == "root" }
    var isFolder: Bool { disk.kind == "folder" }

    var contentType: UTType {
        if isFolder { return .folder }
        if disk.kind == "page" { return UTType("com.inbox2.page") ?? .json }
        let ext = (disk.filename as NSString).pathExtension
        return UTType(filenameExtension: ext) ?? .data
    }

    var capabilities: NSFileProviderItemCapabilities {
        var caps: NSFileProviderItemCapabilities = [.allowsReading]
        if isFolder { caps.insert(.allowsContentEnumerating) }
        guard disk.canWrite else { return caps }
        if isFolder { caps.insert(.allowsAddingSubItems) }
        if !isFolder && disk.kind != "page" { caps.insert(.allowsWriting) }
        if !isDriveRoot { caps.formUnion([.allowsRenaming, .allowsReparenting, .allowsDeleting]) }
        return caps
    }

    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data(disk.contentVersion.utf8), metadataVersion: Data(disk.metadataVersion.utf8))
    }

    /// "Keep on this Mac" sits on the drive roots; everything else inherits.
    var contentPolicy: NSFileProviderContentPolicy {
        disk.keepDownloaded ? .downloadEagerlyAndKeepDownloaded : .inherited
    }

    var documentSize: NSNumber? { isFolder ? nil : NSNumber(value: disk.size) }
    var contentModificationDate: Date? { disk.modifiedAt > 0 ? Date(timeIntervalSince1970: TimeInterval(disk.modifiedAt)) : nil }
}

/// The root container before the first sync answers.
final class RootItem: NSObject, NSFileProviderItem {
    var itemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { "inbox2" }
    var contentType: UTType { .folder }
    var capabilities: NSFileProviderItemCapabilities { [.allowsReading, .allowsContentEnumerating] }
    var itemVersion: NSFileProviderItemVersion { NSFileProviderItemVersion(contentVersion: Data("root".utf8), metadataVersion: Data("root".utf8)) }
}

/// What the engine's errors mean to macOS. `serverUnreachable` makes macOS
/// keep the change and call again later.
func nsError(_ error: Error) -> Error {
    guard let e = error as? DiskError else { return NSFileProviderError(.cannotSynchronize) }
    switch e {
    case .Offline: return NSFileProviderError(.serverUnreachable)
    case .SignedOut: return NSFileProviderError(.notAuthenticated)
    case .NotFound: return NSFileProviderError(.noSuchItem)
    case .NoPermission: return CocoaError(.fileWriteNoPermission)
    case .StorageFull: return NSFileProviderError(.insufficientQuota)
    case .NameTaken: return NSFileProviderError(.filenameCollision)
    case .NameNotAllowed: return CocoaError(.fileWriteInvalidFileName)
    case .Locked: return CocoaError(.fileReadNoPermission)
    case .Other: return NSFileProviderError(.cannotSynchronize)
    }
}

/// Reports engine progress into a Progress macOS shows as the Finder pie.
final class TransferListener: DiskTransferListener {
    let progress: Progress

    init(_ progress: Progress) {
        self.progress = progress
    }

    func progress(done: UInt64, total: UInt64) {
        guard total > 0 else { return }
        progress.totalUnitCount = Int64(total)
        progress.completedUnitCount = Int64(done)
    }

    func isCancelled() -> Bool { progress.isCancelled }
}
