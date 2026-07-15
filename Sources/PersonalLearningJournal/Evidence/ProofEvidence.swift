import Foundation

public enum ProofIntegrity: String, Codable, CaseIterable, Sendable {
    case qualifying
    case needsEvidence
    case changedLink
    case brokenLink
}

public enum ProofArtifact: Codable, Equatable, Sendable {
    case attachment(localPath: String, mimeType: String?, fileSize: Int?)
    case link(
        url: URL,
        title: String?,
        site: String?,
        retrievedAt: Date?,
        fingerprint: String?,
        snapshotPath: String?
    )
    case text(markdown: String)

    public var qualifies: Bool {
        switch self {
        case let .attachment(localPath, _, _):
            !localPath.trimmedForJournal.isEmpty
        case let .link(url, _, _, _, _, _):
            Self.isValidWebURL(url)
        case let .text(markdown):
            !markdown.trimmedForJournal.isEmpty
        }
    }

    static func infer(
        type: ProofType,
        localPath: String?,
        url: URL?,
        mimeType: String?,
        fileSize: Int?
    ) -> ProofArtifact? {
        switch type {
        case .image, .audio, .file:
            guard let localPath, !localPath.trimmedForJournal.isEmpty else { return nil }
            return .attachment(localPath: localPath, mimeType: mimeType, fileSize: fileSize)
        case .link:
            guard let url, isValidWebURL(url) else { return nil }
            return .link(
                url: url,
                title: nil,
                site: url.host,
                retrievedAt: nil,
                fingerprint: nil,
                snapshotPath: nil
            )
        case .text:
            return nil
        }
    }

    public static func isValidWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return false
        }
        return true
    }
}
