import AVFoundation
import SwiftUI

struct SetupWizardView: View {
    let coordinator: AppCoordinator
    var onComplete: (() -> Void)?

    @State private var step: Step = .permissions
    @State private var displayName: String = NSFullUserName()
    @State private var saveError: String?
    @State private var micStatus: AVAuthorizationStatus = .notDetermined
    @State private var screenStatus: Bool = false

    enum Step: Int, CaseIterable {
        case permissions, sttKeys, llmKeys, displayName, done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .task {
            if let saved = try? await coordinator.currentDisplayName(), !saved.isEmpty {
                displayName = saved
            }
            await refreshPermissionStatus()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("execa setup").font(.title2).bold()
            Text(stepLabel).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var stepLabel: String {
        switch step {
        case .permissions: "Step 1 of 4 — Permissions"
        case .sttKeys: "Step 2 of 4 — Speech-to-text keys"
        case .llmKeys: "Step 3 of 4 — LLM keys"
        case .displayName: "Step 4 of 4 — Your display name"
        case .done: "All set"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .permissions:
            permissionsStep
        case .sttKeys:
            SetupWizardSttKeyStep(coordinator: coordinator)
        case .llmKeys:
            placeholder("Add your Anthropic (or OpenAI / Gemini) API key. Validation arrives later.")
        case .displayName:
            displayNameStep
        case .done:
            doneStep
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text).fixedSize(horizontal: false, vertical: true)
            Text("(placeholder — wired up in a later phase)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("execa needs two macOS permissions to record meetings.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: micStatus == .authorized ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(micStatus == .authorized ? .green : .secondary)
                Text("Microphone")
                Spacer()
                if micStatus != .authorized {
                    Button("Request") {
                        Task { await requestMic() }
                    }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: screenStatus ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(screenStatus ? .green : .secondary)
                Text("Screen Recording")
                    .help("Used only to capture system audio from meeting apps. Screen contents are never recorded.")
                Spacer()
                if !screenStatus {
                    Button("Open Settings…") {
                        Task {
                            coordinator.permissions.openScreenRecordingSettings()
                            await refreshPermissionStatus()
                        }
                    }
                }
            }
            Button("Refresh status") {
                Task { await refreshPermissionStatus() }
            }
            .buttonStyle(.link)
        }
    }

    private var displayNameStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How should the transcript label you when you speak?")
            TextField("Display name", text: $displayName)
                .textFieldStyle(.roundedBorder)
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Setup is done.").bold()
            Text("Look for the execa icon in your menu bar to start a meeting.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "headphones")
                    .foregroundStyle(.secondary)
                Text(
                    """
                    **For best results, use headphones during meetings.** Speaker output \
                    bleeds into the mic and produces duplicate transcript entries.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
        }
    }

    private var footer: some View {
        HStack {
            if step.rawValue > Step.permissions.rawValue, step != .done {
                Button("Back") { goBack() }
            }
            Spacer()
            primaryButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .permissions:
            Button("Next") { advance() }
                .keyboardShortcut(.defaultAction)
                .disabled(micStatus != .authorized || !screenStatus)
        case .sttKeys, .llmKeys:
            Button("Next") { advance() }
                .keyboardShortcut(.defaultAction)
        case .displayName:
            Button("Finish") { Task { await finish() } }
                .keyboardShortcut(.defaultAction)
                .disabled(displayName.trimmingCharacters(in: .whitespaces).isEmpty)
        case .done:
            Button("Close") { onComplete?() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private func requestMic() async {
        _ = await coordinator.permissions.requestMicrophone()
        await refreshPermissionStatus()
    }

    private func refreshPermissionStatus() async {
        micStatus = await coordinator.permissions.microphoneStatus()
        screenStatus = coordinator.permissions.screenRecordingStatus()
    }

    private func finish() async {
        let name = displayName.trimmingCharacters(in: .whitespaces)
        do {
            try await coordinator.setDisplayName(name)
            try await coordinator.markFirstRunComplete()
            step = .done
        } catch {
            saveError = String(describing: error)
        }
    }
}
