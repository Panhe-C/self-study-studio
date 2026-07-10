import Foundation

public struct JournalExport: Codable, Equatable, Sendable {
    public var version: String
    public var exportedAt: Date
    public var projects: [Project]
    public var sessions: [LearningSession]
    public var proofs: [Proof]
    public var reviews: [Review]

    public init(
        version: String = "v0.1",
        exportedAt: Date = Date(),
        projects: [Project],
        sessions: [LearningSession],
        proofs: [Proof],
        reviews: [Review]
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.projects = projects
        self.sessions = sessions
        self.proofs = proofs
        self.reviews = reviews
    }
}

public struct JournalExportBundle: Equatable, Sendable {
    public var jsonURL: URL
    public var attachmentURLs: [URL]

    public init(jsonURL: URL, attachmentURLs: [URL]) {
        self.jsonURL = jsonURL
        self.attachmentURLs = attachmentURLs
    }
}

public struct ExportService {
    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public func exportJSON(snapshot: JournalSnapshot) throws -> Data {
        let export = JournalExport(
            exportedAt: now(),
            projects: snapshot.projects,
            sessions: snapshot.sessions,
            proofs: snapshot.proofs,
            reviews: snapshot.reviews
        )
        return try JSONEncoder.journal.encode(export)
    }

    public func exportBundle(
        snapshot: JournalSnapshot,
        to exportDirectory: URL
    ) throws -> JournalExportBundle {
        try FileManager.default.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: true
        )

        let jsonURL = exportDirectory.appendingPathComponent("journal.json")
        let jsonData = try exportJSON(snapshot: snapshot)
        try jsonData.write(to: jsonURL, options: [.atomic])

        let attachmentURLs = try exportAttachments(
            snapshot: snapshot,
            to: exportDirectory
        )

        return JournalExportBundle(
            jsonURL: jsonURL,
            attachmentURLs: attachmentURLs
        )
    }

    public func attachmentExportPath(for proof: Proof) -> String {
        let sessionComponent = proof.sessionId?.uuidString ?? "project"
        let fileExtension = proof.localPath
            .map { URL(fileURLWithPath: $0).pathExtension }
            .flatMap { $0.isEmpty ? nil : $0 }
        let fileName = fileExtension.map { "\(proof.id.uuidString).\($0)" } ?? proof.id.uuidString

        return [
            "Attachments",
            proof.projectId.uuidString,
            sessionComponent,
            fileName
        ].joined(separator: "/")
    }

    public func exportAttachments(
        snapshot: JournalSnapshot,
        to exportDirectory: URL
    ) throws -> [URL] {
        var copiedFiles: [URL] = []

        for proof in snapshot.proofs {
            guard let localPath = proof.localPath else { continue }
            let sourceURL = URL(fileURLWithPath: localPath)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }

            let relativePath = attachmentExportPath(for: proof)
            let destinationURL = exportDirectory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            copiedFiles.append(destinationURL)
        }

        return copiedFiles
    }
}

public extension JSONEncoder {
    static var journal: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public extension JSONDecoder {
    static var journal: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
