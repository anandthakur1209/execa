import GRDB
import SwiftUI

/// Collapsible left-side panel embedded in `LiveMeetingView`. Renders
/// the per-meeting speaker list with single-click inline rename, the
/// "Merge into…" picker (cross-source supported per Decision 4), and a
/// disabled voice-sample button (live-time per Decision 5). Width
/// fixed at ~240 px; collapsible via the chevron toggle.
///
/// View-model is built each redraw from the `TranscriptStore`'s live
/// state — `speakerRowsForLive(...)` joins (a) the unique
/// `(source, raw_speaker_id)` pairs that have produced lines (so the
/// sidebar shows only speakers that have actually said something), with
/// (b) the `talkTimeBySpeaker` map. The DB is consulted once per
/// redraw for the row IDs + labels; SwiftUI's `@Observable` invalidation
/// on `TranscriptStore.lines` and `talkTimeBySpeaker` triggers the
/// re-render automatically.
struct SpeakerSidebar: View {
    let coordinator: AppCoordinator
    let store: TranscriptStore
    let meetingID: String

    @State private var rows: [SpeakerRowModel] = []
    @State private var isCollapsed: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Speakers")
                    .font(.headline)
                Spacer()
                Button(
                    action: { isCollapsed.toggle() },
                    label: { Image(systemName: isCollapsed ? "chevron.right" : "chevron.left") }
                )
                .buttonStyle(.borderless)
                .help(isCollapsed ? "Show sidebar" : "Hide sidebar")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if !isCollapsed {
                Divider().padding(.vertical, 8)
                if rows.isEmpty {
                    Text("No speakers yet — start talking.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                } else {
                    ScrollView {
                        SpeakerListSection(
                            speakers: rows,
                            isLive: true,
                            mergeTargets: rows,
                            onRename: { speakerID, newLabel in
                                Task {
                                    try? await coordinator.renameSpeaker(
                                        speakerID: speakerID,
                                        to: newLabel
                                    )
                                }
                            },
                            onMerge: { sourceID, targetID in
                                Task {
                                    try? await coordinator.mergeSpeakers(
                                        sourceSpeakerID: sourceID,
                                        intoTargetSpeakerID: targetID
                                    )
                                }
                            },
                            onPlayVoiceSample: nil
                        )
                        .padding(.horizontal, 8)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: isCollapsed ? 28 : 240, alignment: .leading)
        .background(Color.gray.opacity(0.04))
        .task(id: store.lines.count) {
            // Re-derive rows whenever a line lands. The DB is hit once
            // per derivation rather than once per row to keep the
            // SwiftUI render path snappy.
            rows = await (try? Self.derive(
                meetingID: meetingID,
                store: store,
                coordinator: coordinator
            )) ?? []
        }
    }

    /// Joins the meeting's visible speakers with `talkTimeBySpeaker`.
    /// "Visible" here means post-merge canonical AND not orphaned by
    /// the Phase 3.5 dedup pass — `SpeakerQueries.visibleSpeakers`
    /// owns the SQL so this view stays in lockstep with
    /// `MeetingDetailView`. Static so it's testable without a SwiftUI
    /// host.
    static func derive(
        meetingID: String,
        store: TranscriptStore,
        coordinator: AppCoordinator
    ) async throws -> [SpeakerRowModel] {
        let database = coordinator.database
        let rawRows = try await database.queue.read { db in
            try SpeakerQueries.visibleSpeakers(meetingID: meetingID, in: db)
        }
        return rawRows.compactMap { row -> SpeakerRowModel? in
            guard let id: Int64 = row["id"],
                  let source: String = row["source"],
                  let label: String = row["display_label"]
            else { return nil }
            let effective: Int64 = row["effective_id"] ?? id
            return SpeakerRowModel(
                id: id,
                label: label,
                source: source,
                talkTimeSeconds: store.talkTimeBySpeaker[effective]
            )
        }
    }
}
