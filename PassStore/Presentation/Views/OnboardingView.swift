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

    private var steps: [OnboardingStep] {
        var s: [OnboardingStep] = [.welcome, .masterPassword]
        if hasBiometricHardware { s.append(.touchID) }
        s.append(contentsOf: [.workspace, .ready])
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
            Rectangle()
                .fill(.ultraThinMaterial)
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
                        WelcomeStepView(onContinue: goNext)
                            .transition(stepTransition)
                    case .masterPassword:
                        PasswordStepView(
                            password: $password,
                            confirmPassword: $confirmPassword,
                            errorMessage: errorMessage,
                            onBack: goBack,
                            onContinue: goNext
                        )
                        .transition(stepTransition)
                    case .touchID:
                        TouchIDStepView(
                            enableTouchID: $enableTouchID,
                            onBack: goBack,
                            onContinue: goNext
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
                        ReadyStepView(onComplete: onComplete)
                            .transition(stepTransition)
                    }
                }
                .frame(maxWidth: 450)
                .clipped()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
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
        isCreating = true
        errorMessage = nil

        settings.biometricsEnabled = enableTouchID
        sessionManager.createVault(password: password)

        if let error = sessionManager.lastErrorMessage {
            errorMessage = error
            isCreating = false
            return
        }

        let trimmedName = workspaceDraft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            viewModel.saveWorkspace(workspaceDraft)
        }

        isCreating = false

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
                Circle()
                    .fill(index == currentIndex ? Color.accentColor : Color.primary.opacity(0.2))
                    .frame(width: index == currentIndex ? 7 : 6, height: index == currentIndex ? 7 : 6)
                    .animation(.spring(response: 0.32, dampingFraction: 0.82), value: currentIndex)
            }
        }
    }
}

// MARK: - Welcome Step

private struct WelcomeStepView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            appIcon
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)

            VStack(spacing: 8) {
                Text("PassStore")
                    .font(.title2.weight(.semibold))
                Text("Your secrets, locked down.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Get Started", action: onContinue)
                .buttonStyle(SheetCapsuleButtonStyle(isPrimary: true))
                .accessibilityIdentifier("onboarding-get-started")

            Spacer()
                .frame(height: 16)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let nsImage = NSImage(named: NSImage.applicationIconName) {
            Image(nsImage: nsImage)
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

// MARK: - Password Step

private struct PasswordStepView: View {
    @Binding var password: String
    @Binding var confirmPassword: String
    let errorMessage: String?
    let onBack: () -> Void
    let onContinue: () -> Void

    private var passwordsMatch: Bool {
        !confirmPassword.isEmpty && password == confirmPassword
    }

    private var canContinue: Bool {
        password.count >= 8 && passwordsMatch
    }

    private var showMismatch: Bool {
        !confirmPassword.isEmpty && !passwordsMatch
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text("Create your master password")
                        .font(.title3.weight(.semibold))
                    Text("This is the only password you need to remember.\nIt protects everything in your vault.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 10) {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("onboarding-password-field")

                    SecureField("Confirm password", text: $confirmPassword)
                        .textFieldStyle(.roundedBorder)
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
}

// MARK: - Password Strength Bar

private struct PasswordStrengthBar: View {
    let password: String

    private var strength: PasswordStrength {
        PasswordStrength.evaluate(password)
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(VaultChrome.mutedFill)
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(strength.color)
                        .frame(width: geometry.size.width * strength.fill, height: 4)
                        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: strength)
                }
            }
            .frame(height: 4)

            HStack {
                Text(strength.label)
                    .font(.caption)
                    .foregroundStyle(password.isEmpty ? .tertiary : .secondary)
                Spacer()
            }
        }
    }
}

private enum PasswordStrength: Equatable {
    case empty
    case tooShort
    case weak
    case fair
    case strong
    case veryStrong

    var label: String {
        switch self {
        case .empty: "At least 8 characters"
        case .tooShort: "Too short"
        case .weak: "Weak"
        case .fair: "Fair"
        case .strong: "Strong"
        case .veryStrong: "Very strong"
        }
    }

    var color: Color {
        switch self {
        case .empty: .clear
        case .tooShort: .red
        case .weak: .orange
        case .fair: .yellow
        case .strong: .green
        case .veryStrong: .green
        }
    }

    var fill: CGFloat {
        switch self {
        case .empty: 0
        case .tooShort: 0.1
        case .weak: 0.25
        case .fair: 0.5
        case .strong: 0.75
        case .veryStrong: 1.0
        }
    }

    static func evaluate(_ password: String) -> PasswordStrength {
        guard !password.isEmpty else { return .empty }
        guard password.count >= 8 else { return .tooShort }

        let hasUpper = password.contains(where: \.isUppercase)
        let hasLower = password.contains(where: \.isLowercase)
        let hasDigit = password.contains(where: \.isNumber)
        let hasSymbol = password.contains(where: { !$0.isLetter && !$0.isNumber })
        let classes = [hasUpper, hasLower, hasDigit, hasSymbol].filter(\.self).count

        if password.count >= 20, classes >= 4 { return .veryStrong }
        if password.count >= 16, classes >= 3 { return .strong }
        if password.count >= 12 || classes >= 3 { return .fair }
        return .weak
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
                    .frame(width: 48, height: 48)

                VStack(spacing: 8) {
                    Text("Unlock with Touch ID")
                        .font(.title3.weight(.semibold))
                    Text("Use your fingerprint to unlock PassStore\ninstead of typing your master password each time.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 12) {
                    Toggle("Enable Touch ID", isOn: $enableTouchID)
                        .toggleStyle(.switch)
                        .frame(width: 300)
                        .accessibilityIdentifier("onboarding-touchid-toggle")

                    Text("You can change this later in Settings.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
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

    private var canContinue: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCreating
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Text("Create your first workspace")
                            .font(.title3.weight(.semibold))
                        Text("Workspaces help you organize secrets\nby project or team.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 8)

                    // Preview
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(hex: draft.colorHex).opacity(0.15))
                            .frame(width: 40, height: 40)
                            .overlay(
                                Image(systemName: draft.icon)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(Color(hex: draft.colorHex))
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(draft.name.isEmpty ? "Workspace" : draft.name)
                                .font(.headline)
                                .foregroundStyle(draft.name.isEmpty ? .tertiary : .primary)
                            if let preset = WorkspaceStylePresets.color(for: draft.colorHex) {
                                Text(preset.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background { GroupedSheetCardBackground(cornerRadius: 10) }

                    // Name
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("", text: $draft.name, prompt: Text("e.g. Production API"))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("onboarding-workspace-name")
                    }

                    // Icons
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Icon")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
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
                                    .foregroundStyle(isActive ? Color(hex: draft.colorHex) : .secondary)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(isActive ? Color(hex: draft.colorHex).opacity(0.12) : .clear)
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
                            .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("onboarding-skip-workspace")
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Ready Step

private struct ReadyStepView: View {
    let onComplete: () -> Void
    @State private var showCheck = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if showCheck {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }

            VStack(spacing: 8) {
                Text("You're all set")
                    .font(.title3.weight(.semibold))
                Text("Your vault is ready.\nStart adding your secrets.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button("Open PassStore", action: onComplete)
                .buttonStyle(SheetCapsuleButtonStyle(isPrimary: true))
                .accessibilityIdentifier("onboarding-open-app")

            Spacer()
                .frame(height: 16)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                showCheck = true
            }
        }
    }
}

// MARK: - Navigation Footer

private struct OnboardingNavigationFooter: View {
    let onBack: () -> Void
    let onContinue: () -> Void
    let continueDisabled: Bool

    var body: some View {
        HStack {
            Button("Back", action: onBack)
                .buttonStyle(SheetCapsuleButtonStyle(isPrimary: false))
                .accessibilityIdentifier("onboarding-back")

            Spacer()

            Button("Continue", action: onContinue)
                .buttonStyle(SheetCapsuleButtonStyle(isPrimary: true))
                .disabled(continueDisabled)
                .accessibilityIdentifier("onboarding-continue")
        }
        .padding(.top, 8)
    }
}
