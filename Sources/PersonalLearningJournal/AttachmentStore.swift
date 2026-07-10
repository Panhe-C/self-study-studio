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
}
