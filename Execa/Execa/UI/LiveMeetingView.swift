import Combine
import SwiftUI

/// Floating window showing the live transcript while a meeting is
/// recording. Auto-opened by `ExecaApp` on the `.recording` state
/// transition; auto-dismissed on `.idle`. Manual re-open via the
/// "Show Live Meeting Window" item in the menu bar.
///
/// Phase 2 (Path B) renders Sarvam-style finals only — no
/// interim/italic styling, because Sarvam streaming emits one
/// finalized message per VAD-detected utterance (commit 5 probe). The
/// `isFinal` field on `TranscriptLine` stays in the data model so a
/// future Deepgram path can light up italic interims without code
/// changes.
struct LiveMeetingView: View {
    let coordinator: AppCoordinator
    let store: TranscriptStore

    @State private var meetingState: MeetingState = .idle

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            transcriptList
        }
        .frame(minWidth: 480, minHeight: 360)
        .navigationTitle("Live Meeting")
        .task {
            for await state in coordinator.audioCapture.stateStream {
                meetingState = state
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            timerView
            Spacer()
            connectionPill
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var timerView: some View {
        switch meetingState {
        case let .recording(_, startedAt):
            RecordingTimerLabel(startedAt: startedAt)
        case .savingMeeting:
            HStack(spacing: 6) {
                Image(systemName: "circle.dashed")
                Text("Saving…")
            }
            .foregroundStyle(.secondary)
        case .stopping:
            Text("Stopping…").foregroundStyle(.secondary)
        case .starting:
            Text("Starting…").foregroundStyle(.secondary)
        case .idle, .error:
            Text("").foregroundStyle(.secondary)
        }
    }

    private var connectionPill: some View {
        let style = aggregatedConnectionState()
        return HStack(spacing: 6) {
            Image(systemName: style.icon)
                .foregroundStyle(style.color)
            Text(style.label)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }

    /// Folds per-source connection states into a single label + colour
    /// for the pill. Worst-case wins: stopped > reconnecting >
    /// disconnected > connected. (Reconnect banner UX in commit 8 will
    /// add a "Resume" affordance for `.stopped`.)
    private func aggregatedConnectionState() -> ConnectionPillStyle {
        let states = store.connection.values
        if states.contains(.stopped) {
            return ConnectionPillStyle(
                label: "Transcription stopped",
                icon: "exclamationmark.triangle.fill",
                color: .red
            )
        }
        if states.contains(.reconnecting) {
            return ConnectionPillStyle(label: "Reconnecting…", icon: "arrow.triangle.2.circlepath", color: .orange)
        }
        if states.allSatisfy({ $0 == .connected }) {
            return ConnectionPillStyle(label: "Connected", icon: "circle.fill", color: .green)
        }
        return ConnectionPillStyle(label: "Disconnected", icon: "circle", color: .secondary)
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcriptList: some View {
        if store.lines.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(store.lines) { line in
                            transcriptRow(line)
                                .id(line.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: store.lines.count) {
                    if let last = store.lines.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Listening…")
                .foregroundStyle(.secondary)
            Text("Transcript will appear here as soon as Sarvam finalizes the first utterance.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func transcriptRow(_ line: TranscriptLine) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(formatTimestamp(line.timestamp))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.speakerLabel)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(line.text)
                    .foregroundStyle(line.isFinal ? .primary : .secondary)
                    .italic(!line.isFinal)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Bundle of styling fields for the connection-state pill. Avoids the
/// 3-tuple SwiftLint flags on `aggregatedConnectionState()`'s return
/// type. Ordered the same way the call site reads them.
private struct ConnectionPillStyle {
    let label: String
    let icon: String
    let color: Color
}

/// One-second-tick timer for the top bar during `.recording`. Same
/// pattern as `MenuBarLabel`'s timer; kept private to this view.
private struct RecordingTimerLabel: View {
    let startedAt: Date
    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.fill").foregroundStyle(.red)
            Text(format(elapsed))
                .font(.body.monospacedDigit())
        }
        .onReceive(timer) { _ in
            elapsed = Date().timeIntervalSince(startedAt)
        }
        .onAppear { elapsed = Date().timeIntervalSince(startedAt) }
    }

    private func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
