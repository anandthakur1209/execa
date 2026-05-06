import SwiftUI

struct SetupWizardView: View {
    let coordinator: AppCoordinator

    @State private var step: Step = .permissions
    @State private var displayName: String = NSFullUserName()
    @State private var savedDisplayName: String?
    @State private var saveError: String?

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
            placeholder("""
            execa needs microphone and screen-recording permissions to capture meeting audio. \
            We'll ask the system for them on first recording — for now, just continue.
            """)
        case .sttKeys:
            placeholder("""
            Add your Sarvam (or Deepgram) API key on this step. Validation arrives in a later \
            phase; for now the wizard just walks you through.
            """)
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
            if let savedDisplayName {
                Text("You'll appear as \"\(savedDisplayName)\" in transcripts.")
                    .foregroundStyle(.secondary)
            }
            Text("Recording features will arrive in the next phase.")
                .font(.caption).foregroundStyle(.tertiary)
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
        case .permissions, .sttKeys, .llmKeys:
            Button("Next") { advance() }
                .keyboardShortcut(.defaultAction)
        case .displayName:
            Button("Finish") { Task { await finish() } }
                .keyboardShortcut(.defaultAction)
                .disabled(displayName.trimmingCharacters(in: .whitespaces).isEmpty)
        case .done:
            EmptyView()
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

    private func finish() async {
        let name = displayName.trimmingCharacters(in: .whitespaces)
        do {
            try await coordinator.setDisplayName(name)
            savedDisplayName = name
            step = .done
        } catch {
            saveError = String(describing: error)
        }
    }
}
