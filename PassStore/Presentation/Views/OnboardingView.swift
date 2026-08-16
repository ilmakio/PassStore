import LocalAuthentication
import SwiftUI

// MARK: - Onboarding Step

private enum OnboardingStep: Int, CaseIterable {
    case welcome
    case masterPassword
    case touchID
    case workspace
    case ready
}

// MARK: - OnboardingView

struct OnboardingView: View {
    let sessionManager: VaultSessionManager
    let settings: AppSettingsStore
    let viewModel: VaultViewModel
    let onComplete: () -> Void

    @State private var currentStep: OnboardingStep = .welcome
    @State private var previousStep: OnboardingStep = .welcome
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var enableTouchID = true
    @State private var workspaceDraft = WorkspaceDraft.empty
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var hasBiometricHardware = false
    /// Set from the welcome step. A restore still needs a master password and a vault to
    /// restore into, so the flow is unchanged — it just opens the import sheet at the end
    /// instead of leaving a new arrival to find it in a menu.
    @State private var wantsBackupRestore = false

    private var steps: [OnboardingStep] {
        var s: [OnboardingStep] = [.welcome, .masterPassword]
        if hasBiometricHardware { s.append(.touchID) }
        // Restoring brings its own workspaces, and "You're all set" is a lie until the backup
        // has actually been chosen. Both steps are dropped and the picker opens straight away.
        if !wantsBackupRestore {
            s.append(.workspace)
            s.append(.ready)
        }
        return s
    }

    private var currentIndex: Int {
        steps.firstIndex(of: currentStep) ?? 0
    }

    private var isForward: Bool {
        currentStep.rawValue >= previousStep.rawValue
    }

    var body: some View {
        ZStack {
            VaultHeroBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if currentStep != .welcome && currentStep != .ready {
                    OnboardingStepIndicator(
                        totalSteps: steps.count,
                        currentIndex: currentIndex
                    )
                    .padding(.top, 28)
                    .padding(.bottom, 8)
                }

                ZStack {
                    switch currentStep {
                    case .welcome:
                        WelcomeStepView(onContinue: goNext, onRestore: {
                            wantsBackupRestore = true
                            goNext()
                        })
                            .transition(stepTransition)
                    case .masterPassword:
                        PasswordStepView(
                            password: $password,
                            confirmPassword: $confirmPassword,
                            errorMessage: errorMessage,
                            onBack: goBack,
                            onContinue: advance
                        )
                        .transition(stepTransition)
                    case .touchID:
                        TouchIDStepView(
                            enableTouchID: $enableTouchID,
                            onBack: goBack,
                            onContinue: advance
                        )
                        .transition(stepTransition)
                    case .workspace:
                        WorkspaceStepView(
                            draft: $workspaceDraft,
                            isCreating: isCreating,
                            errorMessage: errorMessage,
                            onBack: goBack,
                            onContinue: completeOnboarding,
                            onSkip: { workspaceDraft.name = ""; completeOnboarding() }
                        )
                        .transition(stepTransition)
                    case .ready:
                        ReadyStepView(wantsBackupRestore: wantsBackupRestore) {
                            if wantsBackupRestore {
                                viewModel.activeSheet = .importEncryptedExport
                            }
                            onComplete()
                        }
                        .transition(stepTransition)
                    }
                }
                .frame(maxWidth: 450)
                .clipped()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
            // Setup runs on the hero end to end. The backdrop is fixed dark in both
            // appearances, so its content resolves against a dark scheme and uses opaque
            // fills rather than inheriting the window's and dissolving into the animation.
            .vaultHeroContent()
        }
        .onAppear {
            let context = LAContext()
            hasBiometricHardware = context.canEvaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics, error: nil
            )
        }
    }

    // MARK: - Navigation

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: isForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: isForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    /// Moves on, creating the vault when the next stop is the final screen.
    ///
    /// Vault creation used to live only in the workspace step's continue action, so skipping
    /// that step would have walked to "You're all set" without ever making a vault.
    private func advance() {
        guard let idx = steps.firstIndex(of: currentStep) else { return }
        let isFinalStep = idx + 1 >= steps.count
        if isFinalStep || steps[idx + 1] == .ready {
            completeOnboarding()
        } else {
            goNext()
        }
    }

    private func goNext() {
        guard let idx = steps.firstIndex(of: currentStep), idx + 1 < steps.count else { return }
        errorMessage = nil
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            previousStep = currentStep
            currentStep = steps[idx + 1]
        }
    }

    private func goBack() {
        guard let idx = steps.firstIndex(of: currentStep), idx > 0 else { return }
        errorMessage = nil
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            previousStep = currentStep
            currentStep = steps[idx - 1]
        }
    }

    // MARK: - Vault Creation

    private func completeOnboarding() {
        Task { await createVault() }
    }

    private func createVault() async {
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        settings.biometricsEnabled = enableTouchID
        // Key derivation runs off the main actor, so the step stays responsive and the
        // "Creating your vault…" state is actually visible rather than a frozen window.
        await sessionManager.createVault(password: password)

        guard sessionManager.lockState == .unlocked else {
            errorMessage = sessionManager.lastErrorMessage
                ?? "Vault creation was interrupted. Try again."
            return
        }

        let trimmedName = workspaceDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            viewModel.saveWorkspace(workspaceDraft)
        }

        // Restoring goes straight to the file picker: the vault exists but is empty, and
        // congratulating somebody before they have chosen their backup is premature.
        if wantsBackupRestore {
            viewModel.activeSheet = .importEncryptedExport
            onComplete()
            return
        }

        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            previousStep = currentStep
            currentStep = .ready
        }
    }
}

// MARK: - Step Indicator

private struct OnboardingStepIndicator: View {
    let totalSteps: Int
    let currentIndex: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<totalSteps, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index == currentIndex ? Color.vaultAccent : VaultHeroPalette.surfaceActive)
                    .frame(width: index == currentIndex ? 20 : 6, height: 6)
                    .animation(.spring(response: 0.32, dampingFraction: 0.82), value: currentIndex)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(currentIndex + 1) of \(totalSteps)")
    }
}

// MARK: - Welcome Step

private struct WelcomeStepView: View {
    let onContinue: () -> Void
    let onRestore: () -> Void

    var body: some View {
        // One centred block — logo, wordmark, choice — rather than three groups pushed apart
        // by spacers, which left a hole in the middle of the screen.
        VStack(spacing: 0) {
            Spacer(minLength: VaultSpacing.xl)

            VaultHeroLogo(size: 108)

            VaultHeroWordmark(tagline: "Developer secrets that never leave your Mac.")
                .padding(.top, VaultSpacing.xxl)

            VStack(spacing: VaultSpacing.m) {
                Button("Get Started", action: onContinue)
                    .buttonStyle(VaultButtonStyle(.primary))
                    .controlSize(.large)
                    .accessibilityIdentifier("onboarding-get-started")

                // A real button, not a link: restoring a backup is the other half of the
                // decision on this screen, not a footnote to it.
                Button("I already have a backup", action: onRestore)
                    .buttonStyle(VaultButtonStyle(.secondary))
                    .accessibilityIdentifier("onboarding-restore-backup")
            }
            .padding(.top, 38)

            Spacer(minLength: VaultSpacing.xl)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Password Step

private struct PasswordStepView: View {
    @Binding var password: String
    @Binding var confirmPassword: String
    let errorMessage: String?
    let onBack: () -> Void
    let onContinue: () -> Void

    @FocusState private var isConfirmFocused: Bool
    @FocusState private var isPasswordFocused: Bool
    @State private var hasVisitedConfirmField = false

    private var passwordsMatch: Bool {
        !confirmPassword.isEmpty && password == confirmPassword
    }

    private var canContinue: Bool {
        password.count >= 8 && passwordsMatch
    }

    /// Only once the confirmation field has been left alone.
    ///
    /// Judging every keystroke meant "Passwords don't match" appeared on the first character
    /// and stayed there while you typed the rest, which is scolding somebody for not having
    /// finished yet.
    private var showMismatch: Bool {
        hasVisitedConfirmField && !isConfirmFocused && !confirmPassword.isEmpty && !passwordsMatch
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                OnboardingStepHeading(
                    title: "Create your master password",
                    subtitle: "This is the only password you need to remember.\nIt protects everything in your vault."
                )

                VStack(spacing: 10) {
                    SecureField("", text: $password, prompt: Text("Password"))
                        .vaultHeroField(isFocused: isPasswordFocused)
                        .focused($isPasswordFocused)
                        .onSubmit(submitIfReady)
                        .accessibilityLabel("Password")
                        .accessibilityIdentifier("onboarding-password-field")

                    SecureField("", text: $confirmPassword, prompt: Text("Confirm password"))
                        .vaultHeroField(isFocused: isConfirmFocused)
                        .focused($isConfirmFocused)
                        .onSubmit(submitIfReady)
                        .onChange(of: isConfirmFocused) { _, focused in
                            if focused { hasVisitedConfirmField = true }
                        }
                        .accessibilityLabel("Confirm password")
                        .accessibilityIdentifier("onboarding-confirm-field")
                }
                .frame(width: 300)

                VStack(spacing: 8) {
                    PasswordStrengthBar(password: password)
                        .frame(width: 300)

                    if showMismatch {
                        Text("Passwords don't match")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .transition(.opacity)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .transition(.opacity)
                    }
                }
            }

            Spacer()

            OnboardingNavigationFooter(
                onBack: onBack,
                onContinue: onContinue,
                continueDisabled: !canContinue
            )
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.15), value: showMismatch)
    }

    private func submitIfReady() {
        guard canContinue else { return }
        onContinue()
    }
}

// MARK: - Touch ID Step

private struct TouchIDStepView: View {
    @Binding var enableTouchID: Bool
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                Image("touch_id")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 52, height: 52)

                OnboardingStepHeading(
                    title: "Unlock with Touch ID",
                    subtitle: "Use your fingerprint to unlock PassStore\ninstead of typing your master password each time."
                )

                VStack(spacing: 12) {
                    VaultHeroCard(padding: VaultSpacing.m) {
                        Toggle("Enable Touch ID", isOn: $enableTouchID)
                            .toggleStyle(.switch)
                            .tint(.vaultAccent)
                            .accessibilityIdentifier("onboarding-touchid-toggle")
                    }
                    .frame(width: 300)

                    Text("You can change this later in Settings.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }

            Spacer()

            OnboardingNavigationFooter(
                onBack: onBack,
                onContinue: onContinue,
                continueDisabled: false
            )
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Workspace Step

private struct WorkspaceStepView: View {
    @Binding var draft: WorkspaceDraft
    let isCreating: Bool
    let errorMessage: String?
    let onBack: () -> Void
    let onContinue: () -> Void
    let onSkip: () -> Void

    @FocusState private var isNameFocused: Bool

    private var canContinue: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCreating
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    OnboardingStepHeading(
                        title: "Create your first workspace",
                        subtitle: "Workspaces help you organize secrets\nby project or team."
                    )
                    .padding(.top, 8)

                    // Preview
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(hex: draft.colorHex).opacity(0.18))
                            .frame(width: 40, height: 40)
                            .overlay(
                                Image(systemName: draft.icon)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(Color(hex: draft.colorHex))
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(draft.name.isEmpty ? "Workspace" : draft.name)
                                .font(.headline)
                                .foregroundStyle(draft.name.isEmpty ? .white.opacity(0.35) : .white)
                            if let preset = WorkspaceStylePresets.color(for: draft.colorHex) {
                                Text(preset.name)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: VaultRadius.value, style: .continuous)
                            .fill(VaultHeroPalette.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: VaultRadius.value, style: .continuous)
                            .strokeBorder(VaultHeroPalette.stroke, lineWidth: 1)
                    )

                    // Name
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.6))
                        TextField("", text: $draft.name, prompt: Text("e.g. Production API"))
                            .vaultHeroField(isFocused: isNameFocused)
                            .focused($isNameFocused)
                            .onSubmit { if canContinue { onContinue() } }
                            .accessibilityLabel("Workspace name")
                            .accessibilityIdentifier("onboarding-workspace-name")
                    }

                    // Icons
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Icon")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.6))
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5),
                            spacing: 6
                        ) {
                            ForEach(WorkspaceStylePresets.icons) { preset in
                                let isActive = draft.icon == preset.systemImage
                                Button { draft.icon = preset.systemImage } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: preset.systemImage)
                                            .font(.system(size: 14, weight: .medium))
                                        Text(preset.label)
                                            .font(.caption2)
                                            .lineLimit(1)
                                    }
                                    .foregroundStyle(isActive ? Color(hex: draft.colorHex) : .white.opacity(0.55))
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(isActive ? Color(hex: draft.colorHex).opacity(0.16) : VaultHeroPalette.surface)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(
                                                isActive ? Color(hex: draft.colorHex).opacity(0.55) : VaultHeroPalette.stroke,
                                                lineWidth: 1
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // Colors
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Color")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.6))
                        HStack(spacing: 8) {
                            ForEach(WorkspaceStylePresets.colors) { preset in
                                Button { draft.colorHex = preset.hex } label: {
                                    Circle()
                                        .fill(preset.color)
                                        .frame(width: 24, height: 24)
                                        .overlay(
                                            Circle()
                                                .strokeBorder(Color.white, lineWidth: 2)
                                                .opacity(draft.colorHex.caseInsensitiveCompare(preset.hex) == .orderedSame ? 1 : 0)
                                        )
                                        .overlay(
                                            Circle()
                                                .strokeBorder(preset.color.opacity(0.5), lineWidth: 1)
                                                .opacity(draft.colorHex.caseInsensitiveCompare(preset.hex) == .orderedSame ? 1 : 0)
                                                .scaleEffect(1.25)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.hidden)

            VStack(spacing: 8) {
                OnboardingNavigationFooter(
                    onBack: onBack,
                    onContinue: onContinue,
                    continueDisabled: !canContinue
                )

                Button("Skip", action: onSkip)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .accessibilityIdentifier("onboarding-skip-workspace")
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Ready Step

private struct ReadyStepView: View {
    var wantsBackupRestore = false
    let onComplete: () -> Void
    @State private var showCheck = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: VaultSpacing.xl)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.black, Color.vaultAccent)
                .scaleEffect(showCheck ? 1 : 0.5)
                .opacity(showCheck ? 1 : 0)

            OnboardingStepHeading(
                title: "You're all set",
                subtitle: wantsBackupRestore
                    ? "Your vault is ready.\nNext, choose the .pstore backup to restore."
                    : "Your vault is ready.\nStart adding your secrets."
            )
            .padding(.top, VaultSpacing.xxl)

            Button(wantsBackupRestore ? "Choose Backup…" : "Open PassStore", action: onComplete)
                .buttonStyle(VaultButtonStyle(.primary))
                .controlSize(.large)
                .padding(.top, 38)
                .accessibilityIdentifier("onboarding-open-app")

            Spacer(minLength: VaultSpacing.xl)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                showCheck = true
            }
        }
    }
}

// MARK: - Shared pieces

/// Title and supporting copy, identical on every step so the eye stops in the same place.
private struct OnboardingStepHeading: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: VaultSpacing.s) {
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OnboardingNavigationFooter: View {
    let onBack: () -> Void
    let onContinue: () -> Void
    let continueDisabled: Bool

    var body: some View {
        HStack {
            Button("Back", action: onBack)
                .buttonStyle(VaultButtonStyle(.secondary))
                .accessibilityIdentifier("onboarding-back")

            Spacer()

            Button("Continue", action: onContinue)
                .buttonStyle(VaultButtonStyle(.primary))
                .disabled(continueDisabled)
                .accessibilityIdentifier("onboarding-continue")
        }
        .padding(.top, 8)
    }
}
