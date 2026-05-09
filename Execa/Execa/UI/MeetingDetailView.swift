import AppKit
import GRDB
import SwiftUI

/// Post-meeting view showing the diarized transcript + speaker
/// management affordances. Auto-opens via `WindowGroup(id: "execa-
/// meeting-detail", for: String.self)` keyed by meetingID after a
/// successful stop (`AppCoordinator.stopMeeting`'s post-stop path).
/// Also reachable from the menu bar's "Open last meeting" item.
///
/// Phase 3 scope is intentionally minimal:
///   - Top: meeting metadata + diarization status pill.
///   - Single-button "Got it" announcement (Revision 1) when the
///     diarization status flips to `.completed` while the view is
///     on screen — auto-dismisses after 5 s.
///   - Speaker list (reuses `SpeakerListSection`) with rename / merge
///     / voice-sample.
///   - Read-only transcript pane (`TranscriptTurnContextMenu` for
///     split lands in commit 8).
///   - Bottom toolbar: "Re-run diarization" (with confirmation alert
///     per Revision 3) + "Open meeting folder".
struct MeetingDetailView: View {
    let coordinator: AppCoordinator
    let meetingID: String

    @State private var rows: [SpeakerRowModel] = []
    @State private var transcriptLines: [TranscriptDisplayLine] = []
    @State private var status: DiarizationStatus = .notRequested
    @State private var showRerunAlert: Bool = false
    @State private var showCompletedAnnouncement: Bool = false
    @State private var voicePlayer: SpeakerVoiceSamplePlayer?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showCompletedAnnouncement {
                announcementBanner
            }
            Divider()
            HStack(alignment: .top, spacing: 0) {
                speakersPane
                Divider()
                transcriptPane
            }
            Divider()
            bottomToolbar
        }
        .frame(minWidth: 720, minHeight: 480)
        .navigationTitle("Meeting")
        .modifier(
            RerunDiarizationConfirmation.alert(
                isPresented: $showRerunAlert,
                confirm: { Task { await coordinator.rerunDiarization(meetingID: meetingID) } }
            )
        )
        .task(id: meetingID) {
            voicePlayer = SpeakerVoiceSamplePlayer(database: coordinator.database)
            await refreshAll()
        }
        .onChange(of: coordinator.diarizationStatusStore.status(forMeetingID: meetingID)) { _, newStatus in
            status = newStatus
            if case .completed = newStatus {
                showCompletedAnnouncement = true
                Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    showCompletedAnnouncement = false
                }
                Task { await refreshAll() }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Meeting \(meetingID)").font(.headline)
                Text(statusLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            statusPill
        }
        .padding(12)
    }

    private var statusLabel: String {
        switch status {
        case .notRequested: "Diarization: not requested"
        case .pending: "Diarization: pending"
        case let .completed(date): "Diarization: completed \(formatTime(date))"
        case let .failed(message): "Diarization failed: \(message)"
        }
    }

    private var statusPill: some View {
        let pill: (label: String, color: Color) = switch status {
        case .notRequested: ("Not requested", .secondary)
        case .pending: ("Pending", .orange)
        case .completed: ("Done", .green)
        case .failed: ("Failed", .red)
        }
        return Text(pill.label)
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(pill.color.opacity(0.18), in: Capsule())
    }

    private var announcementBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Speaker labels are ready.")
                .fontWeight(.medium)
            Spacer()
            Button("Got it") { showCompletedAnnouncement = false }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.08))
    }

    // MARK: - Panes

    private var speakersPane: some View {
        VStack(alignment: .leading) {
            Text("Speakers").font(.headline).padding(.bottom, 4)
            if rows.isEmpty {
                Text("No speakers yet.").font(.caption).foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    SpeakerListSection(
                        speakers: rows,
                        isLive: false,
                        mergeTargets: rows,
                        onRename: { speakerID, newLabel in
                            Task {
                                try? await coordinator.speakerLabelManager.rename(
                                    speakerID: speakerID, to: newLabel
                                )
                                await refreshAll()
                            }
                        },
                        onMerge: { sourceID, targetID in
                            Task {
                                try? await coordinator.speakerLabelManager.merge(
                                    sourceSpeakerID: sourceID,
                                    intoTargetSpeakerID: targetID
                                )
                                await refreshAll()
                            }
                        },
                        onPlayVoiceSample: { speakerID in
                            Task { _ = await voicePlayer?.play(speakerID: speakerID, meetingID: meetingID) }
                        }
                    )
                }
            }
        }
        .frame(width: 280)
        .padding(12)
    }

    private var transcriptPane: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(transcriptLines) { line in
                    MeetingDetailTranscriptRow(line: line, onSplit: handleSplit)
                }
            }
            .padding(16)
        }
    }

    private func handleSplit(segmentID: Int64, label: String) {
        Task {
            _ = try? await coordinator.speakerLabelManager.split(
                segmentID: segmentID,
                intoNewLabel: label
            )
            await refreshAll()
        }
    }

    // MARK: - Bottom toolbar

    private var bottomToolbar: some View {
        HStack {
            Button("Re-run diarization") { showRerunAlert = true }
                .disabled(status == .pending)
            Button("Open meeting folder", action: openMeetingFolder)
            Spacer()
        }
        .padding(12)
    }

    // MARK: - Data + actions

    private func refreshAll() async {
        status = coordinator.diarizationStatusStore.status(forMeetingID: meetingID)
        rows = await loadSpeakerRows()
        transcriptLines = await loadTranscriptLines()
    }

    private func loadSpeakerRows() async -> [SpeakerRowModel] {
        let database = coordinator.database
        let meeting = meetingID
        let rawRows = await (try? database.queue.read { db -> [Row] in
            try Row.fetchAll(
                db,
                sql: """
                SELECT s.id AS id, s.source AS source, s.display_label AS label
                FROM speakers s
                WHERE s.meeting_id = ? AND s.merged_into_speaker_id IS NULL
                ORDER BY s.source, s.raw_speaker_id
                """,
                arguments: [meeting]
            )
        }) ?? []
        let talkTime = await (try? database.queue.read { db in
            try SpeakerQueries.talkTimeAggregated(meetingID: meeting, in: db)
        }) ?? [:]
        return rawRows.compactMap { row -> SpeakerRowModel? in
            guard let id: Int64 = row["id"],
                  let source: String = row["source"],
                  let label: String = row["label"]
            else { return nil }
            let ms = talkTime[id] ?? 0
            return SpeakerRowModel(
                id: id,
                label: label,
                source: source,
                talkTimeSeconds: TimeInterval(ms) / 1000.0
            )
        }
    }

    private func loadTranscriptLines() async -> [TranscriptDisplayLine] {
        let database = coordinator.database
        let meeting = meetingID
        let lineRows = await (try? database.queue.read { db -> [Row] in
            try Row.fetchAll(
                db,
                sql: """
                SELECT t.id AS id,
                       t.start_ms AS start_ms,
                       t.text AS text,
                       COALESCE(merged.display_label, s.display_label) AS label
                FROM transcript_segments t
                JOIN speakers s ON s.id = t.speaker_id
                LEFT JOIN speakers merged ON merged.id = s.merged_into_speaker_id
                WHERE t.meeting_id = ? AND t.is_final = 1
                ORDER BY t.start_ms ASC, t.id ASC
                """,
                arguments: [meeting]
            )
        }) ?? []
        return lineRows.compactMap { row in
            guard let id: Int64 = row["id"],
                  let startMs: Int = row["start_ms"],
                  let text: String = row["text"],
                  let label: String = row["label"]
            else { return nil }
            return TranscriptDisplayLine(
                id: id,
                timestamp: formatTimestamp(TimeInterval(startMs) / 1000),
                speakerLabel: label,
                text: text
            )
        }
    }

    private func openMeetingFolder() {
        guard let directory = try? MeetingsDirectory.url(forMeetingID: meetingID) else {
            return
        }
        NSWorkspace.shared.open(directory)
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct TranscriptDisplayLine: Identifiable, Equatable {
    let id: Int64
    let timestamp: String
    let speakerLabel: String
    let text: String
}

private struct MeetingDetailTranscriptRow: View {
    let line: TranscriptDisplayLine
    let onSplit: (Int64, String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(line.timestamp)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.speakerLabel).font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(line.text)
            }
            Spacer(minLength: 0)
        }
        .transcriptTurnContextMenu(segmentID: line.id, onSplit: onSplit)
    }
}
