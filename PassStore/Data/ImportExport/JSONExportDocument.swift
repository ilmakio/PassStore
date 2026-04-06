import SwiftUI
import UniformTypeIdentifiers

/// Bridges encrypted export `Data` to SwiftUI `.fileExporter` (sandbox-friendly save flow).
struct JSONExportDocument: FileDocument {
    /// Prefer `.pstore`; keep `.json` so older backups still open if needed.
    static var readableContentTypes: [UTType] { [.passStoreBackup, .json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
