import AppKit
import Testing
@testable import PassStore

/// The window chrome a hero borrows while it is on screen.
///
/// Both cases here are bugs that shipped: a black window after setting the vault up again, and —
/// from the first attempt at fixing it — an app that drew its sidebar and its item list up
/// underneath the traffic lights for the rest of its run.
@MainActor
struct HeroWindowChromeTests {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .automatic
        return window
    }

    /// Erasing the vault takes the lock screen straight to onboarding, so for the length of the
    /// crossfade two heroes are mounted. Each used to save and restore on its own, which meant the
    /// incoming one recorded the outgoing one's black as the state to put back.
    @Test func twoOverlappingHeroesRestoreWhatWasThereBeforeTheFirstOne() {
        let window = makeWindow()
        let original = window.backgroundColor

        VaultHeroTitlebar.retain(window)
        VaultHeroTitlebar.retain(window)

        #expect(window.titlebarAppearsTransparent)
        #expect(window.backgroundColor == VaultHeroPalette.baseNSColor)

        // The outgoing hero goes away; the incoming one is still on screen.
        VaultHeroTitlebar.release(window)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.backgroundColor == VaultHeroPalette.baseNSColor)

        VaultHeroTitlebar.release(window)
        #expect(!window.titlebarAppearsTransparent)
        #expect(window.titlebarSeparatorStyle == .automatic)
        #expect(window.backgroundColor == original)
    }

    @Test func releasingMoreOftenThanRetainingLeavesTheWindowAlone() {
        let window = makeWindow()
        let original = window.backgroundColor

        VaultHeroTitlebar.retain(window)
        VaultHeroTitlebar.release(window)
        #expect(window.backgroundColor == original)

        // Nothing is counted any more, so this must not put a stale value back.
        window.backgroundColor = .systemPink
        VaultHeroTitlebar.release(window)
        #expect(window.backgroundColor == .systemPink)
    }

    /// The coordinator hands its work to the next run-loop turn, because a view has no window at
    /// the moment it is made. A call that lands after SwiftUI has torn the view down used to dress
    /// the window again with nothing left alive to undo it.
    @Test func aCallArrivingAfterTheViewIsGoneDoesNotDressTheWindowAgain() {
        let window = makeWindow()
        let original = window.backgroundColor
        let coordinator = VaultHeroWindowChrome.Coordinator()

        coordinator.apply(to: window)
        #expect(window.titlebarAppearsTransparent)

        coordinator.finish()
        #expect(!window.titlebarAppearsTransparent)
        #expect(window.backgroundColor == original)

        coordinator.apply(to: window)
        #expect(!window.titlebarAppearsTransparent)
        #expect(window.backgroundColor == original)
    }
}
