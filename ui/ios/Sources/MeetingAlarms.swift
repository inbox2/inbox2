import Foundation
import UserNotifications

/// "Your meeting starts in 5 minutes" alarms, pre-scheduled with iOS.
///
/// Every alarm is a local notification handed to the system ahead of time, so it
/// fires whether or not the app is running, backgrounded, or even launched since —
/// no server, no background wake, nothing to go wrong at fire time. The app's only
/// job is keeping that schedule in step with the calendar, which `reconcile` does
/// on foreground, after each sync, and whenever the settings change.
///
/// As alarm-like as iOS lets a normal app be:
///   - a 25s custom sound (`Resources/meeting-alarm.caf`; the OS ignores custom
///     notification sounds longer than 30s),
///   - `.timeSensitive`, so it cuts through Focus / Do Not Disturb.
/// It can't beat the ring/silent switch — only a Critical Alert can, and that needs
/// an entitlement Apple grants by application (see docs/iOS-App.md).
@MainActor
final class MeetingAlarms: ObservableObject {
    static let shared = MeetingAlarms()

    /// Master toggle — default off, this is opt-in.
    static let enabledKey = "inbox2_meeting_alarm"
    /// Minutes before the meeting start (default 5).
    static let leadKey = "inbox2_meeting_alarm_lead"
    private static let mutedKey = "inbox2_meeting_alarm_muted"

    /// Notification-identifier prefix. Everything we own starts with it, and
    /// nothing else does — that's what makes reconcile safe to run destructively.
    private static let idPrefix = "meeting-alarm:"
    private static let soundFile = "meeting-alarm.caf"

    /// iOS keeps at most 64 pending local notifications per app and silently drops
    /// the rest, so we only ever hold the nearest few dozen meetings; reconcile
    /// refills the tail on every foreground/sync.
    // ponytail: fixed window — raise it only if someone books 32 meetings ahead and complains.
    private static let maxScheduled = 32

    /// Rescan floor. `dataVersion` bumps on every mark-read too, so an unthrottled
    /// reconcile would re-diff the calendar on each one.
    private static let minInterval: TimeInterval = 30

    /// Meetings the user silenced individually ("Cancel alarm" on the event sheet) —
    /// e.g. it was called off but is still on the calendar. Device-local: the event
    /// row itself belongs to the provider and gets overwritten on the next sync.
    @Published private(set) var muted: Set<String> = []

    private var lastReconcile: Date?

    private init() {
        muted = Set(UserDefaults.standard.stringArray(forKey: Self.mutedKey) ?? [])
    }

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    var leadMinutes: Int {
        let stored = UserDefaults.standard.integer(forKey: Self.leadKey)
        return stored > 0 ? stored : 5
    }

    func isMuted(_ eventKey: String) -> Bool { muted.contains(eventKey) }

    // MARK: - Mutating one meeting

    /// Silence or re-arm a single meeting's alarm, then re-sync the schedule.
    func setMuted(_ on: Bool, eventKey: String, engine: EngineModel) {
        if on { muted.insert(eventKey) } else { muted.remove(eventKey) }
        UserDefaults.standard.set(Array(muted), forKey: Self.mutedKey)
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.idPrefix + eventKey])
        Task { await reconcile(engine: engine, force: true) }
    }

    // MARK: - Reconcile

    /// Bring the pending alarms in line with the calendar: arm what's missing, drop
    /// what's cancelled, moved, muted, or past. Cheap enough to call freely — it
    /// throttles itself unless `force`.
    func reconcile(store: InboxStore, myEmails: Set<String>, force: Bool = false) async {
        guard enabled else { await cancelAll(); return }
        if !force, let last = lastReconcile, Date().timeIntervalSince(last) < Self.minInterval { return }
        lastReconcile = Date()

        // Same read the agenda uses — already excludes status='cancelled'.
        let from = isoLocalInternet.string(from: Calendar.current.startOfDay(for: Date()))
        let events = await store.read { $0.upcomingEvents(fromISO: from) }

        // Drop mutes for meetings that have fallen out of the window, so the set
        // can't grow forever.
        let live = Set(events.map(\.id))
        if muted.contains(where: { !live.contains($0) }) {
            muted = muted.intersection(live)
            UserDefaults.standard.set(Array(muted), forKey: Self.mutedKey)
        }

        let wanted = desired(from: events, myEmails: myEmails)
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(Self.idPrefix) }

        // Stale = no longer wanted, or the meeting moved (compare the trigger's own
        // fire date, so a rescheduled meeting is re-armed rather than left behind).
        let stale = pending.filter { req in
            guard let want = wanted[req.identifier],
                  let fires = (req.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
            else { return true }
            // Its text changed too (a renamed meeting, the local start time after travel): re-arm it.
            return abs(fires.timeIntervalSince(want.fireAt)) > 1 || req.content.body != want.body || req.content.title != want.title
        }.map(\.identifier)
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }

        let kept = Set(pending.map(\.identifier)).subtracting(stale)
        var added = 0
        for (id, alarm) in wanted where !kept.contains(id) {
            do { try await center.add(request(id: id, alarm: alarm)); added += 1 }
            catch { Log.engine.error("meeting alarm add failed: \(String(describing: error), privacy: .public)") }
        }
        Log.engine.info("meeting alarms: \(wanted.count) armed (+\(added) / -\(stale.count))")
    }

    /// Same, resolving the store + "my" addresses (for the declined check) off the
    /// engine — what every app-level call site has to hand.
    func reconcile(engine: EngineModel, force: Bool = false) async {
        await reconcile(store: engine.store,
                        myEmails: Set(engine.accounts.map { $0.email.lowercased() }),
                        force: force)
    }

    /// Fire one alarm a few seconds from now, exactly as a real one would sound.
    /// The point of this feature is that it goes off when it has to — without a test
    /// you only find out it doesn't by missing a meeting.
    func fireTest() async {
        await refreshSystemStatus()
        let content = alarmContent(
            title: "Test alarm",
            body: "This is how a meeting alarm sounds.",
            eventKey: "")
        let req = UNNotificationRequest(
            identifier: Self.idPrefix + "test", content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false))
        do { try await UNUserNotificationCenter.current().add(req) }
        catch { Log.engine.error("test alarm failed: \(String(describing: error), privacy: .public)") }
    }

    /// What iOS will actually let through, in words — the answer to "the banner
    /// showed but it was silent". Sounds off or Time Sensitive denied are both
    /// invisible from inside the app, and silently defeat the whole feature.
    @Published private(set) var systemStatus: String?

    func refreshSystemStatus() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        Log.engine.info("""
            meeting alarm settings: auth=\(s.authorizationStatus.rawValue) \
            sound=\(s.soundSetting.rawValue) alert=\(s.alertSetting.rawValue) \
            timeSensitive=\(s.timeSensitiveSetting.rawValue) critical=\(s.criticalAlertSetting.rawValue)
            """)

        var blocked: [String] = []
        if s.authorizationStatus != .authorized { blocked.append("notifications are off") }
        if s.soundSetting == .disabled { blocked.append("sounds are off") }
        if s.timeSensitiveSetting == .disabled { blocked.append("Time Sensitive is off") }
        // Only speak up when something is actually wrong — a permanent "all good"
        // line is noise on a settings screen.
        systemStatus = blocked.isEmpty ? nil
            : "The alarm can't sound: \(blocked.joined(separator: ", ")). Fix it in iOS Settings › Notifications › Inbox2."
    }

    /// Forget every alarm we scheduled (master toggle off, or notifications denied).
    func cancelAll() async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.pendingNotificationRequests()
            .map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        Log.engine.info("meeting alarms: cleared \(ids.count)")
    }

    // MARK: - What to schedule

    /// The alarms that *should* exist right now, keyed by notification identifier.
    /// The selection rules live in `MeetingAlarmPlan` (pure, tested).
    private func desired(from events: [CalendarEvent], myEmails: Set<String>) -> [String: MeetingAlarm] {
        let planned = MeetingAlarmPlan.alarms(
            for: events, leadMinutes: leadMinutes, now: Date(),
            muted: muted, myEmails: myEmails, limit: Self.maxScheduled)
        return Dictionary(uniqueKeysWithValues: planned.map { (Self.idPrefix + $0.eventKey, $0) })
    }

    private func alarmContent(title: String, body: String, eventKey: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound(named: UNNotificationSoundName(Self.soundFile))
        // Cuts through Focus / Do Not Disturb. Needs the time-sensitive entitlement
        // (declared in project.yml) — without it iOS silently downgrades to .active.
        content.interruptionLevel = .timeSensitive
        if !eventKey.isEmpty { content.userInfo = ["calendarEventKey": eventKey] }
        content.threadIdentifier = "meeting-alarms"
        return content
    }

    private func request(id: String, alarm: MeetingAlarm) -> UNNotificationRequest {
        let content = alarmContent(title: alarm.title, body: alarm.body, eventKey: alarm.eventKey)

        // Absolute wall-clock trigger: it survives the app being killed, and its own
        // nextTriggerDate is what reconcile diffs a moved meeting against.
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: alarm.fireAt)
        return UNNotificationRequest(
            identifier: id, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
    }
}
