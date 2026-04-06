import UniformTypeIdentifiers

extension UTType {
    /// Encrypted PassStore backup (`.pstore`). On disk the envelope is JSON; the extension marks the proprietary backup format.
    static var passStoreBackup: UTType {
        UTType(exportedAs: "app.makio.PassStore.pstore", conformingTo: .json)
    }
}
