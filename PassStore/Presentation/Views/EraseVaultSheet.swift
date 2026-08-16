import SwiftUI

/// Confirmation for erasing the vault after a forgotten master password.
///
/// This is the only irreversible, everything-at-once action in the app, and the one people
/// reach for when they are already frustrated. A single "are you sure?" is not enough of a
/// pause, so the consequences are spelled out in full and the button stays disabled until the
/// confirmation word has been typed.
struct EraseVaultSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var sessionManager: VaultSessionManager
    let onErase: () throws -> Void

    @State private var typedConfirmation = ""
    @State private var errorMessage: String?
    @State private var isAuthorising = false
    @FocusState private var isFieldFocused: Bool

    /// Deliberately not localised and deliberately not the word on the button: it has to be
    /// read and typed, not muscle-memoried.
    private static let confirmationWord = "ERASE"

    private var canErase: Bool {
        typedConfirmation.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == Self.confirmationWord
    }

    var body: some View {
        VaultSheetScaffold(
            title: "Erase Vault",
            subtitle: "For when the master password is lost for good.",
            systemImage: "exclamationmark.triangle.fill",
            tint: .red
        ) {
            Spacer(minLength: 0)

            Button("Cancel") { dismiss() }
                .buttonStyle(VaultButtonStyle(.secondary))
                .keyboardShortcut(.cancelAction)

            if isAuthorising {
                ProgressView().controlSize(.small)
            }

            Button(sessionManager.requiresBiometricAuthorisationToErase ? "Authorise and Erase" : "Erase Vault") {
                erase()
            }
            .buttonStyle(VaultButtonStyle(.destructive))
            .disabled(!canErase || isAuthorising)
            .accessibilityIdentifier("erase-vault-confirm")
        } content: {
            VaultNote(
                text: "A master password cannot be recovered or reset. Your secrets are encrypted with it, so without it nothing — including PassStore — can read them.",
                tone: .danger
            )

            if sessionManager.requiresBiometricAuthorisationToErase {
                VaultNote(
                    text: "Touch ID is required to erase, so nobody who wanders past your Mac can do this for you.",
                    tone: .success,
                    systemImage: "touchid"
                )
            }

            if let errorMessage {
                VaultNote(text: errorMessage, tone: .danger)
            }

            VaultSection("What will be deleted", systemImage: "trash", tint: .red) {
                bullet("Every secret, workspace, template and custom field stored on this Mac.")
                bullet("Every stored previous value and item history.")
                bullet("The Touch ID key PassStore keeps in your Keychain.")
                bullet("All PassStore settings.")
            }

            VaultSection("What will not be touched", systemImage: "checkmark.shield", tint: .green) {
                bullet("`.pstore` backup files saved anywhere else on your Mac.")
                bullet("Any `.env` files on disk that items were linked to.")
                bullet("After erasing you can set up a new vault and restore a backup into it — if you have one, and if you remember its export password.")
            }

            VaultSection("Confirm", systemImage: "keyboard") {
                VaultField(
                    "Type \(Self.confirmationWord) to continue",
                    hint: "This cannot be undone, and it takes effect immediately."
                ) {
                    TextField("", text: $typedConfirmation, prompt: Text(Self.confirmationWord))
                        .textFieldStyle(.roundedBorder)
                        .font(.vaultValue)
                        .focused($isFieldFocused)
                        .onSubmit { if canErase { erase() } }
                        .accessibilityIdentifier("erase-vault-confirmation-field")
                }
            }
        }
        .frame(width: 500, height: 600)
        .onAppear { isFieldFocused = true }
    }

    private func erase() {
        errorMessage = nil
        isAuthorising = true
        Task {
            defer { isAuthorising = false }
            guard await sessionManager.authoriseErase() else {
                errorMessage = sessionManager.lastErrorMessage ?? "Erase was not authorised."
                return
            }
            do {
                try onErase()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: VaultSpacing.s) {
            Text("•")
                .font(.vaultFootnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(.init(text))
                .font(.vaultFootnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
