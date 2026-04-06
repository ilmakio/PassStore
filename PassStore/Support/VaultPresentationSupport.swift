import AppKit
import Foundation
import SwiftUI

enum PasswordGenerator {
    private static let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*")

    static func generate(length: Int = 24) -> String {
        String((0..<max(length, 1)).compactMap { _ in characters.randomElement() })
    }
}

extension SecretFieldTemplateEntity {
    var summaryText: String {
        let labels = fieldDefinitions
            .sorted { $0.sortOrder < $1.sortOrder }
            .prefix(3)
            .map(\.label)

        if labels.isEmpty {
            return "No predefined fields"
        }

        let summary = labels.joined(separator: " • ")
        if fieldDefinitions.count > 3 {
            return "\(summary) • +\(fieldDefinitions.count - 3)"
        }
        return summary
    }
}

extension SecretItemType {
    var templateDescription: String {
        switch self {
        case .generic:
            "Single secret or token"
        case .envGroup:
            "Whole environment file"
        case .database:
            "Engine, host, database name and credentials"
        case .apiCredential:
            "API keys, client IDs and secrets"
        case .s3Compatible:
            "Bucket, endpoint and access keys"
        case .serverSSH:
            "SSH host, user, password and private key"
        case .websiteService:
            "Login or service credentials"
        case .savedCommand:
            "Shell commands, SQL and run context"
        case .customTemplate:
            "Custom field structure"
        }
    }
}

extension FieldDraft {
    var supportsGeneratedPassword: Bool {
        guard kind == .secret else { return false }
        let descriptor = "\(key) \(label)".lowercased()
        return descriptor.contains("password") || descriptor.contains("passphrase")
    }
}

struct WorkspaceIconPreset: Identifiable, Hashable {
    let id: String
    let systemImage: String
    let label: String

    init(systemImage: String, label: String) {
        self.id = systemImage
        self.systemImage = systemImage
        self.label = label
    }
}

struct WorkspaceColorPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let hex: String

    init(name: String, hex: String) {
        self.id = hex
        self.name = name
        self.hex = hex
    }

    var color: Color {
        Color(hex: hex)
    }
}

enum WorkspaceStylePresets {
    static let icons: [WorkspaceIconPreset] = [
        .init(systemImage: "shippingbox", label: "General"),
        .init(systemImage: "server.rack", label: "Backend"),
        .init(systemImage: "terminal", label: "Infra"),
        .init(systemImage: "globe", label: "Web"),
        .init(systemImage: "iphone", label: "Mobile"),
        .init(systemImage: "key", label: "Security"),
        .init(systemImage: "shippingbox.circle", label: "Platform"),
        .init(systemImage: "bolt.shield", label: "Ops"),
        .init(systemImage: "cloud", label: "Cloud"),
        .init(systemImage: "hammer", label: "Tools")
    ]

    static let colors: [WorkspaceColorPreset] = [
        .init(name: "Cobalt", hex: "#4A7AFF"),
        .init(name: "Ocean", hex: "#2AA198"),
        .init(name: "Mint", hex: "#1FBF8F"),
        .init(name: "Amber", hex: "#E8A317"),
        .init(name: "Coral", hex: "#FF6B57"),
        .init(name: "Ruby", hex: "#D9485F"),
        .init(name: "Plum", hex: "#7C5CFC"),
        .init(name: "Slate", hex: "#5F6B7A")
    ]

    static func icon(for systemImage: String) -> WorkspaceIconPreset? {
        icons.first(where: { $0.systemImage == systemImage })
    }

    static func color(for hex: String) -> WorkspaceColorPreset? {
        colors.first(where: { $0.hex.caseInsensitiveCompare(hex) == .orderedSame })
    }
}

extension Color {
    init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&value)

        let red, green, blue: UInt64
        switch sanitized.count {
        case 6:
            red = (value >> 16) & 0xFF
            green = (value >> 8) & 0xFF
            blue = value & 0xFF
        default:
            red = 74
            green = 122
            blue = 255
        }

        self.init(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: 1
        )
    }
}

enum VaultChrome {
    static let pageBackground = Color(nsColor: .windowBackgroundColor)
    static let sectionBackground = Color(nsColor: .underPageBackgroundColor)
    static let surfaceBackground = Color(nsColor: .controlBackgroundColor)
    static let surfaceRaised = Color(nsColor: .textBackgroundColor)
    static let detailBackground = Color(nsColor: .windowBackgroundColor)
    static let detailSectionBackground = Color(nsColor: .controlBackgroundColor)
    static let detailCardBackground = Color(nsColor: .textBackgroundColor)
    static let detailInsetBackground = Color(nsColor: .underPageBackgroundColor)
    static let overlayBackground = Color.black.opacity(0.4)
    static let mutedFill = Color.primary.opacity(0.06)
}

struct VaultPanelModifier: ViewModifier {
    enum Prominence {
        case `default`
        case section
        case accented
    }

    let prominence: Prominence

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(backgroundColor)
            )
    }

    private var backgroundColor: Color {
        switch prominence {
        case .default:
            VaultChrome.surfaceBackground
        case .section:
            VaultChrome.sectionBackground
        case .accented:
            Color.accentColor.opacity(0.14)
        }
    }
}

struct VaultInfoChipModifier: ViewModifier {
    var accentHex: String? = nil
    var isEmphasized = false

    func body(content: Content) -> some View {
        content
            .background(
                Capsule(style: .continuous)
                    .fill(backgroundColor)
            )
    }

    private var backgroundColor: Color {
        guard let accentHex else {
            return isEmphasized ? VaultChrome.surfaceRaised : VaultChrome.sectionBackground
        }
        return Color(hex: accentHex).opacity(isEmphasized ? 0.22 : 0.14)
    }
}

struct VaultChromeButtonStyle: ButtonStyle {
    enum Prominence {
        case primary
        case secondary
        case success
        case destructive
    }

    let prominence: Prominence

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(foregroundColor)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundColor(configuration.isPressed))
            )
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        switch prominence {
        case .primary, .success, .destructive:
            .white
        case .secondary:
            .primary
        }
    }

    private func backgroundColor(_ isPressed: Bool) -> Color {
        switch prominence {
        case .primary:
            Color.accentColor
        case .success:
            Color.green
        case .destructive:
            Color.red
        case .secondary:
            isPressed ? VaultChrome.surfaceRaised : VaultChrome.surfaceBackground
        }
    }
}

struct VaultIconButtonStyle: ButtonStyle {
    enum Prominence {
        case neutral
        case accent
        case success
    }

    var prominence: Prominence = .neutral

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(width: 30, height: 30)
            .foregroundStyle(foregroundColor)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundColor(configuration.isPressed))
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        switch prominence {
        case .neutral:
            .secondary
        case .accent, .success:
            .white
        }
    }

    private func backgroundColor(_ isPressed: Bool) -> Color {
        switch prominence {
        case .neutral:
            return VaultChrome.surfaceBackground
        case .accent:
            return Color.accentColor
        case .success:
            return Color.green
        }
    }
}

private struct EditorCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.modifier(VaultPanelModifier(prominence: .section))
    }
}

private struct EditorMetaChipModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.secondary)
            .background(
                Capsule(style: .continuous)
                    .fill(VaultChrome.sectionBackground)
            )
    }
}

private struct EditorMetaBadgeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.primary)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(VaultChrome.surfaceBackground)
            )
    }
}

struct EditorInputSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(VaultChrome.surfaceBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
            )
    }
}

extension View {
    func editorCardStyle() -> some View {
        modifier(EditorCardModifier())
    }

    func editorMetaChipStyle() -> some View {
        modifier(EditorMetaChipModifier())
    }

    func editorMetaBadgeStyle() -> some View {
        modifier(EditorMetaBadgeModifier())
    }
}
