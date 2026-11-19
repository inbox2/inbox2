import SwiftUI

/// Multi-select + the optimistic row actions of the inbox list: edit mode and the
/// selection set, bulk actions, the single-row file/act/quick/snooze paths and undo.
/// Mutates the rows through `InboxLoader` (optimistic remove + re-query suppression)
/// and raises toasts on `InboxUndoController`; the write-backs go to the engine.
/// `bind` wires the collaborators once (the view's `onAppear`), before any action.
@MainActor
final class InboxBulkController: ObservableObject {
    @Published var editing = false
    @Published var selection: Set<String> = []

    private var loader: InboxLoader!
    private var undoController: InboxUndoController!
    private var engine: EngineModel!
    private var cloud: CloudSession!

    func bind(loader: InboxLoader, undo: InboxUndoController, engine: EngineModel, cloud: CloudSession) {
        self.loader = loader; self.undoController = undo; self.engine = engine; self.cloud = cloud
    }

    private var conversations: [Conversation] {
        get { loader.conversations }
        set { loader.conversations = newValue }
    }

    var allSelected: Bool { !conversations.isEmpty && selection.count == conversations.count }

    func toggleSelect(_ convo: Conversation) {
        withAnimation(.easeOut(duration: 0.15)) {
            if selection.contains(convo.id) { selection.remove(convo.id) } else { selection.insert(convo.id) }
        }
        setAnchor(convo.id)
    }

    // Desktop's multi-select (web `useConversationSelection`): Command toggles one row,
    // Shift selects from the anchor to here, Shift+arrows extend from the anchor. The
    // anchor starts at the thread open in the iPad reader, so it joins the selection.
    private var anchorId: String?
    private var cursorId: String?
    /// What was selected when the anchor was set: a range adds to it (web does too),
    /// and Shift+arrows back towards the anchor shrink only the range.
    private var rangeBase: Set<String> = []

    private func setAnchor(_ id: String?) {
        anchorId = id; cursorId = id
        rangeBase = selection.subtracting([id].compactMap { $0 })
    }

    /// A tap with Shift or Command held (trackpad, mouse or keyboard on iPad).
    func modifiedTap(_ convo: Conversation, shift: Bool, openId: String?) {
        begin(from: openId)
        if shift, let anchor = anchorId { selectRange(anchor, convo.id) } else { toggleSelect(convo) }
    }

    /// Shift+↑ / Shift+↓.
    func extend(by step: Int, openId: String?) {
        begin(from: openId)
        let ids = conversations.map(\.id)
        guard let anchor = anchorId ?? ids.first,
              let at = ids.firstIndex(of: cursorId ?? anchor) else { return }
        let next = ids[max(0, min(ids.count - 1, at + step))]
        selectRange(anchor, next)
    }

    private func begin(from openId: String?) {
        guard !editing else { return }
        selection = Set([openId].compactMap { $0 })
        setAnchor(openId)
        withAnimation { editing = true }
    }

    private func selectRange(_ from: String, _ to: String) {
        let ids = conversations.map(\.id)
        guard let a = ids.firstIndex(of: from), let b = ids.firstIndex(of: to) else { return }
        cursorId = to
        withAnimation(.easeOut(duration: 0.15)) { selection = rangeBase.union(ids[min(a, b)...max(a, b)]) }
    }

    func toggleSelectAll() {
        if allSelected { selection = [] } else { selection = Set(conversations.map(\.id)) }
    }

    /// ⌘A: everything loaded, whether or not multi-select was on.
    func selectAll() {
        if !editing { withAnimation { editing = true } }
        selection = Set(conversations.map(\.id))
        anchorId = nil; cursorId = nil; rangeBase = selection
    }

    func enterEditing(selecting convo: Conversation? = nil) {
        selection = convo.map { [$0.id] } ?? []
        setAnchor(convo?.id)
        withAnimation { editing = true }
    }

    func exitEditing() {
        anchorId = nil; cursorId = nil; rangeBase = []
        withAnimation { editing = false; selection = [] }
    }

    /// Apply an action to every selected conversation, grouped by account (one engine
    /// call per account since the FFI is account-scoped). Destructive moves
    /// (`action.removesRow`: archive/trash/spam) animate the selected rows out.
    func bulk(_ action: ConversationAction) {
        let chosen = conversations.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        Log.action.info("bulk \(action.verb) on \(chosen.count) conv(s)")
        let byAccount = Dictionary(grouping: chosen, by: \.accountKey)
        // Capture each row's original position before removal so undo can restore them.
        let items = chosen.compactMap { convo -> UndoBanner.Item? in
            conversations.firstIndex(where: { $0.id == convo.id }).map { .init(convo: convo, index: $0) }
        }
        let entry = UndoBanner(items: items, action: action, reverse: action.reverse)
        AppBadge.adjust(action, convos: chosen)
        if action.removesRow {
            let ids = selection
            withAnimation { conversations.removeAll { ids.contains($0.id) } }
            loader.pendingRemoved.formUnion(ids)
        }
        for (acct, convos) in byAccount {
            let keys = convos.map(\.id)
            Task { await engine.perform(accountKey: acct, conversationKeys: keys, action: action, cloud: cloud) }
        }
        exitEditing()
        // Offer the same undo toast as the single-row path (shown once edit mode exits).
        undoController.show(entry)
    }

    func snoozeRow(_ convo: Conversation, date: Date) {
        if let idx = conversations.firstIndex(where: { $0.id == convo.id }) {
            withAnimation { _ = conversations.remove(at: idx) }
        }
        loader.pendingRemoved.insert(convo.id)
        // Snoozing an unread thread takes it out of the inbox unread count (domain).
        if convo.unread { AppBadge.adjustDomain(by: -1) }
        Task { _ = await cloud.snooze(conversationId: convo.id, until: date, orgId: convo.mxOrgId) }
    }

    /// Fire-and-forget triage action used by the context menu for actions that don't
    /// need the undo affordance (flag, quadrant, spam). Destructive moves
    /// (`action.removesRow`) animate the row out; toggles leave it and re-query refreshes.
    func quick(_ convo: Conversation, _ action: ConversationAction) {
        Log.action.info("row menu action \(action.verb) on \(convo.id)")
        if action.removesRow, let idx = conversations.firstIndex(where: { $0.id == convo.id }) {
            withAnimation { _ = conversations.remove(at: idx) }
            loader.pendingRemoved.insert(convo.id)
        }
        AppBadge.adjust(action, convos: [convo])
        Task { await engine.perform(accountKey: convo.accountKey, conversationKeys: [convo.id], action: action, cloud: cloud) }
    }

    /// Drop `convo` from the list (when it's still in this snapshot) and raise its
    /// undo banner. The single row-filing path: `act` (swipe/menu) and the reader
    /// hand-off both go through it, so every surface animates, suppresses, and
    /// offers undo identically — only who fires the write-back differs.
    func fileRow(_ convo: Conversation, _ action: ConversationAction) {
        // The banner must NOT depend on the row still being in `conversations`. A
        // sync burst reloads the list many times a second (each reload replaces the
        // array), so a row can vanish from this snapshot mid-action — the lookup is
        // only needed for the restore *position*, never for whether to act at all.
        let idx = conversations.firstIndex(where: { $0.id == convo.id })
        let entry = UndoBanner(items: [.init(convo: convo, index: idx ?? 0)],
                               action: action, reverse: action.reverse)
        withAnimation {
            if action.removesRow {
                if let idx { conversations.remove(at: idx) }
                // Suppress it from re-queries until the write-back lands, or the
                // next reload resurrects it.
                loader.pendingRemoved.insert(convo.id)
            }
            undoController.banner = entry
        }
        undoController.scheduleDismiss(entry)
    }

    /// Optimistically reflect the action, fire the durable write-back, and offer an
    /// undo. Destructive moves (`action.removesRow`) drop the row; toggles stay.
    func act(_ convo: Conversation, _ action: ConversationAction) {
        Log.action.info("act \(action.verb, privacy: .public) on \(convo.id, privacy: .public) acct=\(convo.accountKey, privacy: .public)")
        fileRow(convo, action)
        AppBadge.adjust(action, convos: [convo])
        Task { await engine.perform(accountKey: convo.accountKey, conversationKeys: [convo.id], action: action, cloud: cloud) }
    }

    /// Reverse the active undo banner, re-inserting the removed rows in place (the
    /// undo controller owns the banner + write-back; the loader owns `conversations`).
    func undo() {
        undoController.undo(engine: engine, cloud: cloud) { item in
            // Undoing a removal: stop suppressing the row from re-queries.
            loader.pendingRemoved.remove(item.convo.id)
            guard !conversations.contains(where: { $0.id == item.convo.id }) else { return }
            withAnimation { conversations.insert(item.convo, at: min(item.index, conversations.count)) }
        }
    }
}
