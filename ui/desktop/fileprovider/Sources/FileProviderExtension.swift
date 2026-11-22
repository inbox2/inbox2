import FileProvider
import os

/// inbox2 Disk in Finder (docs/Disk-Sync.md). macOS owns the local copies;
/// this extension lists, downloads and uploads through the Rust engine. A
/// retryable error (`serverUnreachable`) makes macOS keep the change and call
/// again, so the only write state kept here is the engine's upload in flight.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    let domain: NSFileProviderDomain
    let queue = DispatchQueue(label: "com.inbox2.disk", qos: .userInitiated, attributes: .concurrent)
    private let log = Logger(subsystem: "com.inbox2.disk", category: "extension")
    private let lock = NSLock()
    private var cached: DiskSession?
    private var lastPull = Date.distantPast
    /// Pull at most this often when macOS asks for changes without a signal.
    private let pullEvery: TimeInterval = 20

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }

    func invalidate() {}

    static var groupDir: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "Inbox2AppGroup") as? String else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("Disk", isDirectory: true)
    }

    /// The engine, opened on first use. `SignedOut` until the app writes its config.
    func session() throws -> DiskSession {
        lock.lock()
        defer { lock.unlock() }
        if let s = cached { return s }
        guard let dir = Self.groupDir else { throw DiskError.SignedOut }
        let s = try DiskSession.open(groupDir: dir.path)
        cached = s
        return s
    }

    func pullIfDue(_ session: DiskSession) {
        lock.lock()
        let due = Date().timeIntervalSince(lastPull) > pullEvery
        if due { lastPull = Date() }
        lock.unlock()
        guard due else { return }
        do {
            _ = try session.sync()
        } catch {
            log.info("pull failed: \(String(describing: error), privacy: .public)")
        }
    }

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        queue.async {
            if identifier == .rootContainer { return completionHandler(RootItem(), nil) }
            do {
                completionHandler(Item(try self.session().item(id: Ids.rust(identifier))), nil)
            } catch {
                completionHandler(nil, nsError(error))
            }
        }
        return Progress()
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        queue.async {
            do {
                let s = try self.session()
                let id = Ids.rust(itemIdentifier)
                let path = try s.fetch(id: id, listener: TransferListener(progress))
                completionHandler(URL(fileURLWithPath: path), Item(try s.item(id: id)), nil)
            } catch {
                completionHandler(nil, nil, nsError(error))
            }
        }
        return progress
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        queue.async {
            do {
                let s = try self.session()
                let parent = Ids.rust(itemTemplate.parentItemIdentifier)
                // macOS's id for the new item: the same when it retries this create.
                let op = itemTemplate.itemIdentifier.rawValue
                let created: DiskItem
                if itemTemplate.contentType == .folder {
                    created = try s.createFolder(parentId: parent, name: itemTemplate.filename, opId: op)
                } else if itemTemplate.contentType == .symbolicLink || itemTemplate.contentType == .aliasFile {
                    throw DiskError.NoPermission("links stay on this Mac")
                } else if let url {
                    created = try s.createFile(parentId: parent, name: itemTemplate.filename, src: url.path, opId: op, listener: TransferListener(progress))
                } else {
                    throw DiskError.Other("no content")
                }
                completionHandler(Item(created), [], false, nil)
            } catch {
                completionHandler(nil, [], false, nsError(error))
            }
        }
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
                    contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        queue.async {
            do {
                let s = try self.session()
                let id = Ids.rust(item.itemIdentifier)
                var current = try s.item(id: id)
                var refetch = false
                if changedFields.contains(.parentItemIdentifier) {
                    current = try s.moveTo(id: id, parentId: Ids.rust(item.parentItemIdentifier))
                }
                if changedFields.contains(.filename) {
                    current = try s.rename(id: id, name: item.filename)
                }
                if changedFields.contains(.contents) && newContents == nil {
                    throw DiskError.Other("new content without a file")
                }
                if changedFields.contains(.contents), let newContents {
                    let base = String(data: version.contentVersion, encoding: .utf8) ?? ""
                    let write = try s.modifyContents(id: id, baseVersion: base, src: newContents.path, listener: TransferListener(progress))
                    current = write.item
                    // The server kept its own file; the Mac's edit is now a conflicted copy beside it.
                    refetch = write.conflictCopy != nil
                }
                let handled: NSFileProviderItemFields = [.parentItemIdentifier, .filename, .contents]
                completionHandler(Item(current), changedFields.subtracting(handled), refetch, nil)
            } catch {
                completionHandler(nil, [], false, nsError(error))
            }
        }
        return progress
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        queue.async {
            do {
                try self.session().delete(id: Ids.rust(identifier))
                completionHandler(nil)
            } catch {
                completionHandler(nsError(error))
            }
        }
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .trashContainer { throw NSFileProviderError(.noSuchItem) }
        return Enumerator(container: containerItemIdentifier, ext: self)
    }
}
