import AppKit

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

/// The standard macOS About panel, with authorship and project links in its credits.
@MainActor
enum AboutPassStore {
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private static var credits: NSAttributedString {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        centred.paragraphSpacing = 8

        let result = NSMutableAttributedString()

        result.append(NSAttributedString(
            string: "A local-first secret manager for developers.\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: centred
            ]
        ))

        result.append(NSAttributedString(
            string: "Designed and developed by Makio.\nFree and open source, under the MIT licence.\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: centred
            ]
        ))

        let links: [(String, URL)] = [
            ("GitHub", PassStoreLinks.repository),
            ("Contribute", PassStoreLinks.contributing),
            ("makio.app", PassStoreLinks.author)
        ]
        for (index, link) in links.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(
                    string: "   ·   ",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                        .foregroundColor: NSColor.tertiaryLabelColor,
                        .paragraphStyle: centred
                    ]
                ))
            }
            result.append(NSAttributedString(
                string: link.0,
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .link: link.1,
                    .paragraphStyle: centred
                ]
            ))
        }

        return result
    }
}
