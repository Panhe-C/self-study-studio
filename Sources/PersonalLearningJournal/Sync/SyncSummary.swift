import Foundation

public struct SyncSummary: Equatable, Sendable {
    public var title: String
    public var detail: String

    public static let localOnly = SyncSummary(title: "Local Only", detail: "Stored on this device")

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    public init(status: SyncStatus, conflictCount: Int? = nil) {
        switch status {
        case .idle:
            self.init(title: "Local Only", detail: "Waiting for iCloud")
        case let .syncing(pending):
            self.init(title: "Syncing", detail: "\(pending) changes waiting")
        case .synced:
            self.init(title: "Synced", detail: "Up to date")
        case let .failed(pending, conflicts, _):
            let visibleConflictCount = conflictCount ?? conflicts
            self.init(
                title: "Needs Attention",
                detail: "\(pending) changes waiting, \(visibleConflictCount) conflict\(visibleConflictCount == 1 ? "" : "s")"
            )
        }
    }
}
