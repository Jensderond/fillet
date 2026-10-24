import SwiftUI
import UniformTypeIdentifiers

@main
struct FilletApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: FilletFile()) { file in
            Text("Fillet")
        }
    }
}

extension UTType {
    static let filletDocument = UTType(exportedAs: "app.fillet.document")
}

struct FilletFile: FileDocument {
    static let readableContentTypes: [UTType] = [.filletDocument]
    var data = Data("{}".utf8)

    init() {}
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
