import Foundation
import UniformTypeIdentifiers

public struct ProofAttachmentDraft: Equatable, Sendable {
    public var data: Data?
    public var fileURL: URL?
    public var fileName: String
    public var mimeType: String?
    public var proofType: ProofType
    public var suggestedTitle: String

    public init(
        data: Data?,
        fileURL: URL?,
        fileName: String,
        mimeType: String?,
        proofType: ProofType,
        suggestedTitle: String
    ) {
        self.data = data
        self.fileURL = fileURL
        self.fileName = fileName
        self.mimeType = mimeType
        self.proofType = proofType
        self.suggestedTitle = suggestedTitle
    }

    public static func capturedPhoto(
        _ data: Data,
        fileName: String = "camera-photo.jpg"
    ) -> ProofAttachmentDraft {
        ProofAttachmentDraft(
            data: data,
            fileURL: nil,
            fileName: fileName,
            mimeType: "image/jpeg",
            proofType: .image,
            suggestedTitle: "Photo Proof"
        )
    }

    public static func selectedPhoto(
        _ data: Data,
        contentType: UTType?
    ) -> ProofAttachmentDraft {
        let fileExtension = contentType?.preferredFilenameExtension ?? "jpg"
        return ProofAttachmentDraft(
            data: data,
            fileURL: nil,
            fileName: "photo.\(fileExtension)",
            mimeType: contentType?.preferredMIMEType,
            proofType: .image,
            suggestedTitle: "Photo Proof"
        )
    }

    public static func importedFile(_ fileURL: URL) -> ProofAttachmentDraft {
        let contentType = UTType(filenameExtension: fileURL.pathExtension)
        let proofType: ProofType
        if contentType?.conforms(to: .image) == true {
            proofType = .image
        } else if contentType?.conforms(to: .audio) == true {
            proofType = .audio
        } else {
            proofType = .file
        }

        return ProofAttachmentDraft(
            data: nil,
            fileURL: fileURL,
            fileName: fileURL.lastPathComponent,
            mimeType: contentType?.preferredMIMEType,
            proofType: proofType,
            suggestedTitle: fileURL.deletingPathExtension().lastPathComponent
        )
    }
}
