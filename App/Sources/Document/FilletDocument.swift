import FilletCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let filletDocument = UTType(exportedAs: "app.fillet.document")
    static let threeMF = UTType(importedAs: "com.microsoft.3mf")
    static let stl = UTType(importedAs: "public.standard-tesselated-geometry-format")
    static let step = UTType(importedAs: "org.iso.step")
}

/// A `.fillet` file: the document model as pretty-printed JSON.
struct FilletDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.filletDocument]

    var model: Document

    init(model: Document = Document()) { self.model = model }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        model = try Document(data: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try model.encoded())
    }
}
