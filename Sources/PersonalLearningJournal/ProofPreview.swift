import Foundation

public enum ProofPreviewKind: Equatable, Sendable {
    case image(URL)
    case audio(URL)
    case file(URL)
    case link(URL)
    case text(String)
    case unavailable
}

public struct ProofPreviewDescriptor: Equatable, Sendable {
    public let kind: ProofPreviewKind

    public init(proof: Proof) {
        switch proof.type {
        case .image:
            kind = Self.localKind(for: proof.localPath, as: .image)
        case .audio:
            kind = Self.localKind(for: proof.localPath, as: .audio)
        case .file:
            kind = Self.localKind(for: proof.localPath, as: .file)
        case .link:
            kind = proof.url.map(ProofPreviewKind.link) ?? .unavailable
        case .text:
            kind = proof.artifactBody.map(ProofPreviewKind.text) ?? .unavailable
        }
    }

    private static func localKind(
        for localPath: String?,
        as type: ProofType
    ) -> ProofPreviewKind {
        guard let localPath, !localPath.isEmpty else { return .unavailable }
        let url = URL(fileURLWithPath: localPath)
        return switch type {
        case .image: .image(url)
        case .audio: .audio(url)
        case .file: .file(url)
        case .link: .unavailable
        case .text: .unavailable
        }
    }
}
