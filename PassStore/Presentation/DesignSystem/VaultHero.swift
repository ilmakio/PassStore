import SwiftUI

// MARK: - Hero background

/// The branded backdrop behind the welcome screen and the lock screen.
///
/// Same treatment as the product page: a near-black field, two slowly drifting blurred yellow
/// glows, and a pixel grid that lights up where the glows pass under it. These two screens are
/// the only place in the app allowed to look like a product page — every window behind them
/// stays plain native macOS, which is the point of the contrast.
struct VaultHeroBackground: View {
    var body: some View {
        ZStack {
            baseGradient
            VaultHeroGlows()
            VaultPixelGrid()
            // Darkens the far corners so content in the middle keeps its contrast wherever the
            // glows happen to have drifted to. Kept shallow and pushed well out, or it eats
            // the glow it is supposed to be framing.
            RadialGradient(
                colors: [.clear, .black.opacity(0.38)],
                center: .center,
                startRadius: 320,
                endRadius: 780
            )
            .blendMode(.multiply)
        }
        .background(VaultHeroPalette.base)
        .compositingGroup()
        .background(VaultHeroWindowChrome().frame(width: 0, height: 0))
        .accessibilityHidden(true)
    }

    /// Starts on exactly `base` so the tinted title bar above it has nothing to seam against.
    private var baseGradient: some View {
        LinearGradient(
            colors: [VaultHeroPalette.base, VaultHeroPalette.baseBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Fixed colours, not semantic ones: the hero looks the same in both appearances on purpose,
/// so the brand does not turn into a different screen when somebody switches to light mode.
enum VaultHeroPalette {
    static let base = Color(red: 0.043, green: 0.043, blue: 0.039)
    static let baseBottom = Color(red: 0.016, green: 0.016, blue: 0.016)

    /// The glow yellow, kept a touch warmer than the brand yellow so it reads as light on a
    /// surface rather than as a painted shape.
    static let glow = Color(red: 1.0, green: 0.83, blue: 0.18)

    static let baseNSColor = NSColor(
        srgbRed: 0.043, green: 0.043, blue: 0.039, alpha: 1
    )

    // MARK: Surfaces
    //
    // Solid greys, not translucency. A control drawn as a wash of white over the hero picks up
    // whatever the glow and the pixel grid happen to be doing underneath it, so it shimmers and
    // its edges dissolve. These are opaque, so a button stays a button wherever it sits.

    /// Recessed: text fields, wells, anything you type or read into.
    static let surface = Color(red: 0.106, green: 0.106, blue: 0.102)
    /// Raised: secondary buttons, cards, chips.
    static let surfaceRaised = Color(red: 0.161, green: 0.161, blue: 0.153)
    /// Raised and lit, for pressed or selected.
    static let surfaceActive = Color(red: 0.216, green: 0.216, blue: 0.204)
    static let stroke = Color.white.opacity(0.13)
    static let strokeStrong = Color.white.opacity(0.22)
}

// MARK: - Hero environment

private struct VaultHeroEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside a screen drawn on `VaultHeroBackground`.
    ///
    /// Shared controls read this to swap their translucent macOS fills for the hero's opaque
    /// greys, rather than every hero screen re-implementing a button and a text field.
    var isOnVaultHero: Bool {
        get { self[VaultHeroEnvironmentKey.self] }
        set { self[VaultHeroEnvironmentKey.self] = newValue }
    }
}

extension View {
    /// Marks a subtree as sitting on the hero: dark scheme, opaque control fills.
    func vaultHeroContent() -> some View {
        environment(\.isOnVaultHero, true)
            .environment(\.colorScheme, .dark)
    }
}

// MARK: - Window chrome

/// Tints the title bar to match the hero while one is on screen, and puts it back afterwards.
///
/// Without this the hero stops dead at a strip of standard window chrome — which in light
/// appearance is a white bar over a black panel. Only the title bar's own three properties are
/// touched: the style mask is left alone so the toolbar comes back exactly as it went away, and
/// nothing reaches into the split view AppKit builds for `NavigationSplitView`.
struct VaultHeroWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { context.coordinator.apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.apply(to: nsView.window) }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.finish()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private weak var heldWindow: NSWindow?
        /// One-way, set when SwiftUI takes this view away.
        private var isFinished = false

        /// A view has no window at the moment it is made, so this is handed to the next run-loop
        /// turn — which means a queued call can land *after* SwiftUI has torn the view down.
        /// Unguarded, that call dresses a window with no hero on it and no coordinator left alive
        /// to undo it, and the app keeps the hero's title bar for the rest of its run. Once
        /// finished, always finished.
        func apply(to window: NSWindow?) {
            guard !isFinished, let window, window !== heldWindow else { return }
            release()
            heldWindow = window
            VaultHeroTitlebar.retain(window)
        }

        func finish() {
            isFinished = true
            release()
        }

        private func release() {
            guard let window = heldWindow else { return }
            heldWindow = nil
            VaultHeroTitlebar.release(window)
        }
    }
}

/// The window chrome a hero borrows, counted so it is captured once and put back once.
///
/// Two heroes overlap whenever one crossfades into another, and erasing the vault does exactly
/// that: the lock screen goes straight to onboarding, and for the length of the fade both are
/// mounted. With each screen saving and restoring on its own, the incoming one read the *outgoing
/// one's* black as the value to put back — so the vault came up after setup with a black window
/// that stayed black until the app was quit. Counting means the first hero in captures what was
/// really there and the last hero out is the only one that restores it.
///
/// Deliberately nothing more than that. Three earlier attempts to also chase a hairline in the
/// lock screen from here — writing to the split view's items, re-asserting on every layout pass,
/// substituting "neutral" values for the ones read from the window — each broke the toolbar or
/// the sidebar. The hairline turned out to be a toolbar item's own background and is dealt with
/// where it lives.
@MainActor
enum VaultHeroTitlebar {
    private struct Saved {
        /// Weak, and checked before an entry is trusted: `ObjectIdentifier` is an address, and a
        /// window closed while its entry was still counted would otherwise leave a booby trap for
        /// the next object allocated in the same place.
        weak var window: NSWindow?
        var count = 0
        var background: NSColor?
        var appearsTransparent: Bool?
        var separator: NSTitlebarSeparatorStyle?
    }

    private static var saved: [ObjectIdentifier: Saved] = [:]

    private static func entry(for window: NSWindow) -> Saved? {
        saved = saved.filter { $0.value.window != nil }
        guard let entry = saved[ObjectIdentifier(window)], entry.window === window else { return nil }
        return entry
    }

    static func retain(_ window: NSWindow) {
        var entry = self.entry(for: window) ?? {
            // Read, not assumed. This runs before any hero has dressed the window, which is what
            // makes it the real state — and the count is what guarantees it runs only then.
            var fresh = Saved()
            fresh.window = window
            fresh.background = window.backgroundColor
            fresh.appearsTransparent = window.titlebarAppearsTransparent
            fresh.separator = window.titlebarSeparatorStyle
            return fresh
        }()
        entry.count += 1
        saved[ObjectIdentifier(window)] = entry

        window.backgroundColor = VaultHeroPalette.baseNSColor
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
    }

    static func release(_ window: NSWindow) {
        guard var entry = self.entry(for: window) else { return }
        entry.count -= 1
        guard entry.count <= 0 else {
            saved[ObjectIdentifier(window)] = entry
            return
        }

        saved[ObjectIdentifier(window)] = nil
        if let background = entry.background { window.backgroundColor = background }
        if let appearsTransparent = entry.appearsTransparent {
            window.titlebarAppearsTransparent = appearsTransparent
        }
        if let separator = entry.separator {
            window.titlebarSeparatorStyle = separator
        }
    }
}

// MARK: - Glows

/// Two soft radial washes that drift on a long, offset loop so the pattern never repeats
/// visibly. Animated with a repeating transform rather than a per-frame redraw, so the render
/// thread owns them and the app does no work while they move.
private struct VaultHeroGlows: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDrifting = false

    var body: some View {
        GeometryReader { proxy in
            let side = max(proxy.size.width, proxy.size.height)

            ZStack {
                glow(opacity: 0.46)
                    .frame(width: side * 0.95, height: side * 0.95)
                    .position(x: proxy.size.width * 0.24, y: proxy.size.height * 0.18)
                    .offset(x: isDrifting ? 46 : -34, y: isDrifting ? 30 : -22)
                    .animation(drift(seconds: 17), value: isDrifting)

                glow(opacity: 0.24)
                    .frame(width: side * 0.75, height: side * 0.75)
                    .position(x: proxy.size.width * 0.86, y: proxy.size.height * 0.82)
                    .offset(x: isDrifting ? -40 : 30, y: isDrifting ? -26 : 20)
                    .animation(drift(seconds: 23), value: isDrifting)
            }
        }
        .blendMode(.screen)
        .onAppear { isDrifting = true }
    }

    private func glow(opacity: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        VaultHeroPalette.glow.opacity(opacity),
                        VaultHeroPalette.glow.opacity(opacity * 0.35),
                        .clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 380
                )
            )
            .blur(radius: 40)
    }

    private func drift(seconds: Double) -> Animation? {
        guard !reduceMotion else { return nil }
        return .easeInOut(duration: seconds).repeatForever(autoreverses: true)
    }
}

// MARK: - Pixel grid

/// The dot grid, brighter where the glow passes under it.
///
/// Drawn in a `Canvas` and batched into a handful of opacity buckets, so a screen full of
/// several thousand dots costs a dozen fills per frame rather than one fill per dot. It ticks
/// at 12fps — fast enough to read as alive, slow enough that a vault left locked all afternoon
/// is not quietly spinning a fan.
struct VaultPixelGrid: View {
    /// Colour of the lit dots; the unlit base grid is always neutral.
    var tint: Color = VaultHeroPalette.glow
    var spacing: CGFloat = 13
    var dot: CGFloat = 2
    /// Brightness of the lit dots at the centre of the glow.
    var maxAlpha: Double = 0.8
    /// Brightness of the grid everywhere else.
    var baseAlpha: Double = 0.055
    /// Where the lit patch sits, before it starts drifting.
    var focus = UnitPoint(x: 0.24, y: 0.20)
    var framesPerSecond: Double = 12

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    private static let buckets = 6

    /// Nothing repaints while the window is in the background: this view can sit on screen for
    /// hours behind a locked vault.
    private var isPaused: Bool {
        reduceMotion || controlActiveState == .inactive
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / framesPerSecond, paused: isPaused)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                draw(in: &context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        guard size.width > 1, size.height > 1 else { return }

        let columns = Int(size.width / spacing) + 2
        let rows = Int(size.height / spacing) + 2

        // Follows the glow, on its own slower loop so the two never quite line up.
        let centre = CGPoint(
            x: size.width * (focus.x + 0.05 * sin(time * 0.11)),
            y: size.height * (focus.y + 0.07 * cos(time * 0.09))
        )
        let reach = max(size.width, size.height) * 0.85

        var base = Path()
        var lit = [Path](repeating: Path(), count: Self.buckets)

        for row in 0..<rows {
            for column in 0..<columns {
                let x = CGFloat(column) * spacing
                let y = CGFloat(row) * spacing
                let rect = CGRect(x: x, y: y, width: dot, height: dot)

                base.addRect(rect)

                let distance = hypot(x - centre.x, y - centre.y) / reach
                guard distance < 1 else { continue }

                let falloff = pow(1 - distance, 2.2)
                let phase = Self.scatter(column: column, row: row)
                let shimmer = 0.55 + 0.45 * sin(time * 0.8 + phase * 6.283)
                let intensity = falloff * shimmer * (0.35 + 0.65 * phase)

                guard intensity > 0.04 else { continue }
                lit[min(Self.buckets - 1, Int(intensity * Double(Self.buckets)))].addRect(rect)
            }
        }

        context.fill(base, with: .color(.white.opacity(baseAlpha)))
        for (index, path) in lit.enumerated() where !path.isEmpty {
            let alpha = Double(index + 1) / Double(Self.buckets) * maxAlpha
            context.fill(path, with: .color(tint.opacity(alpha)))
        }
    }

    /// Stable per-cell value in 0..<1, so the grid reads as dithered rather than as a
    /// perfectly even wave. Cheap enough to recompute every frame at this cell count.
    private static func scatter(column: Int, row: Int) -> Double {
        let value = sin(Double(column) * 12.9898 + Double(row) * 78.233) * 43758.5453
        return value - value.rounded(.down)
    }
}

// MARK: - Logo

/// The app icon, breathing.
///
/// A slow float and a glow that swells behind it. Small enough to be ambient rather than
/// distracting, and stopped entirely under Reduce Motion.
struct VaultHeroLogo: View {
    var size: CGFloat = 96
    /// Drawn over the bottom-trailing corner, for the lock screen's Touch ID hint.
    var badge: AnyView?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBreathing = false
    @State private var hasEntered = false

    var body: some View {
        icon
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
            .background {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                VaultHeroPalette.glow.opacity(0.55),
                                VaultHeroPalette.glow.opacity(0.12),
                                .clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: size
                        )
                    )
                    .blur(radius: 22)
                    .scaleEffect(isBreathing ? 1.22 : 0.92)
                    .opacity(isBreathing ? 0.95 : 0.55)
                    .animation(breath(seconds: 3.6), value: isBreathing)
            }
            .overlay(alignment: .bottomTrailing) { badge }
            .offset(y: isBreathing ? -4 : 4)
            .animation(breath(seconds: 4.4), value: isBreathing)
            .scaleEffect(hasEntered ? 1 : 0.7)
            .opacity(hasEntered ? 1 : 0)
            .onAppear {
                withAnimation(reduceMotion ? nil : .spring(response: 0.65, dampingFraction: 0.62)) {
                    hasEntered = true
                }
                isBreathing = true
            }
    }

    private func breath(seconds: Double) -> Animation? {
        guard !reduceMotion else { return nil }
        return .easeInOut(duration: seconds).repeatForever(autoreverses: true)
    }

    @ViewBuilder
    private var icon: some View {
        if let appIcon = NSImage(named: NSImage.applicationIconName) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image("icon")
                .resizable()
                .scaledToFit()
        }
    }
}

// MARK: - Wordmark

/// "PassStore" plus its tagline, set at display size.
struct VaultHeroWordmark: View {
    var tagline: String

    var body: some View {
        VStack(spacing: VaultSpacing.s) {
            Text("PassStore")
                .font(.vaultHeroTitle)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 4)

            Text(tagline)
                .font(.vaultHeroTagline)
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Field

/// A text field that belongs on the hero.
///
/// `.roundedBorder` draws a light control that punches a hole in the dark panel, so the hero
/// draws its own: an opaque well with an accent border while it holds focus.
struct VaultHeroFieldBackground: ViewModifier {
    var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.body)
            .foregroundStyle(.white)
            .padding(.horizontal, VaultSpacing.m)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: VaultRadius.value, style: .continuous)
                    .fill(VaultHeroPalette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: VaultRadius.value, style: .continuous)
                    .strokeBorder(
                        isFocused ? Color.vaultAccent.opacity(0.85) : VaultHeroPalette.stroke,
                        lineWidth: isFocused ? 1.5 : 1
                    )
            )
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

extension View {
    func vaultHeroField(isFocused: Bool) -> some View {
        modifier(VaultHeroFieldBackground(isFocused: isFocused))
    }
}

// MARK: - Card

/// The hero's answer to `VaultCard`: same shape, opaque fill.
struct VaultHeroCard<Content: View>: View {
    var padding: CGFloat = VaultSpacing.l
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: VaultSpacing.m) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(padding)
        .background(
            RoundedRectangle(cornerRadius: VaultRadius.card, style: .continuous)
                .fill(VaultHeroPalette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VaultRadius.card, style: .continuous)
                .strokeBorder(VaultHeroPalette.stroke, lineWidth: 1)
        )
    }
}

// MARK: - Preview

#Preview("Hero") {
    ZStack {
        VaultHeroBackground()
        VStack(spacing: VaultSpacing.xl) {
            VaultHeroLogo()
            VaultHeroWordmark(tagline: "Developer secrets that never leave your Mac.")
            Button("Get Started") {}
                .buttonStyle(VaultButtonStyle(.primary))
        }
    }
    .frame(width: 900, height: 580)
}
