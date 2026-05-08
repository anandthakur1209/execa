import SwiftUI

/// Wizard step for entering the Sarvam API key. Saves to Keychain at
/// `service: "com.anandthakur.execa.sarvam"`, `account: "default"` — the
/// same `(service, account)` pair `AppCoordinator.startMeeting()`'s
/// missing-key gate reads.
///
/// **No live validation** in Phase 2. If the key the user types is bad,
/// the WebSocket upgrade fails on the first meeting and `LiveMeetingView`
/// shows the "Reconnecting…" → "Transcription stopped" path
/// (commit 8). Real test calls land in Phase 7's `KeyValidators.swift`.
///
/// Skipping the step is allowed (the wizard's Back/Next don't block on
/// presence) — but `startMeeting()` will refuse to start without a key.
struct SetupWizardSttKeyStep: View {
    let coordinator: AppCoordinator

    @State private var enteredKey: String = ""
    @State private var savedKeyMask: String?
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste your Sarvam API key. We'll store it in your Mac's Keychain — never on disk, never logged.")
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Sarvam API key", text: $enteredKey)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await save() } }

            HStack(spacing: 8) {
                Button("Save key") { Task { await save() } }
                    .disabled(enteredKey.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                if let savedKeyMask {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Saved: \(savedKeyMask)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.red)
            }

            Text(
                """
                Don't have one? Sign up at sarvam.ai. You can also skip this step and add the key later — \
                Start Meeting will refuse to record without one.
                """
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            // If a key is already stored (e.g. from a prior wizard run or
            // a `security add-generic-password` invocation), show the
            // masked confirmation immediately.
            await loadExistingKeyMask()
        }
    }

    private func save() async {
        let trimmed = enteredKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try coordinator.keychain.set(
                trimmed,
                service: KeychainStore.serviceName(forProvider: "sarvam"),
                account: "default"
            )
            savedKeyMask = Self.mask(trimmed)
            saveError = nil
            // Don't clear the SecureField — let the user verify what they
            // just typed. The mask appears alongside as a "saved" marker.
        } catch {
            saveError = "Couldn't save key: \(error.localizedDescription)"
        }
    }

    private func loadExistingKeyMask() async {
        do {
            let stored = try coordinator.keychain.get(
                service: KeychainStore.serviceName(forProvider: "sarvam"),
                account: "default"
            )
            if let stored, !stored.isEmpty {
                savedKeyMask = Self.mask(stored)
            }
        } catch {
            // No-op: a missing entry is the common first-run case.
        }
    }

    /// Show first 4 + last 2 chars; the middle is asterisks. For a
    /// 36-char Sarvam key this looks like `abcd…**…xy`.
    static func mask(_ key: String) -> String {
        guard key.count > 8 else {
            return String(repeating: "•", count: key.count)
        }
        let prefix = key.prefix(4)
        let suffix = key.suffix(2)
        let middleCount = key.count - 6
        return "\(prefix)" + String(repeating: "•", count: min(middleCount, 8)) + "\(suffix)"
    }
}
