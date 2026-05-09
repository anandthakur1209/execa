import Combine
import SwiftUI

/// SwiftUI views for the menu bar. The label is the source of truth for live
/// status — `MenuBarExtra` disabled menu items don't refresh reliably while
/// the menu is open, but the bar label itself ticks every second when
/// recording so the user sees `● 0:42` updating in place.
struct MenuBarLabel: View {
    let state: MeetingState
    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        switch state {
        case .idle:
            Image(systemName: "record.circle")
        case .starting:
            HStack(spacing: 4) {
                Image(systemName: "circle.dotted")
                Text("Starting…")
            }
        case let .recording(_, startedAt):
            HStack(spacing: 4) {
                Image(systemName: "circle.fill").foregroundStyle(.red)
                Text(format(elapsed))
            }
            .onReceive(timer) { _ in
                elapsed = Date().timeIntervalSince(startedAt)
            }
            .onAppear { elapsed = Date().timeIntervalSince(startedAt) }
        case .stopping:
            HStack(spacing: 4) {
                Image(systemName: "circle.dashed")
                Text("Stopping…")
            }
        case .savingMeeting:
            HStack(spacing: 4) {
                Image(systemName: "circle.dashed")
                Text("Saving…")
            }
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        }
    }

    private func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

struct MenuBarMenu: View {
    let state: MeetingState
    let onStart: () -> Void
    let onStop: () -> Void
    let onOpenScreenSettings: () -> Void
    let onOpenMicSettings: () -> Void
    let onShowLiveWindow: () -> Void
    let onDismissError: () -> Void

    var body: some View {
        switch state {
        case .idle:
            Button("Start Meeting") { onStart() }
                .keyboardShortcut("R", modifiers: [.command, .shift])
            Divider()
            Button("Quit execa") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("Q", modifiers: .command)

        case .starting:
            Text("Starting meeting…")
            Divider()
            Button("Quit execa") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("Q", modifiers: .command)

        case .recording:
            Button("Stop Meeting") { onStop() }
                .keyboardShortcut("E", modifiers: [.command, .shift])
            Button("Show Live Meeting Window") { onShowLiveWindow() }
            Divider()
            Button("Quit execa") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("Q", modifiers: .command)

        case .stopping, .savingMeeting:
            Text("Saving meeting…")
            Divider()
            Button("Quit execa") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("Q", modifiers: .command)

        case let .error(meetingError):
            Text(errorLabel(meetingError))
            Divider()
            switch meetingError {
            case .permissionDenied(.microphone):
                Button("Open Microphone Settings…") { onOpenMicSettings() }
            case .permissionDenied(.screenRecording):
                Button("Open Screen Recording Settings…") { onOpenScreenSettings() }
            case .missingSTTKey:
                // Deep-link into the wizard's STT step lands in commit 3.
                EmptyView()
            case .diskFull, .streamFailed:
                EmptyView()
            }
            Button("Dismiss") { onDismissError() }
            Divider()
            Button("Quit execa") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("Q", modifiers: .command)
        }
    }

    private func errorLabel(_ error: MeetingError) -> String {
        switch error {
        case .permissionDenied(.microphone): "Recording paused: microphone permission denied"
        case .permissionDenied(.screenRecording): "Recording paused: screen recording permission denied"
        case .diskFull: "Recording paused: disk full"
        case .missingSTTKey: "No Sarvam key — add one in the wizard"
        case let .streamFailed(message): "Recording paused: \(message)"
        }
    }
}
