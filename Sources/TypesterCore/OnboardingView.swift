import TypesterCore
import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var apiKeyInput = ""
    @State private var currentStep = 1
    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @FocusState private var isApiKeyFocused: Bool

    var onComplete: () -> Void

    private var canContinue: Bool {
        switch currentStep {
        case 1: return !apiKeyInput.isEmpty
        case 2: return micGranted
        case 3: return accessibilityGranted
        default: return true
        }
    }

    private var hasApiKey: Bool {
        switch settings.sttProvider {
        case .soniox: return settings.apiKey != nil
        case .deepgram: return settings.deepgramApiKey != nil
        case .openai: return settings.openaiApiKey != nil
        }
    }

    private var apiKeyLink: (String, URL) {
        switch settings.sttProvider {
        case .deepgram:
            return ("Get key", URL(string: "https://console.deepgram.com")!)
        case .openai:
            return ("Get key", URL(string: "https://platform.openai.com/api-keys")!)
        case .soniox:
            return ("Get key", URL(string: "https://soniox.com")!)
        }
    }

    private var permissionsComplete: Bool {
        hasApiKey && micGranted && accessibilityGranted
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(Color(hex: 0x26272C))
                .frame(height: 1)

            VStack(spacing: 0) {
                stepView(
                    number: 1,
                    title: "Enter your API key",
                    titleLink: apiKeyLink,
                    description: "You pay the provider directly for usage — no middleman, no subscription.",
                    isActive: currentStep == 1,
                    isComplete: hasApiKey
                ) {
                    providerAndApiKeyContent
                }

                stepDivider

                stepView(
                    number: 2,
                    title: "Grant microphone access",
                    description: "Typester needs to hear you speak to transcribe your voice to text.",
                    isActive: currentStep == 2,
                    isComplete: micGranted
                ) {
                    microphoneStepContent
                }

                stepDivider

                stepView(
                    number: 3,
                    title: "Grant accessibility access",
                    description: "Typester needs this to type text into other apps by simulating keyboard input.",
                    isActive: currentStep == 3,
                    isComplete: accessibilityGranted
                ) {
                    accessibilityStepContent
                }
            }
            .padding(.vertical, 6)

            if permissionsComplete {
                Rectangle()
                    .fill(Codex.hairline)
                    .frame(height: 1)

                readyView
            }

            Spacer(minLength: 0)

            Rectangle()
                .fill(Codex.hairline)
                .frame(height: 1)

            footer
        }
        .background(Codex.background)
        .tint(Codex.green)
        .frame(width: 540)
        .frame(height: permissionsComplete ? 632 : 592)
        .onAppear {
            checkPermissions()
            loadApiKeyForProvider()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isApiKeyFocused = true
            }
        }
        .onChange(of: settings.sttProvider) { _ in
            loadApiKeyForProvider()
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            checkPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkPermissions()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 11)
                    .fill(Color(hex: 0x26272C))
                    .frame(width: 46, height: 46)
                    .overlay(
                        HairlineBorder(cornerRadius: 11, color: Color(hex: 0x33363D))
                    )

                Image(systemName: "waveform")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Codex.mist)
                    .frame(width: 46, height: 46)

                Circle()
                    .fill(Codex.green)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Codex.charcoal, lineWidth: 2.5))
                    .offset(x: 3, y: 3)
            }

            Text("Welcome to Typester")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(Codex.mist)

            Text("Dictate text anywhere on your Mac")
                .font(.system(size: 13))
                .foregroundStyle(Codex.steel)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 34)
        .padding(.bottom, 24)
        .background(Codex.charcoal)
    }

    // MARK: Steps

    private var stepDivider: some View {
        Rectangle()
            .fill(Codex.hairline)
            .frame(height: 1)
            .padding(.leading, 70)
    }

    @ViewBuilder
    private func stepView<Content: View>(
        number: Int,
        title: String,
        titleLink: (String, URL)? = nil,
        description: String,
        isActive: Bool,
        isComplete: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            stepIndicator(number: number, isActive: isActive, isComplete: isComplete)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: 13.5, weight: isActive || isComplete ? .semibold : .semibold))
                        .foregroundStyle(isActive || isComplete ? Codex.text : Codex.textSecondary)

                    if let (linkText, linkURL) = titleLink {
                        Spacer()
                        Link(linkText, destination: linkURL)
                            .font(.system(size: 12))
                            .foregroundStyle(Codex.azure)
                    }
                }

                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(Codex.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if isActive && !isComplete {
                    content()
                        .padding(.top, 8)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .onTapGesture {
            if number <= currentStep || (number == currentStep + 1 && canContinue) {
                withAnimation { currentStep = number }
            }
        }
    }

    private func stepIndicator(number: Int, isActive: Bool, isComplete: Bool) -> some View {
        ZStack {
            if isComplete {
                HairlineBorder(cornerRadius: 8, color: Codex.green, lineWidth: 1.3)

                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Codex.green)
            } else if isActive {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Codex.charcoal)

                Text(String(format: "%02d", number))
                    .font(.mono(11, .semibold))
                    .foregroundStyle(Codex.mist)
            } else {
                HairlineBorder(cornerRadius: 8)

                Text(String(format: "%02d", number))
                    .font(.mono(11, .semibold))
                    .foregroundStyle(Codex.textTertiary)
            }
        }
        .frame(width: 30, height: 30)
        .animation(.easeOut(duration: 0.15), value: isComplete)
    }

    // MARK: Ready

    @ViewBuilder
    private var readyView: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Codex.green.opacity(0.12))

                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Codex.green)
            }
            .frame(width: 30, height: 30)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 6) {
                Text("You're all set")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Codex.text)

                HStack(spacing: 6) {
                    Text("Hold")
                    KeyToken(text: "fn")
                    Text("and speak — your words appear wherever your cursor is. Release to paste.")
                }
                .font(.system(size: 12))
                .foregroundStyle(Codex.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Spacer()

            if permissionsComplete {
                Button("Start using Typester") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else if canContinue && currentStep < 3 {
                Button("Continue") {
                    if currentStep == 1 && !apiKeyInput.isEmpty {
                        switch settings.sttProvider {
                        case .soniox:
                            settings.apiKey = apiKeyInput
                        case .deepgram:
                            settings.deepgramApiKey = apiKeyInput
                        case .openai:
                            settings.openaiApiKey = apiKeyInput
                        }
                    }
                    withAnimation { currentStep += 1 }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(20)
    }

    // MARK: Step content

    @ViewBuilder
    private var providerAndApiKeyContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            CodexSegmented(
                options: STTProviderType.allCases.map {
                    (label: $0.displayName, value: $0)
                },
                selection: $settings.sttProvider
            )

            SecureField("Paste your API key", text: $apiKeyInput)
                .textFieldStyle(.plain)
                .font(.mono(12.5))
                .fieldCard()
                .focused($isApiKeyFocused)

            if settings.sttProvider == .openai {
                Picker("Model", selection: $settings.openaiModel) {
                    ForEach(OpenAITranscribeModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            } else if settings.sttProvider == .soniox {
                Picker("Mode", selection: $settings.sonioxMode) {
                    ForEach(SonioxTranscribeMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    @ViewBuilder
    private var microphoneStepContent: some View {
        Button("Request microphone access") {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    micGranted = granted
                    if granted && currentStep == 2 {
                        withAnimation { currentStep = 3 }
                    }
                }
            }
        }
        .controlSize(.regular)
    }

    @ViewBuilder
    private var accessibilityStepContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button("Open System Settings") {
                    TextPaster.openAccessibilitySettings()
                }

                Button("Relaunch") {
                    TextPaster.relaunchApp()
                }
                .buttonStyle(.borderedProminent)
            }

            Text("Enable Typester in the list. If it was already on after an update, remove it, add /Applications/Typester.app again, enable it, then Relaunch.")
                .font(.system(size: 11.5))
                .foregroundStyle(Codex.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Helpers

    private func loadApiKeyForProvider() {
        switch settings.sttProvider {
        case .soniox:
            apiKeyInput = settings.apiKey ?? ""
        case .deepgram:
            apiKeyInput = settings.deepgramApiKey ?? ""
        case .openai:
            apiKeyInput = settings.openaiApiKey ?? ""
        }
    }

    private func checkPermissions() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        micGranted = status == .authorized
        accessibilityGranted = TextPaster.checkAccessibilityPermission()
    }
}
