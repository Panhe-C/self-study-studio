import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Deep link carried by pending-capture notifications
/// (`selfstudystudio://pending-capture/<uuid>`, spec 13). Opening it resumes
/// the capture at its own step instead of a generic Today screen; a capture
/// that was confirmed or deleted in the meantime resolves to `nil`, which
/// callers treat as "stay on Today".
public enum PendingCaptureDeepLink {
    public static let scheme = "selfstudystudio"
    public static let host = "pending-capture"

    public static func url(for captureID: UUID) -> URL {
        URL(string: "\(scheme)://\(host)/\(captureID.uuidString)")!
    }

    public static func parse(_ url: URL) -> UUID? {
        guard url.scheme == scheme, url.host == host else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return UUID(uuidString: path)
    }

    /// The capture to reopen for a deep link, or `nil` when it no longer
    /// waits on the user (unknown, discarded, or confirmed/removed).
    public static func resolve(
        _ captureID: UUID,
        in store: PendingStudyCaptureStore
    ) -> PendingStudyCapture? {
        try? store.pendingConfirmations().first { $0.id == captureID }
    }
}

/// Thin seam over `UNUserNotificationCenter` so scheduling stays testable
/// without a real notification center (SwiftPM macOS tests have none).
public protocol NotificationScheduling: Sendable {
    func requestAuthorization() async -> Bool
    func schedule(id: String, payload: LearningNotificationPayload, date: Date) async throws
    func cancel(ids: [String]) async
    func pendingIDs() async -> Set<String>
}

#if canImport(UserNotifications)
/// Production scheduler backed by the user's notification center. The deep
/// link travels in `userInfo` so a tapped notification can reopen the exact
/// pending capture; user data (project names, record content) never enters
/// the payload (spec 15).
public struct UserNotificationCenterScheduler: @unchecked Sendable, NotificationScheduling {
    public static let deepLinkUserInfoKey = "deepLinkURL"

    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func schedule(id: String, payload: LearningNotificationPayload, date: Date) async throws {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.sound = .default
        if let captureID = PendingCaptureNotificationCoordinator.captureID(fromNotificationID: id) {
            content.userInfo[Self.deepLinkUserInfoKey] =
                PendingCaptureDeepLink.url(for: captureID).absoluteString
        }
        let interval = max(1, date.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    public func cancel(ids: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    public func pendingIDs() async -> Set<String> {
        let requests = await center.pendingNotificationRequests()
        return Set(requests.map(\.identifier))
    }
}
#endif

/// Scheduler used where no notification center exists (macOS SwiftPM tests
/// constructing the app session). Denies authorization and schedules nothing.
public struct NullNotificationScheduler: NotificationScheduling {
    public init() {}
    public func requestAuthorization() async -> Bool { false }
    public func schedule(id: String, payload: LearningNotificationPayload, date: Date) async throws {}
    public func cancel(ids: [String]) async {}
    public func pendingIDs() async -> Set<String> { [] }
}

/// Keeps exactly one reminder per pending study capture (spec 13).
///
/// Rules:
/// - Only captures that really started — the timer ran
///   (`activeDurationSeconds > 0`) or explicitly ended (`endedAt != nil`) —
///   and are still waiting on the user (`awaitingCheck`,
///   `awaitingRecordConfirmation`, `savedForLater`) ever schedule a
///   notification. Unstarted activities are never nudged.
/// - Category mapping: `awaitingCheck` → `pendingCompletionCheck`;
///   `awaitingRecordConfirmation`, and `savedForLater` with a record draft,
///   → `pendingRecordConfirmation`; `savedForLater` without a draft →
///   `pendingCompletionCheck`.
/// - `refresh(from:)` reconciles desired reminders with the system: stale
///   ones (confirmed, discarded, removed) are cancelled, missing or
///   category-changed ones are (re)scheduled. Confirm/discard therefore
///   cancels simply by refreshing.
/// - Permission denial is silent: nothing schedules, nothing throws, and the
///   store is never touched, so the local recovery card is unaffected.
@MainActor
public final class PendingCaptureNotificationCoordinator {
    public static nonisolated let notificationIDPrefix = "pending-capture."
    /// How long after the refresh a pending capture reminds the user.
    public static nonisolated let reminderDelay: TimeInterval = 60 * 60

    private let scheduler: any NotificationScheduling
    private let policy: LearningNotificationPolicy
    private let now: () -> Date
    private var didRequestAuthorization = false
    /// Category last scheduled per notification id, so a capture that moved
    /// from check to record confirmation gets its reminder re-scheduled with
    /// the updated copy instead of firing stale wording.
    private var scheduledCategories: [String: LearningNotificationCategory] = [:]

    public init(
        scheduler: any NotificationScheduling,
        policy: LearningNotificationPolicy = LearningNotificationPolicy(),
        now: @escaping () -> Date = Date.init
    ) {
        self.scheduler = scheduler
        self.policy = policy
        self.now = now
    }

    public nonisolated static func notificationID(for captureID: UUID) -> String {
        "\(notificationIDPrefix)\(captureID.uuidString)"
    }

    public nonisolated static func captureID(fromNotificationID id: String) -> UUID? {
        guard id.hasPrefix(notificationIDPrefix) else { return nil }
        return UUID(uuidString: String(id.dropFirst(notificationIDPrefix.count)))
    }

    /// "确实开始过": the timer actually ran or the session explicitly ended.
    public nonisolated static func isNotifiable(_ capture: PendingStudyCapture) -> Bool {
        guard category(for: capture) != nil else { return false }
        return capture.activeDurationSeconds > 0 || capture.endedAt != nil
    }

    public nonisolated static func category(for capture: PendingStudyCapture) -> LearningNotificationCategory? {
        switch capture.stage {
        case .awaitingCheck:
            return .pendingCompletionCheck
        case .awaitingRecordConfirmation:
            return .pendingRecordConfirmation
        case .savedForLater:
            return capture.recordDraft != nil ? .pendingRecordConfirmation : .pendingCompletionCheck
        case .active, .paused, .recovered, .confirmed, .discarded:
            return nil
        }
    }

    /// Reconciles scheduled reminders with the store. Authorization is
    /// requested lazily — only when there is something to schedule.
    public func refresh(from store: PendingStudyCaptureStore) async {
        let captures = (try? store.allCaptures()) ?? []
        var desired: [String: LearningNotificationCategory] = [:]
        for capture in captures where Self.isNotifiable(capture) {
            if let category = Self.category(for: capture) {
                desired[Self.notificationID(for: capture.id)] = category
            }
        }

        let managed = await scheduler.pendingIDs().filter { $0.hasPrefix(Self.notificationIDPrefix) }
        var toCancel: [String] = []
        var toSchedule: [String: LearningNotificationCategory] = [:]
        for id in managed {
            guard let category = desired[id] else {
                toCancel.append(id)
                scheduledCategories[id] = nil
                continue
            }
            if let known = scheduledCategories[id], known != category {
                toCancel.append(id)
                toSchedule[id] = category
            }
        }
        for (id, category) in desired where !managed.contains(id) {
            toSchedule[id] = category
        }
        if !toCancel.isEmpty {
            await scheduler.cancel(ids: toCancel)
        }

        guard !toSchedule.isEmpty, await ensureAuthorization() else { return }
        let date = now().addingTimeInterval(Self.reminderDelay)
        for (id, category) in toSchedule {
            // Best-effort: a failed schedule (e.g. denied permission) must
            // never surface or disturb capture state.
            try? await scheduler.schedule(
                id: id,
                payload: policy.payload(for: category),
                date: date
            )
            scheduledCategories[id] = category
        }
    }

    private func ensureAuthorization() async -> Bool {
        if didRequestAuthorization { return true }
        didRequestAuthorization = true
        return await scheduler.requestAuthorization()
    }
}

#if canImport(UserNotifications) && canImport(UIKit)
/// Routes notification taps into the same deep-link handling as `onOpenURL`.
/// Dismissing a notification never reaches this path and changes nothing.
public final class PendingCaptureNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let openURL: @MainActor @Sendable (URL) -> Void

    public init(openURL: @escaping @MainActor @Sendable (URL) -> Void) {
        self.openURL = openURL
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.identifier == PracticeTimerAlertCoordinator.notificationID {
            // The active app supplies its own immediate sound + haptic. Keep
            // the notification banner without playing the sound twice.
            completionHandler([.banner])
        } else {
            completionHandler([.banner, .sound])
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let raw = response.notification.request.content.userInfo[
            UserNotificationCenterScheduler.deepLinkUserInfoKey
        ] as? String, let url = URL(string: raw) {
            let openURL = self.openURL
            Task { @MainActor in openURL(url) }
        }
        completionHandler()
    }
}
#endif
