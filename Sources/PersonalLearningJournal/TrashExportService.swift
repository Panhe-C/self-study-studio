import Foundation

public struct TrashExportDocument: Equatable, Identifiable, Sendable {
    public let url: URL
    public let attachmentCount: Int

    public var id: URL { url }

    public init(url: URL, attachmentCount: Int) {
        self.url = url
        self.attachmentCount = attachmentCount
    }
}

/// Creates one shareable archive before a Trash item is permanently deleted.
/// The public `prepare` seam is intentionally injectable by tests and by UI flows
/// that need to choose a different export directory.
public struct TrashExportService {
    private let archiveService: JournalArchiveService

    public init(archiveService: JournalArchiveService = JournalArchiveService()) {
        self.archiveService = archiveService
    }

    public func prepare(
        snapshot: JournalSnapshot,
        project: Project,
        to directory: URL
    ) throws -> TrashExportDocument {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        var attachments: [String: Data] = [:]
        for proof in snapshot.proofs {
            guard let localPath = proof.localPath else { continue }
            let sourceURL = URL(fileURLWithPath: localPath)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }
            let path = ExportService().attachmentExportPath(for: proof)
            attachments[path] = try Data(contentsOf: sourceURL)
        }

        let envelope = try archiveService.export(
            snapshot: snapshot,
            attachments: attachments,
            password: nil,
            allowUnencrypted: true
        )
        let stamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "trash-" + project.id.uuidString + "-" + stamp + ".learningjournal"
        let url = directory.appendingPathComponent(filename)
        let data = try JSONEncoder.journal.encode(envelope)
        try data.write(to: url, options: [.atomic])
        return TrashExportDocument(url: url, attachmentCount: attachments.count)
    }
}
