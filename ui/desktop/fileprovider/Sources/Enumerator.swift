import FileProvider

/// Lists a folder from the engine's store and reports changes from its log.
/// Changes are domain-wide: the engine keeps one change log, so every
/// enumerator (the working set included) reports the same changes.
final class Enumerator: NSObject, NSFileProviderEnumerator {
    let container: NSFileProviderItemIdentifier
    let ext: FileProviderExtension

    init(container: NSFileProviderItemIdentifier, ext: FileProviderExtension) {
        self.container = container
        self.ext = ext
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        // The working set holds nothing of its own; changes reach it below.
        if container == .workingSet {
            observer.finishEnumerating(upTo: nil)
            return
        }
        ext.queue.async {
            do {
                let session = try self.ext.session()
                if try session.anchor() == 0 { _ = try session.sync() }
                let items = try session.children(parentId: Ids.rust(self.container))
                observer.didEnumerate(items.map(Item.init))
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(nsError(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        ext.queue.async {
            do {
                let session = try self.ext.session()
                // A signal from the app means "pull now"; a failed pull still
                // reports what the store already has.
                self.ext.pullIfDue(session)
                let since = UInt64(String(data: anchor.rawValue, encoding: .utf8) ?? "") ?? 0
                let changes: DiskChanges
                do {
                    changes = try session.changesSince(anchor: since)
                } catch DiskError.NotFound {
                    observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
                    return
                }
                if !changes.updated.isEmpty { observer.didUpdate(changes.updated.map(Item.init)) }
                if !changes.deleted.isEmpty { observer.didDeleteItems(withIdentifiers: changes.deleted.map(Ids.system)) }
                observer.finishEnumeratingChanges(upTo: Self.anchor(changes.anchor), moreComing: changes.more)
            } catch {
                observer.finishEnumeratingWithError(nsError(error))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        ext.queue.async {
            completionHandler((try? self.ext.session().anchor()).map(Self.anchor))
        }
    }

    static func anchor(_ n: UInt64) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data(String(n).utf8))
    }
}
