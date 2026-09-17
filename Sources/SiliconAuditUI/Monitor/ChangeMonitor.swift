import Foundation
import Observation
import SiliconAuditCore
#if canImport(UserNotifications) && !os(tvOS)
import UserNotifications
#endif
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif
#if os(watchOS)
import WatchKit
#endif

/// Remembers what the kernel reported and notices when it changes (SPEC §6.5). File-backed in
/// Application Support so the foreground app and a background refresh can share one baseline:
/// each check compares the fresh report with the stored baseline, records any difference, and
/// then makes the fresh report the new baseline. A different device (a restored backup) starts a
/// new baseline silently.
@MainActor
@Observable
public final class ChangeMonitor {
    public struct Record: Codable, Identifiable, Equatable, Sendable {
        public var id: String
        public var detectedAt: Date
        public var diff: ReportDiff
        public var seen: Bool

        enum CodingKeys: String, CodingKey {
            case id, diff, seen
            case detectedAt = "detected_at"
        }
    }

    /// Everything but the baseline report, in one small file.
    struct State: Codable {
        var baselineRecordedAt: Date?
        var lastCheckAt: Date?
        var records: [Record] = []

        enum CodingKeys: String, CodingKey {
            case records
            case baselineRecordedAt = "baseline_recorded_at"
            case lastCheckAt = "last_check_at"
        }
    }

    public enum Authorization: Equatable, Sendable {
        case notDetermined, denied, authorized, unavailable
    }

    public private(set) var baseline: Report?
    public private(set) var baselineRecordedAt: Date?
    public private(set) var lastCheckAt: Date?
    public private(set) var records: [Record] = []
    public private(set) var authorization: Authorization = .notDetermined

    /// The user's wish, kept in UserDefaults so it survives reinstalls of the baseline.
    public var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: ChangeMonitor.notifyKey) }
    }
    /// The in-app invitation to turn on notifications was answered or dismissed.
    public var promptDismissed: Bool {
        didSet { defaults.set(promptDismissed, forKey: ChangeMonitor.promptKey) }
    }

    public let directory: URL
    private let defaults: UserDefaults
    static let notifyKey = "monitor.notify"
    static let promptKey = "monitor.promptDismissed"
    /// Foreground checks are cheap but not free; one every 15 minutes is plenty.
    public static let foregroundInterval: TimeInterval = 15 * 60
    /// Background refresh asks for roughly this cadence; the system decides.
    public static let backgroundInterval: TimeInterval = 6 * 60 * 60
    public static let refreshTaskID = "org.unredacted.silicon-audit.refresh"
    /// Keep the history bounded; the newest records are the ones that matter.
    static let maxRecords = 50

    public static let defaultDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SiliconAudit/Monitor", isDirectory: true)
    }()

    public init(directory: URL = ChangeMonitor.defaultDirectory, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
        notificationsEnabled = defaults.bool(forKey: ChangeMonitor.notifyKey)
        promptDismissed = defaults.bool(forKey: ChangeMonitor.promptKey)
        load()
    }

    private var baselineURL: URL { directory.appendingPathComponent("baseline.json") }
    private var stateURL: URL { directory.appendingPathComponent("state.json") }

    public var unseenRecords: [Record] { records.filter { !$0.seen } }
    public var hasBaseline: Bool { baseline != nil }

    // MARK: - Persistence

    public func load() {
        baseline = (try? Data(contentsOf: baselineURL)).flatMap { try? Report.decode($0) }
        let state = (try? Data(contentsOf: stateURL)).flatMap { try? ChangeMonitor.decoder.decode(State.self, from: $0) } ?? State()
        baselineRecordedAt = state.baselineRecordedAt
        lastCheckAt = state.lastCheckAt
        records = state.records.sorted { $0.detectedAt > $1.detectedAt }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let baseline { try baseline.jsonData(pretty: false).write(to: baselineURL, options: .atomic) }
            let state = State(baselineRecordedAt: baselineRecordedAt, lastCheckAt: lastCheckAt, records: records)
            try ChangeMonitor.encoder.encode(state).write(to: stateURL, options: .atomic)
        } catch {
            // A failed save loses at most one check; the next one starts from the last good files.
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Checking

    /// Compares `report` with the baseline. The first report becomes the baseline; a report from
    /// another device replaces it. Returns the diff when something changed, nil otherwise, and in
    /// every case the report becomes the new baseline so the next check sees only new changes.
    @discardableResult
    public func process(_ report: Report, now: Date = Date()) -> ReportDiff? {
        lastCheckAt = now
        defer { save() }
        guard let baseline else {
            self.baseline = report
            baselineRecordedAt = now
            return nil
        }
        let diff = ReportDiff.compare(baseline: baseline, current: report)
        if diff.identityChanged {
            self.baseline = report
            baselineRecordedAt = now
            records = []
            return nil
        }
        guard !diff.isEmpty else { return nil }
        let record = Record(id: ChangeMonitor.recordID(now), detectedAt: now, diff: diff, seen: false)
        records.insert(record, at: 0)
        if records.count > ChangeMonitor.maxRecords { records.removeLast(records.count - ChangeMonitor.maxRecords) }
        self.baseline = report
        baselineRecordedAt = now
        return diff
    }

    static func recordID(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date) + "-" + UUID().uuidString.prefix(8)
    }

    /// Forgets the history and starts over from `report`.
    public func resetBaseline(_ report: Report, now: Date = Date()) {
        baseline = report
        baselineRecordedAt = now
        lastCheckAt = now
        records = []
        save()
    }

    public func markAllSeen() {
        guard records.contains(where: { !$0.seen }) else { return }
        records = records.map { var r = $0; r.seen = true; return r }
        save()
    }

    public func delete(_ record: Record) {
        records.removeAll { $0.id == record.id }
        save()
    }

    /// Whether a foreground check is due (app launch or return to the foreground).
    public func isCheckDue(now: Date = Date()) -> Bool {
        guard let lastCheckAt else { return true }
        return now.timeIntervalSince(lastCheckAt) >= ChangeMonitor.foregroundInterval
    }

    // MARK: - Notifications

    public func refreshAuthorization() async {
        #if canImport(UserNotifications) && !os(tvOS)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: authorization = .notDetermined
        case .denied: authorization = .denied
        case .authorized, .provisional, .ephemeral: authorization = .authorized
        @unknown default: authorization = .denied
        }
        #else
        authorization = .unavailable
        #endif
    }

    /// Asks the system once; the answer is remembered by the system, our wish by `notificationsEnabled`.
    @discardableResult
    public func requestNotifications() async -> Bool {
        promptDismissed = true
        #if canImport(UserNotifications) && !os(tvOS)
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        notificationsEnabled = granted
        await refreshAuthorization()
        return granted
        #else
        notificationsEnabled = false
        authorization = .unavailable
        return false
        #endif
    }

    /// Posts one notification for a detected change set, if the user asked for them.
    public func notify(_ diff: ReportDiff) async {
        #if canImport(UserNotifications) && !os(tvOS)
        guard notificationsEnabled else { return }
        await refreshAuthorization()
        guard authorization == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = ChangeCopy.notificationTitle(diff)
        content.body = ChangeCopy.notificationBody(diff)
        content.sound = diff.securityChanges.isEmpty ? nil : .default
        content.userInfo = ["route": "__changes__"]
        content.threadIdentifier = "silicon-audit-changes"
        let request = UNNotificationRequest(identifier: "change-\(diff.currentCollectedAt)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
        #endif
    }

    // MARK: - Background refresh

    /// Asks the system for a refresh later. Safe to call often; a pending request is replaced.
    /// macOS has no app-refresh task; there the running app checks on a timer instead
    /// (`periodicChecks`), which suits an app that stays open.
    public static func scheduleBackgroundRefresh() {
        #if os(watchOS)
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: Date().addingTimeInterval(backgroundInterval), userInfo: nil) { _ in }
        #elseif canImport(BackgroundTasks) && !os(macOS)
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date().addingTimeInterval(backgroundInterval)
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    /// A check every `backgroundInterval` while the app runs, for the platform with no system
    /// refresh. Runs until the calling task is cancelled.
    public func periodicChecks(model: ReportModel) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(ChangeMonitor.backgroundInterval))
            guard !Task.isCancelled else { return }
            await model.run()
            if let report = model.report { await processInForeground(report) }
        }
    }

    /// The whole background check: a fresh monitor over the shared files, a fresh audit, compare,
    /// notify, reschedule. Runs from the scene's `backgroundTask` handler.
    public static func performBackgroundCheck() async {
        let monitor = ChangeMonitor()
        let report = await Task.detached(priority: .utility) { Auditor().audit() }.value
        if let diff = monitor.process(report) {
            await monitor.notify(diff)
        }
        scheduleBackgroundRefresh()
    }

    /// The foreground check after a report loads: compare, notify (the in-app card shows too),
    /// and ask for the next background refresh.
    public func processInForeground(_ report: Report) async {
        if let diff = process(report) {
            await notify(diff)
        }
        ChangeMonitor.scheduleBackgroundRefresh()
    }
}
