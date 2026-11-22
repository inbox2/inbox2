import ActivityKit
import Foundation
import UserNotifications

/// Calendar zones (docs/iOS-App.md "Zones"): soft focus blocks on the user's own
/// calendar — "Deep work · Project Atlas", "Prep · Q3 board review". A zone never
/// marks anyone busy; it's a label over time, plus an optional "You're in the zone"
/// alert when it starts. They live on the inbox2 API (user-scoped), so they only
/// exist with a cloud session — every zone surface checks `enabled` first.
///
/// This owns the cache the calendar reads, the writes, and the three alert paths:
///   - a pre-scheduled local notification at each upcoming notify-zone's start
///     (same shape as MeetingAlarms: own `zone-start:` id prefix, `.timeSensitive`),
///   - the in-app sticky card (`ZoneBanner`, reads `activeZone(at:)`),
///   - a Live Activity countdown, started while we're in the foreground.
/// "Done" on the card dismisses that occurrence on every device: kept locally,
/// POSTed to `/account/zone-dismissals`, and applied from the list's `dismissed`
/// flag + the `zones_changed` silent push (PushRegistrar).
@MainActor
final class ZoneStore: ObservableObject {
    static let shared = ZoneStore()

    @Published private(set) var categories: [CloudZoneCategory] = []
    /// Every zone fetched so far, by id — the calendar windows merge into it.
    @Published private(set) var zones: [String: CloudZone] = [:]
    /// Zones the user hit Done on (card + Live Activity stay gone), id → zone end.
    /// An entry drops out once its zone has ended — it can't come back after that.
    @Published private(set) var dismissed: [String: Date]
    /// Zones whose card went up (seen running), id → zone end. The card outlives the
    /// zone ("Zone ended") until Done removes it here.
    @Published private(set) var raised: [String: Date]

    private static let dismissedKey = "inbox2_zone_dismissed"
    private static let raisedKey = "inbox2_zone_raised"
    /// Dismissals not yet accepted by the server, id → zone end; retried on refresh.
    private static let pendingKey = "inbox2_zone_dismiss_pending"
    private static let idPrefix = "zone-start:"
    /// Well under iOS's 64-pending cap, which MeetingAlarms shares.
    // ponytail: fixed window, the next foreground refills it.
    private static let maxScheduled = 16
    /// Wakes at the next zone start / active-zone end while we're alive.
    private var wakeTimer: Task<Void, Never>?
    /// Union of every window fetched — what a series write re-fetches.
    private var loadedFrom: Date?
    private var loadedTo: Date?
    /// Anchored zones with a retime PATCH in flight (reconcile runs on every load).
    private var anchorInFlight: Set<String> = []

    /// The API's palette keys (`ZoneCategory::COLORS`), in picker order.
    static let palette = ["blue", "amber", "violet", "green", "rose", "teal"]

    private init() {
        dismissed = Self.loadMap(Self.dismissedKey)
        raised = Self.loadMap(Self.raisedKey)
    }

    private static func loadMap(_ key: String) -> [String: Date] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:])
            .mapValues { Date(timeIntervalSince1970: $0) }
    }

    private static func saveMap(_ map: [String: Date], _ key: String) {
        UserDefaults.standard.set(map.mapValues(\.timeIntervalSince1970), forKey: key)
    }

    private var cloud: CloudSession { CloudSession.shared }
    private var client: CloudClient { cloud.mailClient() }
    var enabled: Bool { cloud.isSignedIn }

    // MARK: - Reads

    func category(_ id: String?) -> CloudZoneCategory? {
        guard let id else { return nil }
        return categories.first { $0.id == id }
    }

    /// Zones overlapping the given local day, by start.
    func zones(on day: Date) -> [CloudZone] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        return zones.values.filter { $0.start < end && $0.end > start }.sorted { $0.start < $1.start }
    }

    /// The zone the sticky card / Live Activity is about: a notify-zone running now
    /// that the user hasn't dismissed. Overlaps → the one that started last.
    func activeZone(at now: Date) -> CloudZone? {
        zones.values
            .filter { $0.notify && $0.isActive(at: now) && dismissed[$0.id] == nil }
            .max { $0.start < $1.start }
    }

    /// The in-app card: the active zone, or a raised one that has since ended — it
    /// stays until Done. Overlaps → the one that started last.
    func cardZone(at now: Date) -> CloudZone? {
        zones.values
            .filter { z in
                z.notify && dismissed[z.id] == nil
                    && (z.isActive(at: now) || (raised[z.id] != nil && z.start <= now))
            }
            .max { $0.start < $1.start }
    }

    // MARK: - Loading

    /// The window already sits inside what's been fetched (the day view skips a
    /// refetch when paging through days the calendar already loaded).
    func covers(from: Date, to: Date) -> Bool {
        guard let lo = loadedFrom, let hi = loadedTo else { return false }
        return lo <= from && to <= hi
    }

    /// Fetch a window and replace what the cache held for it (so a zone deleted on
    /// another device drops out). Silent on failure — zones are an overlay.
    func load(from: Date, to: Date) async {
        guard enabled else { return }
        if categories.isEmpty { await loadCategories() }
        do {
            let fetched = try await client.zones(startISO: isoLocalInternet.string(from: from),
                                                 endISO: isoLocalInternet.string(from: to))
            var next = zones.filter { !($0.value.start < to && $0.value.end > from) }
            for z in fetched { next[z.id] = z }
            zones = next
            // Clicked away on another device.
            for z in fetched where z.dismissed && dismissed[z.id] == nil { markDismissed(id: z.id, end: z.end) }
            loadedFrom = min(loadedFrom ?? from, from)
            loadedTo = max(loadedTo ?? to, to)
        } catch {
            Log.cloud.warning("zones load failed: \(String(describing: error), privacy: .public)")
        }
    }

    func loadCategories() async {
        guard enabled else { return }
        do { categories = try await client.zoneCategories().sorted { ($0.position ?? 0) < ($1.position ?? 0) } }
        catch { Log.cloud.warning("zone categories failed: \(String(describing: error), privacy: .public)") }
    }

    /// Foreground / sign-in: pull the near window, then re-arm every alert path.
    /// Signed out clears everything instead.
    func refresh() async {
        // Still validating the stored token at launch — don't tear down alerts yet.
        guard cloud.state != .loading else { return }
        guard enabled else {
            zones = [:]; categories = []; loadedFrom = nil; loadedTo = nil
            UserDefaults.standard.removeObject(forKey: Self.pendingKey)
            await syncAlerts()
            return
        }
        await flushPendingDismissals()
        await loadCategories()
        let now = Date()
        await load(from: now.addingTimeInterval(-86_400), to: now.addingTimeInterval(14 * 86_400))
        await syncAlerts()
    }

    // MARK: - Writes

    /// Create (`editing == nil`) or update a zone. Editing an occurrence PATCHes by
    /// its occurrence id, so a retime shifts the whole series by the same delta.
    /// Returns an error message, nil on success.
    func save(editing: CloudZone?, name: String, note: String, categoryId: String?,
              start: Date, end: Date, notify: Bool, repeatRule: String = CloudZone.repeatNone,
              repeatUntil: Date? = nil, anchorEventId: String? = nil, anchorMinutes: Int? = nil,
              clearAnchor: Bool = false) async -> String? {
        var body: [String: Any] = [
            "name": name, "note": note, "category_id": categoryId ?? NSNull(),
            "start_at": isoLocalInternet.string(from: start), "end_at": isoLocalInternet.string(from: end),
            "notify": notify, "repeat": repeatRule,
            "repeat_until": repeatUntil.map { Self.day.string(from: $0) } ?? NSNull(),
        ]
        if editing == nil { body["time_zone"] = TimeZone.current.identifier }
        if let anchorEventId, let anchorMinutes {
            body["anchor_event_id"] = anchorEventId; body["anchor_minutes"] = anchorMinutes
        } else if clearAnchor {
            body["anchor_event_id"] = NSNull(); body["anchor_minutes"] = NSNull()
        }
        do {
            let z = try await client.saveZone(id: editing?.id, body: body)
            // The response is the series (bare key, first times) — never an occurrence.
            // Drop what we held for it; a repeating zone re-fetches its occurrences.
            zones = zones.filter { $0.value.seriesId != z.seriesId }
            if z.isRepeating || editing?.isRepeating == true { await reloadLoaded() } else { zones[z.id] = z }
            // A moved/re-armed zone should alert again.
            if let id = editing?.id, dismissed[id] != nil || raised[id] != nil {
                dismissed[id] = nil; raised[id] = nil
                Self.saveMap(dismissed, Self.dismissedKey); Self.saveMap(raised, Self.raisedKey)
            }
            await syncAlerts()
            return nil
        } catch {
            return (error as? CloudError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Re-fetch everything we've shown so far (API caps a window at 400 days).
    private func reloadLoaded() async {
        let from = loadedFrom ?? Date().addingTimeInterval(-86_400)
        let to = min(loadedTo ?? Date().addingTimeInterval(14 * 86_400), from.addingTimeInterval(399 * 86_400))
        await load(from: from, to: to)
    }

    /// Deletes the whole series (the API does, whichever id it's given).
    func delete(_ zone: CloudZone) async -> String? {
        do {
            try await client.deleteZone(id: zone.id)
            zones = zones.filter { $0.value.seriesId != zone.seriesId }
            await syncAlerts()
            return nil
        } catch {
            return (error as? CloudError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// "Prep: <title>" ending when the meeting starts, in the "Prep" category,
    /// anchored to the event so it follows a reschedule.
    func createPrep(title: String, eventId: String, meetingStart: Date, minutes: Int) async -> String? {
        let prep = categories.first { $0.name.caseInsensitiveCompare("Prep") == .orderedSame }
        return await save(editing: nil, name: "Prep: \(title)", note: "", categoryId: prep?.id,
                          start: meetingStart.addingTimeInterval(TimeInterval(-minutes * 60)),
                          end: meetingStart, notify: true, anchorEventId: eventId, anchorMinutes: minutes)
    }

    /// Prep zones follow their meeting: for each anchored zone whose event is in
    /// `events` (the loaded calendar rows — cancelled ones are already filtered out
    /// by the store) and whose start moved, retime the zone to end at the new start.
    /// An event that isn't loaded leaves its zone alone.
    func reconcileAnchors(_ events: [CalendarEvent]) {
        guard enabled, zones.values.contains(where: { $0.anchorEventId != nil }) else { return }
        let byId = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for z in zones.values where !z.isRepeating && !anchorInFlight.contains(z.id) {
            guard let eid = z.anchorEventId, let mins = z.anchorMinutes, let ev = byId[eid],
                  !ev.allDay, let evStart = ev.start, abs(evStart.timeIntervalSince(z.end)) >= 60
            else { continue }
            anchorInFlight.insert(z.id)
            Task {
                defer { anchorInFlight.remove(z.id) }
                let body: [String: Any] = [
                    "start_at": isoLocalInternet.string(from: evStart.addingTimeInterval(TimeInterval(-mins * 60))),
                    "end_at": isoLocalInternet.string(from: evStart),
                ]
                do {
                    let moved = try await client.saveZone(id: z.id, body: body)
                    zones[z.id] = nil
                    zones[moved.id] = moved
                    await syncAlerts()
                    Log.cloud.info("prep zone \(z.id, privacy: .public) followed its meeting")
                } catch {
                    Log.cloud.warning("prep zone retime failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    // MARK: - Categories

    /// Create (`id == nil`) or update a category. Error message, nil on success.
    func saveCategory(id: String?, name: String, color: String) async -> String? {
        do {
            let c = try await client.saveZoneCategory(id: id, body: ["name": name, "color": color])
            if let i = categories.firstIndex(where: { $0.id == c.id }) { categories[i] = c } else { categories.append(c) }
            return nil
        } catch {
            return (error as? CloudError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Its zones stay, uncategorised — mirror that in the cache.
    func deleteCategory(_ id: String) async -> String? {
        do {
            try await client.deleteZoneCategory(id: id)
            categories.removeAll { $0.id == id }
            zones = zones.mapValues { z in
                var z = z
                if z.categoryId == id { z.categoryId = nil }
                return z
            }
            return nil
        } catch {
            return (error as? CloudError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Done on the sticky card: gone from the app and the lock screen.
    func dismiss(_ zone: CloudZone) { dismiss(id: zone.id) }

    /// Silent `zones_changed` push: apply its dismissal (if any) right away, then
    /// refetch. Waits out the launch-time session restore, which `refresh` skips.
    func syncFromPush(dismissed id: String?) async {
        if let id { applyRemoteDismissal(id: id) }
        for _ in 0..<20 where cloud.state == .loading { try? await Task.sleep(for: .milliseconds(250)) }
        await refresh()
    }

    /// Another device hit Done on this occurrence.
    func applyRemoteDismissal(id: String) {
        guard dismissed[id] == nil else { return }
        markDismissed(id: id, end: knownEnd(id))
    }

    /// The end is what prunes a dismissal; a background launch only has the activity's.
    private func knownEnd(_ id: String) -> Date {
        zones[id]?.end
            ?? Activity<ZoneActivityAttributes>.activities.first { $0.attributes.zoneId == id }?.attributes.end
            ?? raised[id] ?? Date().addingTimeInterval(86_400)
    }

    /// POST every queued dismissal. Network/5xx/auth failures stay queued for the
    /// next refresh; 404/422 (zone deleted, bad row) are dropped.
    private func flushPendingDismissals() async {
        var settled: Set<String> = []
        for (id, end) in Self.loadMap(Self.pendingKey) where end > Date() {
            do {
                try await client.dismissZone(occurrenceId: id, endISO: isoLocalInternet.string(from: end))
                settled.insert(id)
            } catch CloudError.http(let code, _) where code == 404 || code == 422 {
                settled.insert(id)
            } catch {
                Log.cloud.info("zone dismissal post failed, retrying later: \(String(describing: error), privacy: .public)")
            }
        }
        // Re-read: a Done tapped mid-flush added to the queue meanwhile.
        let now = Date()
        Self.saveMap(Self.loadMap(Self.pendingKey).filter { !settled.contains($0.key) && $0.value > now },
                     Self.pendingKey)
    }

    /// Also the Live Activity's Done button (`ZoneDoneIntent`), which may run in a
    /// background launch with an empty cache — so end the card directly and only
    /// re-sync alerts when there's a cache to sync from (an empty one would cancel
    /// every pending zone alert).
    /// The returned task is the server POST (queued first, so a failure retries on
    /// the next refresh) — the intent awaits it so a background launch isn't
    /// suspended mid-request.
    @discardableResult
    func dismiss(id: String) -> Task<Void, Never> {
        let end = knownEnd(id)
        markDismissed(id: id, end: end)
        var pending = Self.loadMap(Self.pendingKey)
        pending[id] = end
        Self.saveMap(pending, Self.pendingKey)
        if !zones.isEmpty { Task { await syncAlerts() } }
        return Task { await flushPendingDismissals() }
    }

    /// Local or remote Done: hide the card, end the Live Activity, and drop the
    /// start notification (pending or already on screen).
    private func markDismissed(id: String, end: Date) {
        dismissed[id] = end
        raised[id] = nil
        prune(Date())
        for activity in Activity<ZoneActivityAttributes>.activities where activity.attributes.zoneId == id {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.idPrefix + id])
        center.removeDeliveredNotifications(withIdentifiers: [Self.idPrefix + id])
    }

    /// Drop dismissals of ended zones, and raised cards past the cache window
    /// (`refresh` keeps a day back) — neither can render any more. Persists both.
    private func prune(_ now: Date) {
        dismissed = dismissed.filter { $0.value > now }
        raised = raised.filter { $0.value > now.addingTimeInterval(-86_400) }
        Self.saveMap(dismissed, Self.dismissedKey)
        Self.saveMap(raised, Self.raisedKey)
    }

    // MARK: - Alerts

    /// Bring the notifications and the Live Activity in line with the cache.
    func syncAlerts() async {
        await syncNotifications()
        syncLiveActivity()
    }

    private func syncNotifications() async {
        let now = Date()
        let upcoming = zones.values
            .filter { $0.notify && $0.start > now && dismissed[$0.id] == nil }
            .sorted { $0.start < $1.start }
            .prefix(Self.maxScheduled)
        // Too close to re-add safely (the trigger could pass mid-add) — but their
        // pending request stays: it's about to fire.
        let wanted = upcoming.filter { $0.start > now.addingTimeInterval(5) }
        let center = UNUserNotificationCenter.current()
        let wantedIds = Set(upcoming.map { Self.idPrefix + $0.id })
        let stale = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.idPrefix) && !wantedIds.contains($0) }
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
        // Re-adding an identifier replaces it, so edits (name/time) just land.
        for zone in wanted {
            let content = UNMutableNotificationContent()
            content.title = "You're in the zone: \(zone.name)"
            var body = "\(category(zone.categoryId)?.name ?? "Zone") until \(Self.clock.string(from: zone.end))"
            if let note = zone.note, !note.isEmpty { body += "\n\(note)" }
            content.body = body
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.threadIdentifier = "zones"
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: zone.start)
            let req = UNNotificationRequest(identifier: Self.idPrefix + zone.id, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
            do { try await center.add(req) }
            catch { Log.engine.error("zone alert add failed: \(String(describing: error), privacy: .public)") }
        }
        Log.engine.info("zone alerts: \(wanted.count) armed, -\(stale.count)")
    }

    /// One Live Activity for the active zone (it ends with the zone — the in-app card
    /// doesn't). iOS only lets us START it in the foreground; ending works any time.
    /// `staleDate` + the timer-driven text cover the zone running out while we're
    /// suspended; the next foreground ends it for good. Also raises the card.
    private func syncLiveActivity() {
        let now = Date()
        let active = enabled ? activeZone(at: now) : nil
        prune(now)
        if let active, raised[active.id] == nil {
            raised[active.id] = active.end
            Self.saveMap(raised, Self.raisedKey)
        }
        for activity in Activity<ZoneActivityAttributes>.activities
        where activity.attributes.zoneId != active?.id || activity.attributes.end != active?.end {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        // Re-evaluate (while we're alive) when the active zone ends or the next
        // notify-zone starts, so the card + Live Activity switch on time.
        wakeTimer?.cancel()
        let nextStart = zones.values
            .filter { $0.notify && $0.start > now && dismissed[$0.id] == nil }
            .map(\.start).min()
        if let wake = [active?.end, nextStart].compactMap({ $0 }).min() {
            wakeTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(1, wake.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                self?.syncLiveActivity()
            }
        }
        guard let zone = active, AppActivity.isForeground, ActivityAuthorizationInfo().areActivitiesEnabled,
              !Activity<ZoneActivityAttributes>.activities.contains(where: { $0.attributes.zoneId == zone.id })
        else { return }
        let attrs = ZoneActivityAttributes(
            zoneId: zone.id, name: zone.name, note: zone.note ?? "",
            category: category(zone.categoryId)?.name ?? "",
            colorKey: category(zone.categoryId)?.color ?? "blue",
            start: zone.start, end: zone.end)
        do {
            _ = try Activity.request(attributes: attrs,
                                     content: .init(state: .init(), staleDate: zone.end),
                                     pushType: nil)
        } catch {
            Log.ui.error("zone live activity failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// "YYYY-MM-DD" for `repeat_until`.
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"; return f
    }()

    static var clock: DateFormatter { CalendarClock.formatter }
}
