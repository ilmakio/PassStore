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
}

// MARK: - Window chrome

/// Tints the title bar to match the hero while one is on screen, and puts it back afterwards.
///
/// Without this the hero stops dead at a strip of standard window chrome — which in light
/// appearance is a white bar over a black panel. Only the title bar's colour is touched: the
/// window's style mask is left alone so the toolbar comes back exactly as it went away.
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
        coordinator.restore()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var previousBackground: NSColor?
        private var previousTransparency: Bool?
        private var previousSeparator: NSTitlebarSeparatorStyle?

        func apply(to window: NSWindow?) {
            guard let window, window !== self.window else { return }
            restore()

            self.window = window
            previousBackground = window.backgroundColor
            previousTransparency = window.titlebarAppearsTransparent
            previousSeparator = window.titlebarSeparatorStyle

            window.backgroundColor = VaultHeroPalette.baseNSColor
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
        }

        func restore() {
            guard let window else { return }
            if let previousBackground { window.backgroundColor = previousBackground }
            if let previousTransparency { window.titlebarAppearsTransparent = previousTransparency }
            if let previousSeparator { window.titlebarSeparatorStyle = previousSeparator }
            self.window = nil
            previousBackground = nil
            previousTransparency = nil
            previousSeparator = nil
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
private struct VaultPixelGrid: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    private static let spacing: CGFloat = 13
    private static let dot: CGFloat = 2
    private static let buckets = 6

    /// Nothing repaints while the window is in the background: this view can sit on screen for
    /// hours behind a locked vault.
    private var isPaused: Bool {
        reduceMotion || controlActiveState == .inactive
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: isPaused)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                draw(in: &context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        guard size.width > 1, size.height > 1 else { return }

        let columns = Int(size.width / Self.spacing) + 2
        let rows = Int(size.height / Self.spacing) + 2

        // Follows the top-left glow, on its own slower loop so the two never quite line up.
        let centre = CGPoint(
            x: size.width * (0.24 + 0.05 * sin(time * 0.11)),
            y: size.height * (0.20 + 0.07 * cos(time * 0.09))
        )
        let reach = max(size.width, size.height) * 0.85

        var base = Path()
        var lit = [Path](repeating: Path(), count: Self.buckets)

        for row in 0..<rows {
            for column in 0..<columns {
                let x = CGFloat(column) * Self.spacing
                let y = CGFloat(row) * Self.spacing
                let rect = CGRect(x: x, y: y, width: Self.dot, height: Self.dot)

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

        context.fill(base, with: .color(.white.opacity(0.055)))
        for (index, path) in lit.enumerated() where !path.isEmpty {
            let alpha = Double(index + 1) / Double(Self.buckets) * 0.8
            context.fill(path, with: .color(VaultHeroPalette.glow.opacity(alpha)))
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
/// draws its own: a translucent well with an accent border while it holds focus.
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
                    .fill(.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: VaultRadius.value, style: .continuous)
                    .strokeBorder(
                        isFocused ? Color.vaultAccent.opacity(0.8) : .white.opacity(0.14),
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
