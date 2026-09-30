import Foundation

/// File-backed store for unconfirmed study captures (spec 3.4, 15).
///
/// Persists every capture to a single JSON file (`pending-study-captures.json`)
/// under the app's Application Support directory. Writes are atomic: data is
/// written to a temporary file and renamed over the target (`Data.write`
/// `.atomic`), so a crash mid-write never leaves a truncated store.
///
/// Isolation: this store is device-local only. Captures never enter
/// `JournalSnapshot`, never export, and never enter the CloudKit outbox.
///
/// Timer-tick policy: callers hold the running elapsed value and call
/// `noteElapsed(id:activeDurationSeconds:)` per tick — that updates memory
/// only and never touches the disk. Key state changes (`begin`, `pause`,
/// `resume`, `end`, drafts, answers, save/discard), `checkpoint`, and
/// `persist()` are the only operations that write to disk.
///
/// Crash recovery: a capture found in `active`/`paused` when the file is
/// loaded means the app died mid-timer. Loading marks it `recovered`
/// (persisted once) so accumulated seconds survive and the timer slot stays
/// occupied until the user resumes, ends, saves, or discards it.
public final class PendingStudyCaptureStore {
    public static let defaultFileName = "pending-study-captures.json"

    private let fileURL: URL
    private let now: () -> Date
    /// The default writer uses `Data.write(..., .atomic)`. Keeping the writer
    /// injectable gives persistence tests a deterministic way to exercise a
    /// failed replace without relying on filesystem permissions.
    private let writeData: (Data, URL) throws -> Void
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// In-memory source of truth; `nil` until first loaded from disk.
    private var captures: [PendingStudyCapture]?

    public init(
        directory: URL,
        fileName: String = PendingStudyCaptureStore.defaultFileName,
        now: @escaping () -> Date = Date.init,
        writeData: @escaping (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: [.atomic])
        }
    ) {
        self.fileURL = directory.appendingPathComponent(fileName)
        self.now = now
        self.writeData = writeData
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    /// Default store rooted in this app's Application Support subdirectory.
    public convenience init(now: @escaping () -> Date = Date.init) {
        self.init(directory: Self.defaultDirectory(), now: now)
    }

    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("SelfStudyStudio", isDirectory: true)
    }

    // MARK: - Reads

    public func load() throws -> [PendingStudyCapture] {
        try ensureLoaded()
    }

    public func allCaptures() throws -> [PendingStudyCapture] {
        try ensureLoaded()
    }

    /// The capture holding the single timer slot, if any. `recovered` keeps
    /// the slot occupied: a new capture cannot begin until it is resolved.
    public func activeCapture() throws -> PendingStudyCapture? {
        try ensureLoaded().first { Self.occupiesTimerSlot($0.stage) }
    }

    /// Captures waiting on user confirmation, including ones saved for later.
    public func pendingConfirmations() throws -> [PendingStudyCapture] {
        try ensureLoaded().filter {
            $0.stage == .awaitingCheck
                || $0.stage == .awaitingRecordConfirmation
                || $0.stage == .savedForLater
        }
    }

    // MARK: - Lifecycle transitions

    @discardableResult
    public func begin(
        id: UUID = UUID(),
        projectID: UUID,
        plannedSessionID: UUID? = nil,
        source: SessionSource
    ) throws -> PendingStudyCapture {
        if let existing = try activeCapture() {
            throw PendingStudyCaptureError.activeCaptureAlreadyExists(existing.id)
        }
        let capture = PendingStudyCapture(
            id: id,
            projectID: projectID,
            plannedSessionID: plannedSessionID,
            source: source,
            stage: .active,
            startedAt: now(),
            lastResumedAt: now(),
            updatedAt: now()
        )
        var all = try ensureLoaded()
        all.append(capture)
        try persistSnapshot(all)
        captures = all
        return capture
    }

    @discardableResult
    public func pause(id: UUID) throws -> PendingStudyCapture {
        try transition(id: id, to: .paused, from: [.active])
    }

    @discardableResult
    public func resume(id: UUID) throws -> PendingStudyCapture {
        try transition(id: id, to: .active, from: [.paused, .recovered]) { capture in
            capture.lastResumedAt = self.now()
        }
    }

    /// Ends the timer: freezes accumulated seconds and moves to the
    /// completion check. Allowed from any timer-slot stage, including
    /// `recovered` (a crashed timer the user chooses to finish).
    @discardableResult
    public func end(id: UUID, at endDate: Date? = nil) throws -> PendingStudyCapture {
        try transition(id: id, to: .awaitingCheck, from: [.active, .paused, .recovered]) { capture in
            capture.endedAt = endDate ?? self.now()
        }
    }

    @discardableResult
    public func attachCheckDraft(
        id: UUID,
        draft: CompletionCheckDraft
    ) throws -> PendingStudyCapture {
        try transition(id: id, to: .awaitingCheck, from: [.awaitingCheck]) { capture in
            capture.checkDraft = draft
        }
    }

    /// Records (or revises) the user's answers. Allowed while checking and
    /// while reviewing the record draft, since answers feed that draft.
    @discardableResult
    public func recordAnswers(
        id: UUID,
        answers: CompletionCheckAnswers
    ) throws -> PendingStudyCapture {
        try transition(
            id: id,
            to: nil,
            from: [.awaitingCheck, .awaitingRecordConfirmation]
        ) { capture in
            capture.answers = answers
        }
    }

    /// Attaches the generated record draft, or persists the user's edits to
    /// an already-attached draft. Either way the capture stays (or lands) in
    /// `awaitingRecordConfirmation`; nothing confirms automatically.
    @discardableResult
    public func attachRecordDraft(
        id: UUID,
        draft: LearningRecordDraft
    ) throws -> PendingStudyCapture {
        try transition(
            id: id,
            to: .awaitingRecordConfirmation,
            from: [.awaitingCheck, .awaitingRecordConfirmation]
        ) { capture in
            capture.recordDraft = draft
        }
    }

    @discardableResult
    public func stageAttachment(
        id: UUID,
        attachment: PendingAttachmentReference
    ) throws -> PendingStudyCapture {
        try transition(
            id: id,
            to: nil,
            from: [.awaitingCheck, .awaitingRecordConfirmation, .savedForLater]
        ) { capture in
            capture.stagedAttachments.append(attachment)
        }
    }

    @discardableResult
    public func saveForLater(id: UUID) throws -> PendingStudyCapture {
        try transition(
            id: id,
            to: .savedForLater,
            from: [.awaitingCheck, .awaitingRecordConfirmation]
        )
    }

    /// Reopens a saved-for-later capture so the user can finish it (spec 5.1:
    /// "结束学习但稍后确认"). Lands on `awaitingRecordConfirmation` when a
    /// record draft was already attached, otherwise back on `awaitingCheck`.
    @discardableResult
    public func reopen(id: UUID) throws -> PendingStudyCapture {
        var all = try ensureLoaded()
        guard let index = all.firstIndex(where: { $0.id == id }) else {
            throw PendingStudyCaptureError.captureNotFound(id)
        }
        let target: PendingStudyCaptureStage =
            all[index].recordDraft != nil ? .awaitingRecordConfirmation : .awaitingCheck
        guard all[index].stage == .savedForLater else {
            throw PendingStudyCaptureError.illegalTransition(
                from: all[index].stage,
                to: target
            )
        }
        all[index].stage = target
        all[index].updatedAt = now()
        try persistSnapshot(all)
        captures = all
        return all[index]
    }

    @discardableResult
    public func discard(id: UUID) throws -> PendingStudyCapture {
        try transition(
            id: id,
            to: .discarded,
            from: [.active, .paused, .recovered, .awaitingCheck, .awaitingRecordConfirmation, .savedForLater]
        )
    }

    /// Permanently deletes a capture. Called after the confirmation
    /// transaction succeeds (the capture became a journal fact).
    public func remove(id: UUID) throws {
        let all = try ensureLoaded()
        guard let index = all.firstIndex(where: { $0.id == id }) else {
            throw PendingStudyCaptureError.captureNotFound(id)
        }
        var candidate = all
        candidate.remove(at: index)
        try persistSnapshot(candidate)
        captures = candidate
    }

    // MARK: - Timer ticks and checkpoints

    /// Per-tick elapsed update. Memory only — never writes to disk.
    public func noteElapsed(id: UUID, activeDurationSeconds: Int) throws {
        var all = try ensureLoaded()
        guard let index = all.firstIndex(where: { $0.id == id }) else {
            throw PendingStudyCaptureError.captureNotFound(id)
        }
        all[index].activeDurationSeconds = activeDurationSeconds
        all[index].updatedAt = now()
        // Timer ticks are intentionally memory-only. The next lifecycle
        // checkpoint persists the accumulated value.
        captures = all
    }

    /// Lifecycle save point for a running timer (background/termination):
    /// persists accumulated active seconds alongside the last resume time.
    @discardableResult
    public func checkpoint(id: UUID, activeDurationSeconds: Int) throws -> PendingStudyCapture {
        try transition(id: id, to: nil, from: PendingStudyCaptureStage.allCases) { capture in
            capture.activeDurationSeconds = activeDurationSeconds
        }
    }

    /// Persists the current in-memory state of every capture.
    public func persist() throws {
        let all = try ensureLoaded()
        try persistSnapshot(all)
    }

    /// Writes a complete candidate snapshot before publishing it to memory.
    /// All state-changing operations use this seam so a failed write cannot
    /// leave the in-memory store ahead of the durable file.
    private func persistSnapshot(_ all: [PendingStudyCapture]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(all)
        try writeData(data, fileURL)
    }

    // MARK: - Internals

    private static func occupiesTimerSlot(_ stage: PendingStudyCaptureStage) -> Bool {
        stage == .active || stage == .paused || stage == .recovered
    }

    private func ensureLoaded() throws -> [PendingStudyCapture] {
        if let captures { return captures }
        var loaded: [PendingStudyCapture] = []
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            loaded = try decoder.decode([PendingStudyCapture].self, from: data)
        }
        // Crash recovery: a capture left in a timer-running stage means the
        // app died mid-timer. Mark it recovered so accumulated seconds
        // survive and the user can resume without a phantom running timer.
        var recoveredAny = false
        for index in loaded.indices where loaded[index].stage == .active || loaded[index].stage == .paused {
            loaded[index].stage = .recovered
            recoveredAny = true
        }
        if recoveredAny {
            // Publish the recovered snapshot only after the recovery marker
            // itself has been persisted. A failed recovery write leaves this
            // store unloaded, so a later retry can safely try again.
            try persistSnapshot(loaded)
        }
        captures = loaded
        return loaded
    }

    @discardableResult
    private func transition(
        id: UUID,
        to target: PendingStudyCaptureStage?,
        from allowed: [PendingStudyCaptureStage],
        mutate: ((inout PendingStudyCapture) -> Void)? = nil
    ) throws -> PendingStudyCapture {
        var all = try ensureLoaded()
        guard let index = all.firstIndex(where: { $0.id == id }) else {
            throw PendingStudyCaptureError.captureNotFound(id)
        }
        guard allowed.contains(all[index].stage) else {
            throw PendingStudyCaptureError.illegalTransition(
                from: all[index].stage,
                to: target ?? all[index].stage
            )
        }
        mutate?(&all[index])
        if let target { all[index].stage = target }
        all[index].updatedAt = now()
        try persistSnapshot(all)
        captures = all
        return all[index]
    }
}
