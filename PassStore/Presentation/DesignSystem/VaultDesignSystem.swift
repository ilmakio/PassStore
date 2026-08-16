import SwiftUI

// MARK: - Metrics

/// One spacing scale for the whole app.
///
/// Before 1.2.0 every screen invented its own paddings (8/9/10/12/14/20 all appeared within
/// the same sheet), which is most of why the app read as "anonymous but slightly off".
enum VaultSpacing {
    static let hair: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 28
}

enum VaultRadius {
    static let control: CGFloat = 7
    static let value: CGFloat = 9
    static let card: CGFloat = 12
    static let hero: CGFloat = 14
}

extension Color {
    /// The brand yellow, used for tints, selection and accents.
    static let vaultAccent = Color.accentColor

    /// A deeper shade of the same hue, used wherever a filled control carries white text.
    ///
    /// The brand yellow is too light to sit under white — around 1.7:1, which is why SwiftUI's
    /// own prominent button style silently switched some labels to black and left the app
    /// looking like it had two kinds of yellow button. Filled buttons use this instead, so
    /// every one of them reads the same way, while the rest of the app keeps the bright yellow.
    static let vaultAccentStrong = Color("AccentStrong")
}

enum VaultChrome {
    static let mutedFill = Color.primary.opacity(0.06)
    static let hairline = Color.primary.opacity(0.09)
    static let hairlineStrong = Color.primary.opacity(0.14)

    /// Height of the accent rule that marks a section header. Small, but it is the one
    /// repeated graphic element that makes the app recognisable as itself.
    static let sectionRuleWidth: CGFloat = 3
}

// MARK: - Typography

/// Semantic text styles.
///
/// Everything here resolves to a system text style, so the app follows the user's text-size
/// setting. Fixed `.system(size:)` values do not, which is why they are gone.
extension Font {
    /// Screen or sheet title.
    static let vaultTitle = Font.title3.weight(.semibold)
    /// Section header inside a sheet or pane.
    static let vaultSectionTitle = Font.subheadline.weight(.semibold)
    /// Primary row text (item titles, list rows).
    static let vaultRowTitle = Font.callout.weight(.medium)
    /// Supporting row text.
    static let vaultRowSubtitle = Font.caption
    /// Label above a control.
    static let vaultFieldLabel = Font.caption.weight(.medium)
    /// Explanatory paragraph under a control.
    static let vaultFootnote = Font.caption
    /// Stored values, keys, generated passwords.
    static let vaultValue = Font.system(.body, design: .monospaced)
    static let vaultValueSmall = Font.system(.caption, design: .monospaced)
    /// Counts and badges that must not jitter as digits change.
    static let vaultBadge = Font.caption2.weight(.medium).monospacedDigit()
}

// MARK: - Card

/// The single card background used by every grouped surface in the app.
struct VaultCardBackground: View {
    var cornerRadius: CGFloat = VaultRadius.card
    var isProminent = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(isProminent ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(.regularMaterial))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08),
                        lineWidth: 0.5
                    )
            )
    }
}

/// Content wrapped in the standard card.
struct VaultCard<Content: View>: View {
    var cornerRadius: CGFloat = VaultRadius.card
    var padding: CGFloat = VaultSpacing.l
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: VaultSpacing.m) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(padding)
        .background { VaultCardBackground(cornerRadius: cornerRadius) }
    }
}

// MARK: - Section

/// A titled group: accent rule, optional icon, title, optional trailing accessory, then a card.
///
/// This is the app's main structural element — using it everywhere is what gives the
/// otherwise plain macOS chrome a consistent identity.
struct VaultSection<Content: View, Accessory: View>: View {
    let title: String
    var systemImage: String?
    var tint: Color = .accentColor
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: VaultSpacing.s) {
            if !title.isEmpty {
                HStack(spacing: VaultSpacing.s) {
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.85))
                        .frame(width: VaultChrome.sectionRuleWidth, height: 12)
                        .accessibilityHidden(true)

                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.caption)
                            .foregroundStyle(tint)
                            .accessibilityHidden(true)
                    }

                    Text(title)
                        .font(.vaultSectionTitle)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: VaultSpacing.s)

                    accessory()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            }

            VaultCard { content() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension VaultSection where Accessory == EmptyView {
    init(
        _ title: String,
        systemImage: String? = nil,
        tint: Color = .accentColor,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(title: title, systemImage: systemImage, tint: tint, accessory: { EmptyView() }, content: content)
    }
}

extension VaultSection {
    init(
        _ title: String,
        systemImage: String? = nil,
        tint: Color = .accentColor,
        @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(title: title, systemImage: systemImage, tint: tint, accessory: accessory, content: content)
    }
}

// MARK: - Form row

/// Label above control, with an optional hint underneath.
///
/// macOS `Form` wants a two-column layout that fights every custom control in these sheets,
/// so the app lays fields out itself — but through one component rather than per screen.
struct VaultField<Content: View>: View {
    let title: String
    var hint: String?
    var titleAccessibilityIdentifier: String?
    @ViewBuilder let content: () -> Content

    init(
        _ title: String,
        hint: String? = nil,
        titleAccessibilityIdentifier: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.hint = hint
        self.titleAccessibilityIdentifier = titleAccessibilityIdentifier
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VaultSpacing.xs) {
            if !title.isEmpty {
                Text(title)
                    .font(.vaultFieldLabel)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(OptionalAccessibilityIdentifier(identifier: titleAccessibilityIdentifier))
            }

            content()
                .frame(maxWidth: .infinity, alignment: .leading)

            if let hint, !hint.isEmpty {
                Text(hint)
                    .font(.vaultFootnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OptionalAccessibilityIdentifier: ViewModifier {
    let identifier: String?

    func body(content: Content) -> some View {
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}

// MARK: - Explanatory note

enum VaultNoteTone {
    case neutral
    case warning
    case danger
    case success

    var tint: Color {
        switch self {
        case .neutral: .secondary
        case .warning: .orange
        case .danger: .red
        case .success: .green
        }
    }

    var systemImage: String {
        switch self {
        case .neutral: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .danger: "exclamationmark.octagon"
        case .success: "checkmark.circle"
        }
    }
}

/// The recurring "here is what this actually does" paragraph, in one consistent shape.
struct VaultNote: View {
    let text: String
    var tone: VaultNoteTone = .neutral
    var systemImage: String?

    var body: some View {
        HStack(alignment: .top, spacing: VaultSpacing.s) {
            Image(systemName: systemImage ?? tone.systemImage)
                .font(.vaultFootnote)
                .foregroundStyle(tone.tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.vaultFootnote)
                .foregroundStyle(tone == .neutral ? .secondary : tone.tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Value container

/// The monospaced box that holds a stored value, a generated password or a JSON blob.
struct VaultValueBox<Content: View>: View {
    var isHighlighted = false
    var highlightColor: Color = .accentColor
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(VaultSpacing.s)
            .background(
                RoundedRectangle(cornerRadius: VaultRadius.value, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: VaultRadius.value, style: .continuous)
                            .strokeBorder(
                                isHighlighted ? highlightColor.opacity(0.9) : VaultChrome.hairline,
                                lineWidth: isHighlighted ? 1.5 : 0.5
                            )
                    )
            )
    }
}

// MARK: - Text editor

/// Multi-line text box with a placeholder.
///
/// `TextEditor` has no prompt, so every screen that needed one overlaid a `Text` at
/// hand-tuned coordinates — which drifted between screens and broke when the font changed.
struct VaultTextEditor: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 90
    var isMonospaced = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .font(isMonospaced ? .vaultValue : .body)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
                .multilineTextAlignment(.leading)
                .padding(VaultSpacing.xs)

            if text.isEmpty {
                Text(placeholder)
                    .font(isMonospaced ? .vaultValue : .body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, VaultSpacing.s)
                    .padding(.vertical, VaultSpacing.s + 2)
                    .allowsHitTesting(false)
            }
        }
        .padding(VaultSpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: VaultRadius.value, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: VaultRadius.value, style: .continuous)
                        .strokeBorder(VaultChrome.hairline, lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Chips

/// Small labelled capsule used for workspace / environment / tag metadata.
struct VaultChip: View {
    let title: String
    var systemImage: String?
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: VaultSpacing.xs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundStyle(color == .secondary ? Color.secondary : color)
        .padding(.horizontal, VaultSpacing.s)
        .padding(.vertical, VaultSpacing.xs)
        .background(
            Capsule(style: .continuous)
                .fill((color == .secondary ? Color.primary : color).opacity(0.10))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder((color == .secondary ? Color.primary : color).opacity(0.16), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

// MARK: - Button styles

/// Primary / secondary sheet actions.
///
/// Always white on `vaultAccentStrong`. SwiftUI's `.borderedProminent` picks its label colour
/// from the fill's luminance, which against a yellow accent meant some buttons came out with
/// black text and others white.
struct VaultButtonStyle: ButtonStyle {
    enum Role {
        case primary
        case secondary
        case destructive
    }

    let role: Role
    @Environment(\.isEnabled) private var isEnabled

    init(_ role: Role = .secondary) {
        self.role = role
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.vertical, VaultSpacing.s)
            .padding(.horizontal, VaultSpacing.xl)
            .background(
                Capsule(style: .continuous)
                    .fill(fill)
            )
            .foregroundStyle(foreground)
            .opacity(opacity(isPressed: configuration.isPressed))
            .contentShape(Capsule(style: .continuous))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

    private var fill: Color {
        switch role {
        case .primary: Color.vaultAccentStrong
        case .secondary: Color.primary.opacity(0.08)
        case .destructive: Color.red
        }
    }

    private var foreground: Color {
        switch role {
        case .primary, .destructive: .white
        case .secondary: .primary
        }
    }

    private func opacity(isPressed: Bool) -> Double {
        if !isEnabled { return 0.4 }
        return isPressed ? 0.75 : 1
    }
}

/// Compact icon button used in rows and toolbars (copy, reveal, generate…).
struct VaultIconButtonStyle: ButtonStyle {
    var isActive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .frame(width: 24, height: 22)
            .background(
                RoundedRectangle(cornerRadius: VaultRadius.control - 1, style: .continuous)
                    .fill(configuration.isPressed || isActive ? Color.primary.opacity(0.12) : Color.clear)
            )
            // The explicit asset colour, not `Color.accentColor`: the item list clears its
            // tint to suppress the system row highlight, which would take this with it.
            .foregroundStyle(isActive ? AnyShapeStyle(Color.vaultAccentStrong) : AnyShapeStyle(.secondary))
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(Rectangle())
    }
}

// MARK: - Sheet scaffold

/// Every sheet in the app: icon + title + subtitle header, scrolling body, pinned footer.
///
/// Sheets used to each roll their own header and footer, which is why some clipped their
/// buttons and others had none at all.
struct VaultSheetScaffold<Content: View, Footer: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var tint: Color = .accentColor
    /// Set false for sheets that manage their own scrolling (split views, lists).
    var scrolls = true
    @ViewBuilder let footer: () -> Footer
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Group {
                if scrolls {
                    ScrollView {
                        VStack(alignment: .leading, spacing: VaultSpacing.xl) {
                            content()
                        }
                        .padding(VaultSpacing.xl)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    content()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            HStack(spacing: VaultSpacing.m) {
                footer()
            }
            .padding(.horizontal, VaultSpacing.xl)
            .padding(.vertical, VaultSpacing.m)
            .frame(maxWidth: .infinity)
        }
        .background(.windowBackground)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: VaultSpacing.m) {
            if let systemImage {
                RoundedRectangle(cornerRadius: VaultRadius.value, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: systemImage)
                            .font(.body)
                            .foregroundStyle(tint)
                    )
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.vaultTitle)
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.vaultFootnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, VaultSpacing.xl)
        .padding(.vertical, VaultSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Empty state

/// Consistent empty / placeholder state.
struct VaultEmptyState<Actions: View>: View {
    let title: String
    let message: String
    var systemImage: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: VaultSpacing.m) {
            Image(systemName: systemImage)
                .font(.system(.largeTitle, design: .default, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            VStack(spacing: VaultSpacing.xs) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actions()
        }
        .padding(VaultSpacing.xxl)
        .frame(maxWidth: 360)
    }
}

extension VaultEmptyState where Actions == EmptyView {
    init(title: String, message: String, systemImage: String) {
        self.init(title: title, message: message, systemImage: systemImage, actions: { EmptyView() })
    }
}
