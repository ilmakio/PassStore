import AppKit
import SwiftUI

/// The live code for a one-time code field, with the time it has left.
///
/// The digits are shown unmasked on purpose. They are not the secret — the seed behind them is,
/// and that stays hidden — and a code you have to hover to read is a code you cannot type into
/// the box waiting for it.
struct OneTimeCodeValueBox: View {
    let configuration: OneTimeCodeConfiguration
    let isCopied: Bool
    let onCopy: () -> Void

    /// Below this many seconds the code is about to turn over, and pasting it is likely to fail.
    private static let expiringThreshold = 5

    var body: some View {
        // One tick a second is the granularity the code itself has; anything finer redraws for
        // nothing. The ring animates between ticks instead.
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            content(at: context.date)
        }
    }

    private func content(at date: Date) -> some View {
        let code = OneTimeCodeGenerator.code(for: configuration, at: date)
        let remaining = OneTimeCodeGenerator.secondsRemaining(for: configuration, at: date)
        let progress = OneTimeCodeGenerator.progress(for: configuration, at: date)
        let isExpiring = remaining <= Self.expiringThreshold

        return Button(action: onCopy) {
            VaultValueBox(isHighlighted: isCopied) {
                HStack(alignment: .center, spacing: VaultSpacing.m) {
                    Text(OneTimeCodeGenerator.grouped(code))
                        .font(.system(.title2, design: .monospaced).weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(isExpiring ? Color.orange : Color.primary)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.25), value: code)
                        .accessibilityLabel("One-time code \(code.map(String.init).joined(separator: " "))")

                    Spacer(minLength: VaultSpacing.s)

                    OneTimeCodeCountdown(
                        progress: progress,
                        remaining: remaining,
                        isExpiring: isExpiring,
                        period: configuration.period
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .vaultCopiedFeedback(isCopied: isCopied)
        .help("Click to copy this code")
        .accessibilityHint("Activate to copy the current code")
        .accessibilityIdentifier("detail-onetimecode-value")
    }
}

/// A ring that empties as the code runs out, with the seconds written beside it.
///
/// The number alone is easy to miss and the ring alone cannot be read out; a screen reader gets
/// the number and nothing else.
private struct OneTimeCodeCountdown: View {
    let progress: Double
    let remaining: Int
    let isExpiring: Bool
    let period: Int

    private var tint: Color { isExpiring ? .orange : .secondary }

    var body: some View {
        HStack(spacing: VaultSpacing.xs) {
            Text("\(remaining)s")
                .font(.vaultBadge)
                .foregroundStyle(tint)

            ZStack {
                Circle()
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(0.001, 1 - progress))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    // Animating a shrinking trim reads as time running out; animating the jump
                    // back to full when the step turns over reads as it running backwards.
                    .animation(progress > 0.02 ? .linear(duration: 1) : nil, value: progress)
            }
            .frame(width: 16, height: 16)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(remaining) seconds left of \(period)")
    }
}

/// Shown under the code when the field cannot be read as a one-time code at all.
struct OneTimeCodeProblemBox: View {
    let message: String

    var body: some View {
        VaultNote(text: message, tone: .warning, systemImage: "exclamationmark.triangle")
            .accessibilityIdentifier("detail-onetimecode-problem")
    }
}

// MARK: - Editor

/// The control for setting up a one-time code on a field.
///
/// Everything a site can hand you is accepted in the one box: the `otpauth://` URI behind the QR
/// code, or the "setup key" printed next to it, spaces and all. What it read back is stated
/// plainly, with a live code, because the only way to know a 2FA field is right is to see it
/// produce the same digits as the phone you are replacing.
struct OneTimeCodeFieldEditor: View {
    @Binding var value: String
    /// Reveals the stored seed. Off by default so an existing code is not exposed by opening
    /// the editor to change something else on the item.
    @State private var isRevealed = false
    @State private var problem: String?
    @State private var isImportingImage = false

    private var parsed: OneTimeCodeConfiguration? {
        try? OneTimeCodeParser.parse(value)
    }

    private var trimmed: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VaultSpacing.s) {
            entryRow

            if let parsed {
                acceptedSummary(parsed)
            } else if !trimmed.isEmpty {
                // Parsing has already failed here, so the parser's own message is the whole
                // explanation the editor needs to give.
                VaultNote(text: Self.describe(parseErrorFor: value), tone: .warning)
            }

            if let problem {
                VaultNote(text: problem, tone: .warning, systemImage: "qrcode.viewfinder")
            }

            scanRow
        }
        .fileImporter(
            isPresented: $isImportingImage,
            allowedContentTypes: OneTimeCodeQRReader.supportedImageTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImageSelection(result)
        }
    }

    private var entryRow: some View {
        HStack(spacing: VaultSpacing.s) {
            if isRevealed || trimmed.isEmpty {
                TextField("", text: $value, prompt: Text("Setup key or otpauth:// link"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.leading)
                    .accessibilityLabel("One-time code setup key")
                    .accessibilityIdentifier("editor-onetimecode-value")
            } else {
                HStack(spacing: VaultSpacing.s) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                    Text("Setup key stored")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, VaultSpacing.s)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: VaultRadius.control, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: VaultRadius.control, style: .continuous)
                                .strokeBorder(VaultChrome.hairline, lineWidth: 0.5)
                        )
                )
            }

            if !trimmed.isEmpty {
                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(VaultIconButtonStyle(isActive: isRevealed))
                .help(isRevealed ? "Hide the setup key" : "Show the setup key")
                .accessibilityLabel(isRevealed ? "Hide setup key" : "Show setup key")
            }
        }
    }

    /// What was understood, and the code it currently produces.
    private func acceptedSummary(_ configuration: OneTimeCodeConfiguration) -> some View {
        VStack(alignment: .leading, spacing: VaultSpacing.xs) {
            HStack(spacing: VaultSpacing.s) {
                Label("Reads as a one-time code", systemImage: "checkmark.circle")
                    .font(.vaultFootnote)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    Text(OneTimeCodeGenerator.grouped(OneTimeCodeGenerator.code(for: configuration, at: context.date)))
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .monospacedDigit()
                        .accessibilityLabel("Current code preview")
                }
            }

            if let subtitle = configuration.subtitle {
                Text(subtitle)
                    .font(.vaultFootnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Only worth the line when the issuer asked for something unusual; almost nobody does.
            if configuration.hasNonDefaultParameters {
                Text(configuration.parameterSummary)
                    .font(.vaultFootnote)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var scanRow: some View {
        HStack(spacing: VaultSpacing.s) {
            Button {
                problem = nil
                isImportingImage = true
            } label: {
                Label("Scan QR from Image…", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(VaultButtonStyle(.secondary))
            .controlSize(.small)
            .accessibilityIdentifier("editor-onetimecode-scan-file")

            Button {
                readFromClipboard()
            } label: {
                Label("Read QR from Clipboard", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(VaultButtonStyle(.secondary))
            .controlSize(.small)
            .accessibilityIdentifier("editor-onetimecode-scan-clipboard")

            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions

    private func handleImageSelection(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            switch OneTimeCodeQRReader.readSetupURI(fromImageAt: url) {
            case let .success(uri):
                accept(uri)
            case let .failure(error):
                problem = error.localizedDescription
            }
        case let .failure(error):
            problem = error.localizedDescription
        }
    }

    private func readFromClipboard() {
        // A screenshot of the QR code is already on the clipboard nine times out of ten, and
        // reading it there needs no screen-recording permission and no file to save first.
        switch OneTimeCodeQRReader.readSetupURIFromClipboard() {
        case let .success(uri):
            accept(uri)
        case let .failure(error):
            problem = error.localizedDescription
        }
    }

    private func accept(_ uri: String) {
        value = uri
        problem = nil
        // A freshly scanned code is worth showing once: it is the only chance to check it against
        // the phone before the QR code on screen goes away.
        isRevealed = false
    }

    /// The parser's own message, so the editor never invents a second vocabulary for the same
    /// failure.
    private static func describe(parseErrorFor value: String) -> String {
        do {
            _ = try OneTimeCodeParser.parse(value)
            return ""
        } catch let error as OneTimeCodeError {
            return error.errorDescription ?? "That is not a one-time code."
        } catch {
            return error.localizedDescription
        }
    }
}
