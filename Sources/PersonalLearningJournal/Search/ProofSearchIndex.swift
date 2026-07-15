import Foundation

public struct ProofSearchDocument: Equatable, Identifiable, Sendable {
    public var proof: Proof
    public var projectName: String
    public var locallyDerivedText: String

    public var id: UUID { proof.id }

    fileprivate var searchableText: String {
        [proof.title, proof.statement, projectName, proof.artifactBody ?? "", locallyDerivedText]
            .joined(separator: "\n")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

public struct ProofSearchIndex: Sendable {
    private var documents: [ProofSearchDocument]

    public init(
        snapshot: JournalSnapshot,
        locallyDerivedText: [UUID: String] = [:]
    ) {
        documents = Self.makeDocuments(
            snapshot: snapshot,
            locallyDerivedText: locallyDerivedText
        )
    }

    public func search(_ query: String) -> [ProofSearchDocument] {
        let normalized = query.trimmedForJournal.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return documents
            .filter { normalized.isEmpty || $0.searchableText.localizedStandardContains(normalized) }
            .sorted {
                if $0.proof.createdAt != $1.proof.createdAt {
                    return $0.proof.createdAt > $1.proof.createdAt
                }
                return $0.proof.id.uuidString < $1.proof.id.uuidString
            }
    }

    public mutating func rebuild(
        snapshot: JournalSnapshot,
        locallyDerivedText: [UUID: String] = [:]
    ) {
        documents = Self.makeDocuments(
            snapshot: snapshot,
            locallyDerivedText: locallyDerivedText
        )
    }

    private static func makeDocuments(
        snapshot: JournalSnapshot,
        locallyDerivedText: [UUID: String]
    ) -> [ProofSearchDocument] {
        let projectNames = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0.name) })
        return snapshot.proofs.compactMap { proof in
            guard proof.deletedAt == nil, proof.qualifies else { return nil }
            return ProofSearchDocument(
                proof: proof,
                projectName: projectNames[proof.projectId] ?? "Unknown Project",
                locallyDerivedText: locallyDerivedText[proof.id] ?? ""
            )
        }
    }
}
