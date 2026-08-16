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
    /// The brand yellow: fills, selection, tints, anything the accent paints *behind* content.
    ///
    /// Read from the asset rather than `Color.accentColor` so it survives views that clear
    /// their tint to suppress a system highlight.
    static let vaultAccent = Color("AccentColor")

    /// The same hue shifted to whatever reads on the window background, for the rare places
    /// where the accent is the *text* rather than what sits under it.
    ///
    /// Bright yellow type on white is around 1.5:1 and effectively invisible, so the light
    /// appearance uses a dark gold; on a dark background the bright yellow is already fine and
    /// is kept. Fills never use this — they use `vaultAccent` with black content on top.
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
    /// The wordmark on the welcome and lock screens.
    ///
    /// The one deliberate fixed size in the app: this is the brand set at display size, and it
    /// is drawn inside a hero panel sized by the window rather than by the text around it.
    static let vaultHeroTitle = Font.system(size: 46, weight: .bold)
    /// Supporting line under the wordmark.
    static let vaultHeroTagline = Font.system(size: 15, weight: .regular)
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
    @Environment(\.isOnVaultHero) private var isOnHero

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isOnHero ? VaultHeroPalette.stroke : Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08),
                        lineWidth: isOnHero ? 1 : 0.5
                    )
            )
    }

    /// Material blurs whatever is behind it, which on the hero means blurring a live animation.
    private var fill: AnyShapeStyle {
        if isOnHero {
            return AnyShapeStyle(isProminent ? VaultHeroPalette.surfaceRaised : VaultHeroPalette.surface)
        }
        return AnyShapeStyle(isProminent ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(.regularMaterial))
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
                VaultSectionHeader(title: title, systemImage: systemImage, tint: tint, accessory: accessory)
            }

            VaultCard { content() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The accent rule + icon + title line on its own.
///
/// Used directly by the few places whose content is already a set of cards: wrapping a grid of
/// cards in another card just draws a box around a box.
struct VaultSectionHeader<Accessory: View>: View {
    let title: String
    var systemImage: String?
    var tint: Color = .accentColor
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
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
}

extension VaultSectionHeader where Accessory == EmptyView {
    init(_ title: String, systemImage: String? = nil, tint: Color = .accentColor) {
        self.init(title: title, systemImage: systemImage, tint: tint, accessory: { EmptyView() })
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

// MARK: - Flow layout

/// Lays children out left to right, wrapping to a new line when the row runs out of room.
///
/// Chips used to sit in a horizontal `ScrollView`, which meant a long workspace name left the
/// next chip sliced down the middle at the edge of the pane, with nothing to say it was
/// scrollable. Metadata should wrap like text, not queue up off-screen.
struct VaultFlowLayout: Layout {
    var spacing: CGFloat = VaultSpacing.s
    var lineSpacing: CGFloat = VaultSpacing.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let rows = self.rows(within: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var y = bounds.minY
        for row in rows(within: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(within maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width

            if !current.indices.isEmpty, needed > maxWidth {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }

        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Button styles

/// Primary / secondary sheet actions.
///
/// Every yellow button in the app is the brand yellow with **black** type, in every view and
/// in both appearances. SwiftUI's own `.borderedProminent` picks its label colour from the
/// fill's luminance, which against a yellow accent meant some buttons came out black and
/// others white — which is what made the app look like it had two kinds of yellow button.
struct VaultButtonStyle: ButtonStyle {
    enum Role {
        case primary
        case secondary
        case destructive
    }

    let role: Role
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isOnVaultHero) private var isOnHero

    init(_ role: Role = .secondary) {
        self.role = role
    }

    private var isLarge: Bool { controlSize == .large || controlSize == .extraLarge }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(isLarge ? .body.weight(.semibold) : .callout.weight(.semibold))
            .padding(.vertical, isLarge ? VaultSpacing.m : VaultSpacing.s)
            .padding(.horizontal, isLarge ? 32 : VaultSpacing.xl)
            .background(
                Capsule(style: .continuous)
                    .fill(fill)
            )
            // Secondary is a wash, which on a busy or very dark surface can lose its edge
            // entirely. The hairline keeps it a button.
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            )
            .foregroundStyle(foreground)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule(style: .continuous))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }

    /// Disabled is a neutral wash for every role rather than a faded version of the role's own
    /// colour: yellow at 40% over a dark panel comes out as murky olive with black type on it.
    ///
    /// On the hero the neutrals are opaque. A translucent button there sits over a drifting
    /// glow and an animated grid, so it shimmers and its edge disappears wherever the two
    /// happen to be bright.
    private var fill: Color {
        guard isEnabled else {
            return isOnHero ? VaultHeroPalette.surface : Color.primary.opacity(0.10)
        }
        switch role {
        case .primary: return Color.vaultAccent
        case .secondary: return isOnHero ? VaultHeroPalette.surfaceRaised : Color.primary.opacity(0.08)
        case .destructive: return Color.red
        }
    }

    private var stroke: Color {
        guard role == .secondary || !isEnabled else { return .clear }
        return isOnHero ? VaultHeroPalette.stroke : Color.primary.opacity(0.13)
    }

    private var foreground: Color {
        guard isEnabled else { return isOnHero ? .white.opacity(0.35) : Color.secondary }
        switch role {
        case .primary: return .black
        case .destructive: return .white
        case .secondary: return .primary
        }
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

            footerBar
        }
        .background(.windowBackground)
    }

    /// A tinted band rather than a plain strip: it gives the sheet a top edge that belongs to
    /// the app, and tells you at a glance which kind of sheet you opened.
    private var header: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: VaultSpacing.m) {
                if let systemImage {
                    RoundedRectangle(cornerRadius: VaultRadius.value, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.30), tint.opacity(0.14)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 36, height: 36)
                        .overlay(
                            RoundedRectangle(cornerRadius: VaultRadius.value, style: .continuous)
                                .strokeBorder(tint.opacity(0.28), lineWidth: 0.5)
                        )
                        .overlay(
                            Image(systemName: systemImage)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(headerGlyph)
                        )
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
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
            .padding(.vertical, VaultSpacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [tint.opacity(0.10), tint.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            Rectangle()
                .fill(VaultChrome.hairline)
                .frame(height: 1)
        }
    }

    /// The brand yellow is too light to carry a glyph on a pale tile; every other tint is fine
    /// as itself.
    private var headerGlyph: Color {
        tint == .accentColor || tint == .vaultAccent ? .vaultAccentStrong : tint
    }

    private var footerBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(VaultChrome.hairline)
                .frame(height: 1)

            HStack(spacing: VaultSpacing.m) {
                footer()
            }
            .padding(.horizontal, VaultSpacing.xl)
            .padding(.vertical, VaultSpacing.m)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.035))
        }
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
