import AppKit
import CoreImage
import Foundation
import UniformTypeIdentifiers

nonisolated enum OneTimeCodeQRReaderError: LocalizedError, Equatable, Sendable {
    case fileTooLarge
    case unreadableImage
    case noQRCodeFound
    case noImageOnClipboard
    /// A QR code was read, but it encodes something else. The payload is deliberately not
    /// quoted back: an unexpected QR code can hold anything, including a credential, and an
    /// error message is the one place a secret must never appear.
    case notAOneTimeCode

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            "That image is too large to scan."
        case .unreadableImage:
            "That file could not be read as an image."
        case .noQRCodeFound:
            "No QR code was found in that image."
        case .noImageOnClipboard:
            "The clipboard has no image or setup link in it."
        case .notAOneTimeCode:
            "That QR code is not a one-time code setup link."
        }
    }
}

/// Reads the `otpauth://` link out of the QR code a service shows during 2FA setup.
///
/// Two ways in, both of which avoid asking for a permission: a saved image file, and whatever is
/// on the clipboard — which is where a screenshot of the setup page already is. Capturing the
/// screen directly would need Screen Recording, a permission a password manager should not be
/// asking for to save somebody a ⌘⇧4.
enum OneTimeCodeQRReader {
    /// Any image type the system can decode; narrowing it only makes the picker refuse files it
    /// could have read.
    static let supportedImageTypes: [UTType] = [.image]

    /// Generous but bounded: a retina screenshot is a few megabytes, and a vault should not try
    /// to decode an arbitrarily large file handed to it.
    static let maximumImageBytes = 64 * 1_024 * 1_024

    static func readSetupURI(fromImageAt url: URL) -> Result<String, OneTimeCodeQRReaderError> {
        let gotAccess = url.startAccessingSecurityScopedResource()
        defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let read = try handle.read(upToCount: maximumImageBytes + 1) ?? Data()
            guard read.count <= maximumImageBytes else { return .failure(.fileTooLarge) }
            data = read
        } catch {
            return .failure(.unreadableImage)
        }

        guard let image = CIImage(data: data) else { return .failure(.unreadableImage) }
        return payload(in: image)
    }

    static func readSetupURIFromClipboard() -> Result<String, OneTimeCodeQRReaderError> {
        let pasteboard = NSPasteboard.general

        // A pasted link is the same thing without the round trip through an image, and some
        // services offer the URI as text next to the QR code.
        if let text = pasteboard.string(forType: .string)?.nilIfBlankValue,
           OneTimeCodeParser.isPlausible(text) {
            return .success(text)
        }

        guard let image = clipboardImage(from: pasteboard) else { return .failure(.noImageOnClipboard) }
        return payload(in: image)
    }

    // MARK: - Private

    private static func clipboardImage(from pasteboard: NSPasteboard) -> CIImage? {
        for type in [NSPasteboard.PasteboardType.tiff, .png] {
            if let data = pasteboard.data(forType: type), let image = CIImage(data: data) {
                return image
            }
        }
        // A file copied in Finder arrives as a URL rather than as pixels.
        guard let objects = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage],
              let representation = objects.first?.tiffRepresentation else {
            return nil
        }
        return CIImage(data: representation)
    }

    /// The first QR code in the image that is actually a one-time code link.
    ///
    /// A screenshot of a setup page can contain more than one QR code, so every payload is tried
    /// rather than only the first the detector happens to return.
    private static func payload(in image: CIImage) -> Result<String, OneTimeCodeQRReaderError> {
        guard let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ) else {
            return .failure(.noQRCodeFound)
        }

        let messages = detector.features(in: image)
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString?.nilIfBlankValue }
        guard !messages.isEmpty else { return .failure(.noQRCodeFound) }

        if let match = messages.first(where: { OneTimeCodeParser.isPlausible($0) }) {
            return .success(match)
        }
        return .failure(.notAOneTimeCode)
    }
}

private nonisolated extension String {
    var nilIfBlankValue: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
