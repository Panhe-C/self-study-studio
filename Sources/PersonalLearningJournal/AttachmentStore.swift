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
}

public struct AttachmentCleanupEntry: Codable, Equatable, Sendable {
    public var projectID: UUID
    public var paths: [String]

    public init(projectID: UUID, paths: [String]) {
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

    public init(fileURL: URL) {
        self.fileURL = fileURL
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
        do {
            return try JSONDecoder().decode([AttachmentCleanupEntry].self, from: Data(contentsOf: fileURL))
        } catch {
            throw AttachmentCleanupQueueError.invalidQueue
        }
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

    private func write(_ entries: [AttachmentCleanupEntry]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sorted = entries.sorted { $0.projectID.uuidString < $1.projectID.uuidString }
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
