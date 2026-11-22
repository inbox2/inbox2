import AppKit
import FileProvider

/// Thumbnails from the server and Finder's "Copy inbox2 Link" (docs/Disk-Sync.md).
extension FileProviderExtension: NSFileProviderThumbnailing, NSFileProviderCustomAction {
    static let thumbnailsAtOnce = 4
    static let copyLinkAction = NSFileProviderExtensionActionIdentifier("com.inbox2.disk.copy-link")

    /// The server's thumbnail for each item, so Finder shows previews of files
    /// that are not downloaded. No thumbnail is not an error: Finder keeps the icon.
    func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier], requestedSize size: CGSize,
                         perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
                         completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        // The completion runs once: on cancel at once, else when the last thumbnail is in.
        let done = NSLock()
        var finished = false
        let finish: (Error?) -> Void = { error in
            done.lock()
            let first = !finished
            finished = true
            done.unlock()
            if first { completionHandler(error) }
        }
        progress.cancellationHandler = { finish(CocoaError(.userCancelled)) }
        queue.async {
            let s: DiskSession
            do { s = try self.session() } catch { return finish(nsError(error)) }
            // A few at a time, so one slow thumbnail does not hold up the rest.
            let group = DispatchGroup()
            let slots = DispatchSemaphore(value: Self.thumbnailsAtOnce)
            for id in itemIdentifiers {
                if progress.isCancelled { break }
                slots.wait()
                group.enter()
                self.queue.async {
                    defer { slots.signal(); group.leave() }
                    if progress.isCancelled { return }
                    let result: (Data?, Error?)
                    do { result = (try s.thumbnail(id: Ids.rust(id)), nil) } catch { result = (nil, nsError(error)) }
                    // A request still running when Finder cancelled reports nothing.
                    if progress.isCancelled { return }
                    perThumbnailCompletionHandler(id, result.0, result.1)
                    progress.completedUnitCount += 1
                }
            }
            group.notify(queue: self.queue) {
                finish(progress.isCancelled ? CocoaError(.userCancelled) : nil)
            }
        }
        return progress
    }

    func performAction(identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
                       onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
                       completionHandler: @escaping (Error?) -> Void) -> Progress {
        queue.async {
            guard actionIdentifier == Self.copyLinkAction, let first = itemIdentifiers.first else {
                return completionHandler(NSFileProviderError(.noSuchItem))
            }
            do {
                let url = try self.session().link(id: Ids.rust(first))
                DispatchQueue.main.async {
                    let board = NSPasteboard.general
                    board.clearContents()
                    board.setString(url, forType: .string)
                    completionHandler(nil)
                }
            } catch {
                completionHandler(nsError(error))
            }
        }
        return Progress()
    }
}
