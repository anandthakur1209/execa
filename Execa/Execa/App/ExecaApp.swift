import AppKit
import SwiftUI

@main
struct ExecaApp: App {
    @State private var coordinator: AppCoordinator?
    @State private var initError: String?
    @State private var firstRunComplete: Bool = false
    @State private var meetingState: MeetingState = .idle
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some Scene {
        WindowGroup(id: "execa-setup") {
            RootView(
                coordinator: coordinator,
                initError: initError,
                firstRunComplete: firstRunComplete,
                onWizardComplete: {
                    firstRunComplete = true
                    dismissWindow(id: "execa-setup")
                }
            )
            .frame(minWidth: 520, minHeight: 360)
            .task {
                guard coordinator == nil, initError == nil else { return }
                do {
                    let coord = try await AppCoordinator()
                    coordinator = coord
                    firstRunComplete = await (try? coord.isFirstRunComplete()) ?? false
                    Task { await observeMeetingState(coord) }
                } catch {
                    initError = String(describing: error)
                }
            }
        }

        WindowGroup(id: "execa-live-meeting") {
            if let coordinator {
                LiveMeetingView(
                    coordinator: coordinator,
                    store: coordinator.transcriptStore,
                    meetingState: meetingState
                )
            } else {
                ProgressView("Starting execa…").padding()
            }
        }

        WindowGroup(id: "execa-meeting-detail", for: String.self) { $meetingID in
            if let coordinator, let id = meetingID {
                MeetingDetailView(coordinator: coordinator, meetingID: id)
            } else {
                ProgressView("Starting execa…").padding()
            }
        }

        MenuBarExtra {
            if let coordinator {
                MenuBarMenu(
                    state: meetingState,
                    lastEndedMeetingID: coordinator.audioCapture.lastEndedMeetingID,
                    onStart: { Task { try? await coordinator.startMeeting() } },
                    onStop: { Task { try? await coordinator.stopMeeting() } },
                    onOpenScreenSettings: {
                        Task { coordinator.permissions.openScreenRecordingSettings() }
                    },
                    onOpenMicSettings: {
                        Task { coordinator.permissions.openMicrophoneSettings() }
                    },
                    onShowLiveWindow: {
                        openWindow(id: "execa-live-meeting")
                    },
                    onOpenLastMeeting: { meetingID in
                        openWindow(id: "execa-meeting-detail", value: meetingID)
                    },
                    onDismissError: {
                        Task { await coordinator.dismissError() }
                    }
                )
            } else {
                Text("execa is starting…")
            }
        } label: {
            MenuBarLabel(state: meetingState)
        }
    }

    private func observeMeetingState(_ coordinator: AppCoordinator) async {
        var lastDiskFullAlertShown = false
        var previousState: MeetingState = .idle
        for await newState in coordinator.audioCapture.stateStream {
            let priorState = previousState
            meetingState = newState
            previousState = newState
            switch newState {
            case .recording:
                openWindow(id: "execa-live-meeting")
            case .idle:
                dismissWindow(id: "execa-live-meeting")
                // Auto-open the meeting detail view on a clean stop
                // (transitioning from .savingMeeting / .stopping to
                // .idle, with a just-ended meeting ID set). 200 ms
                // delay matches Phase 3 plan to avoid stealing focus
                // from LiveMeetingView's dismiss animation.
                if case .savingMeeting = priorState,
                   let meetingID = coordinator.audioCapture.lastEndedMeetingID {
                    Task {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        openWindow(id: "execa-meeting-detail", value: meetingID)
                    }
                }
            default:
                break
            }
            if case .error(.diskFull) = newState, !lastDiskFullAlertShown {
                lastDiskFullAlertShown = true
                await MainActor.run { Self.showDiskFullAlert() }
            }
            if case .error(.diskFull) = newState {
                // keep flag set until we leave the error state
            } else {
                lastDiskFullAlertShown = false
            }
        }
    }

    private static func showDiskFullAlert() {
        let alert = NSAlert()
        alert.messageText = "Recording paused: disk full"
        alert.informativeText = """
        execa stopped recording because there's no space left on the disk. Free \
        some space and start a new meeting. The audio captured so far has been \
        saved to the meetings folder.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private struct RootView: View {
    let coordinator: AppCoordinator?
    let initError: String?
    let firstRunComplete: Bool
    let onWizardComplete: () -> Void

    var body: some View {
        if let coordinator {
            if firstRunComplete {
                AlreadySetUpView()
            } else {
                SetupWizardView(coordinator: coordinator, onComplete: onWizardComplete)
            }
        } else if let initError {
            VStack(spacing: 8) {
                Text("execa failed to start").font(.headline)
                Text(initError).font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        } else {
            ProgressView("Starting execa…").padding()
        }
    }
}

private struct AlreadySetUpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("execa is set up.").bold()
            Text("Look for the execa icon in your menu bar to start a meeting.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }
}
