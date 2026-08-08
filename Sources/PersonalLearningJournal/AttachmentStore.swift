import Foundation

public struct StoredAttachment: Equatable, Sendable {
    public var fileURL: URL
    public var fileSize: Int
    public var mimeType: String?

    public init(fileURL: URL, fileSize: Int, mimeType: String?) {
        self.fileURL = fileURL
        self.fileSize = fileSize
        self.mimeType = mimeType
    }
}

public enum AttachmentCleanupQueueError: Error, Equatable, Sendable {
    case invalidQueue
    case legacyQueueNeedsReview([String])
    case orphanCleanupRequiresConfirmation([String])
    case orphanCleanupFailed([String])
    case quarantineFailed
}

extension AttachmentCleanupQueueError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidQueue:
            return "The attachment cleanup queue is unreadable. Repair or remove the queue file before retrying."
        case let .legacyQueueNeedsReview(paths):
            return "The legacy attachment cleanup queue contains paths without a safely identifiable project: \(paths.joined(separator: ", "))."
        case let .orphanCleanupRequiresConfirmation(paths):
            return "These attachment paths need explicit confirmation before deletion: \(paths.joined(separator: ", "))."
        case let .orphanCleanupFailed(paths):
            return "Some confirmed orphan attachment paths could not be deleted: \(paths.joined(separator: ", "))."
        case .quarantineFailed:
            return "The corrupt attachment cleanup queue could not be quarantined; the original file remains blocked for safety."
        }
    }
}

public struct AttachmentCleanupEntry: Codable, Equatable, Sendable {
    public var projectID: UUID?
    public var paths: [String]

    public init(projectID: UUID?, paths: [String]) {
        self.projectID = projectID
        self.paths = paths
    }
}

public enum AttachmentStoreError: Error, Equatable, Sendable {
    case unsafePath(String)
}

/// A local-only retry queue for attachment file cleanup. Its contents are never
/// part of a JournalSnapshot or JournalTransaction, so absolute local paths cannot
/// enter CloudKit sync payloads.
public struct AttachmentCleanupQueue: Sendable {
    public let fileURL: URL
    private let moveItem: @Sendable (URL, URL) throws -> Void

    public init(
        fileURL: URL,
        moveItem: @escaping @Sendable (URL, URL) throws -> Void = { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        }
    ) {
        self.fileURL = fileURL
        self.moveItem = moveItem
    }

    public init(rootDirectory: URL) {
        self.init(
            fileURL: rootDirectory
                .appendingPathComponent("LearningJournal", isDirectory: true)
                .appendingPathComponent("Private", isDirectory: true)
                .appendingPathComponent("attachment-cleanup-queue.json")
        )
    }

    public func load() throws -> [AttachmentCleanupEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw AttachmentCleanupQueueError.invalidQueue
        }
        if let entries = try? JSONDecoder().decode([AttachmentCleanupEntry].self, from: data) {
            return entries
        }
        guard let legacyPaths = try? JSONDecoder().decode([String].self, from: data) else {
            throw AttachmentCleanupQueueError.invalidQueue
        }
        let legacyEntries = legacyPaths.compactMap(legacyEntry(for:))
        guard legacyEntries.count == legacyPaths.count else {
            throw AttachmentCleanupQueueError.legacyQueueNeedsReview(legacyPaths.filter { legacyEntry(for: $0) == nil })
        }
        let grouped = Dictionary(grouping: legacyEntries, by: \.projectID)
        let migrated = grouped
            .map { projectID, entries in
                AttachmentCleanupEntry(
                    projectID: projectID,
                    paths: Array(Set(entries.flatMap(\.paths))).sorted()
                )
            }
            .sorted { ($0.projectID?.uuidString ?? "") < ($1.projectID?.uuidString ?? "") }
        try write(migrated)
        return migrated
    }

    private func legacyEntry(for path: String) -> AttachmentCleanupEntry? {
        let rawComponents = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let componentsAfterRoot = path.hasPrefix("/") ? rawComponents.dropFirst() : rawComponents[...]
        guard !componentsAfterRoot.contains(".."), !componentsAfterRoot.contains("") else { return nil }
        let components = URL(fileURLWithPath: path).pathComponents
        guard let rootIndex = components.lastIndex(where: { $0 == "Attachments" || $0 == "ImportedAssets" }),
              rootIndex > 0,
              components[rootIndex - 1] == "LearningJournal",
              rootIndex + 1 < components.count else {
            return nil
        }
        if components[rootIndex] == "Attachments",
           let projectID = UUID(uuidString: components[rootIndex + 1]) {
            return AttachmentCleanupEntry(projectID: projectID, paths: [path])
        }
        return AttachmentCleanupEntry(projectID: nil, paths: [path])
    }

    public func enqueue(projectID: UUID, paths: [String]) throws {
        guard !paths.isEmpty else { return }
        var entries = try load()
        if let index = entries.firstIndex(where: { $0.projectID == projectID }) {
            entries[index].paths = Array(Set(entries[index].paths).union(paths)).sorted()
        } else {
            entries.append(AttachmentCleanupEntry(projectID: projectID, paths: paths.sorted()))
        }
        try write(entries)
    }

    public func remove(projectID: UUID, paths: [String]) throws {
        var entries = try load()
        guard let index = entries.firstIndex(where: { $0.projectID == projectID }) else { return }
        entries[index].paths = Array(Set(entries[index].paths).subtracting(paths)).sorted()
        if entries[index].paths.isEmpty {
            entries.remove(at: index)
        }
        if entries.isEmpty {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } else {
            try write(entries)
        }
    }

    public func removeOrphan(paths: [String]) throws {
        var entries = try load()
        let requested = Set(paths)
        entries = entries.compactMap { entry in
            guard entry.projectID == nil else { return entry }
            let remaining = entry.paths.filter { !requested.contains($0) }
            return remaining.isEmpty ? nil : AttachmentCleanupEntry(projectID: nil, paths: remaining)
        }
        if entries.isEmpty {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } else {
            try write(entries)
        }
    }

    public func quarantineCorruptQueue() throws -> URL {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AttachmentCleanupQueueError.invalidQueue
        }
        let quarantineDirectory = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("Quarantine", isDirectory: true)
        let stamp = String(Int(Date().timeIntervalSince1970))
        let quarantineURL = quarantineDirectory.appendingPathComponent(
            "\(fileURL.deletingPathExtension().lastPathComponent)-\(stamp)-\(UUID().uuidString).json"
        )
        do {
            try FileManager.default.createDirectory(
                at: quarantineDirectory,
                withIntermediateDirectories: true
            )
            try moveItem(fileURL, quarantineURL)
            return quarantineURL
        } catch {
            throw AttachmentCleanupQueueError.quarantineFailed
        }
    }

    private func write(_ entries: [AttachmentCleanupEntry]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sorted = entries.sorted { ($0.projectID?.uuidString ?? "") < ($1.projectID?.uuidString ?? "") }
        try JSONEncoder().encode(sorted).write(to: fileURL, options: [.atomic])
    }
}

public struct AttachmentStore: Sendable {
    public var rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public static func defaultStore() -> AttachmentStore {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return AttachmentStore(rootDirectory: documents)
    }

    public func saveData(
        _ data: Data,
        projectId: UUID,
        sessionId: UUID?,
        proofId: UUID,
        originalFileName: String,
        mimeType: String?
    ) throws -> StoredAttachment {
        let destinationURL = attachmentURL(
            projectId: projectId,
            sessionId: sessionId,
            proofId: proofId,
            originalFileName: originalFileName
        )
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destinationURL, options: [.atomic])
        return StoredAttachment(
            fileURL: destinationURL,
            fileSize: data.count,
            mimeType: mimeType
        )
    }

    public func copyFile(
        from sourceURL: URL,
        projectId: UUID,
        sessionId: UUID?,
        proofId: UUID,
        mimeType: String?
    ) throws -> StoredAttachment {
        let data = try Data(contentsOf: sourceURL)
        let destinationURL = attachmentURL(
            projectId: projectId,
            sessionId: sessionId,
            proofId: proofId,
            originalFileName: sourceURL.lastPathComponent
        )
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try data.write(to: destinationURL, options: [.atomic])
        return StoredAttachment(
            fileURL: destinationURL,
            fileSize: data.count,
            mimeType: mimeType
        )
    }

    public func importCloudAsset(
        at sourceURL: URL,
        proofId: UUID
    ) throws -> URL {
        let ext = sourceURL.pathExtension
        let filename = ext.isEmpty ? proofId.uuidString : "\(proofId.uuidString).\(ext)"
        let destination = rootDirectory
            .appendingPathComponent("LearningJournal", isDirectory: true)
            .appendingPathComponent("ImportedAssets", isDirectory: true)
            .appendingPathComponent(filename)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    public func removeAttachment(at url: URL) throws {
        try validateAttachmentTarget(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public static func removeAttachmentFile(at path: String) throws {
        try AttachmentStore.defaultStore().removeAttachment(at: URL(fileURLWithPath: path))
    }

    public func attachmentURL(
        projectId: UUID,
        sessionId: UUID?,
        proofId: UUID,
        originalFileName: String
    ) -> URL {
        let ext = URL(fileURLWithPath: originalFileName).pathExtension
        let fileName = ext.isEmpty ? proofId.uuidString : "\(proofId.uuidString).\(ext)"
        return rootDirectory
            .appendingPathComponent("LearningJournal", isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent(projectId.uuidString, isDirectory: true)
            .appendingPathComponent(sessionId?.uuidString ?? "project", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    private var attachmentRoots: [URL] {
        let learningJournal = rootDirectory
            .appendingPathComponent("LearningJournal", isDirectory: true)
        return [
            learningJournal.appendingPathComponent("Attachments", isDirectory: true),
            learningJournal.appendingPathComponent("ImportedAssets", isDirectory: true)
        ].map(\.standardizedFileURL)
    }

    private func validateAttachmentTarget(_ url: URL) throws {
        let target = url.standardizedFileURL
        guard let root = attachmentRoots.first(where: {
            target != $0 && isDescendant(target, of: $0)
        }) else {
            throw AttachmentStoreError.unsafePath(url.path)
        }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolvedTarget = target.resolvingSymlinksInPath().standardizedFileURL
        guard isDescendant(resolvedTarget, of: resolvedRoot),
              !containsSymlink(onPathTo: target, from: root) else {
            throw AttachmentStoreError.unsafePath(url.path)
        }
    }

    private func isDescendant(_ target: URL, of root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let targetComponents = target.pathComponents
        guard targetComponents.count > rootComponents.count else { return false }
        return Array(targetComponents.prefix(rootComponents.count)) == rootComponents
    }

    private func containsSymlink(onPathTo target: URL, from root: URL) -> Bool {
        let components = target.pathComponents.dropFirst(root.pathComponents.count)
        var current = root
        for component in components {
            current.appendPathComponent(component)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: current.path),
                  let type = attributes[.type] as? FileAttributeType else {
                continue
            }
            if type == .typeSymbolicLink { return true }
        }
        return false
    }
}
