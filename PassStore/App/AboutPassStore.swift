import AppKit
import SwiftUI

/// Links that appear in the About panel and the Help menu.
enum PassStoreLinks {
    static let website = URL(string: "https://passstore.makio.app")!
    static let security = URL(string: "https://passstore.makio.app/security")!
    static let changelog = URL(string: "https://passstore.makio.app/changelog")!
    static let repository = URL(string: "https://github.com/ilmakio/PassStore")!
    static let contributing = URL(string: "https://github.com/ilmakio/PassStore/blob/main/CONTRIBUTING.md")!
    static let issues = URL(string: "https://github.com/ilmakio/PassStore/issues")!
    static let author = URL(string: "https://makio.app")!
    static let donate = URL(string: "https://ko-fi.com/ilmakio")!
    static let feedback = URL(string: "mailto:feedback@makio.app")!

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// The About window: authorship, version and project links, on the app's own backdrop.
///
/// The standard AppKit panel could only take a block of attributed credits, which meant the one
/// screen that says who made this and where the source lives looked like every other app's.
@MainActor
enum AboutPassStore {
    private static var window: NSWindow?

    static func show() {
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            window.center()
            return
        }

        let controller = NSHostingController(rootView: AboutPassStoreView())
        let panel = NSWindow(contentViewController: controller)
        panel.title = "About PassStore"
        panel.styleMask = [.titled, .closable, .fullSizeContentView]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.backgroundColor = VaultHeroPalette.baseNSColor
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.setContentSize(NSSize(width: 420, height: 540))
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        window = panel
    }
}

// MARK: - View

private struct AboutPassStoreView: View {
    private static let links: [(label: String, systemImage: String, url: URL)] = [
        ("GitHub", "chevron.left.forwardslash.chevron.right", PassStoreLinks.repository),
        ("Contribute", "hammer", PassStoreLinks.contributing),
        ("Report an issue", "exclamationmark.bubble", PassStoreLinks.issues),
        ("makio.app", "person.crop.circle", PassStoreLinks.author)
    ]

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        ZStack {
            VaultHeroBackground()

            VStack(spacing: 0) {
                Spacer(minLength: VaultSpacing.xl)

                VaultHeroLogo(size: 88)

                Text("PassStore")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, VaultSpacing.l)

                Text(version)
                    .font(.vaultValueSmall)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, VaultSpacing.xs)
                    .textSelection(.enabled)

                VStack(spacing: VaultSpacing.xs) {
                    Text("Designed and developed by Makio.")
                        .foregroundStyle(.white.opacity(0.75))
                    Text("Free and open source, under the MIT licence.")
                        .foregroundStyle(.white.opacity(0.5))
                    Text("Your secrets never leave this Mac.")
                        .foregroundStyle(.white.opacity(0.5))
                }
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.top, VaultSpacing.xl)

                VStack(spacing: VaultSpacing.s) {
                    ForEach(Self.links, id: \.label) { link in
                        AboutLinkRow(label: link.label, systemImage: link.systemImage, url: link.url)
                    }
                }
                .frame(width: 260)
                .padding(.top, VaultSpacing.xxl)

                Spacer(minLength: VaultSpacing.xl)
            }
            .padding(.horizontal, VaultSpacing.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .vaultHeroContent()
        }
        .frame(minWidth: 420, minHeight: 540)
    }
}

private struct AboutLinkRow: View {
    let label: String
    let systemImage: String
    let url: URL

    @State private var isHovering = false

    var body: some View {
        Button { PassStoreLinks.open(url) } label: {
            HStack(spacing: VaultSpacing.s) {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(Color.vaultAccent)
                    .frame(width: 16)
                    .accessibilityHidden(true)

                Text(label)
                    .font(.callout)
                    .foregroundStyle(.white)

                Spacer(minLength: VaultSpacing.s)

                Image(systemName: "arrow.up.right")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(isHovering ? 0.7 : 0.3))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, VaultSpacing.m)
            .padding(.vertical, VaultSpacing.s)
            .background(
                RoundedRectangle(cornerRadius: VaultRadius.value, style: .continuous)
                    .fill(isHovering ? VaultHeroPalette.surfaceActive : VaultHeroPalette.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: VaultRadius.value, style: .continuous)
                    .strokeBorder(isHovering ? VaultHeroPalette.strokeStrong : VaultHeroPalette.stroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: VaultRadius.value, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityLabel("\(label), opens in your browser")
    }
}
