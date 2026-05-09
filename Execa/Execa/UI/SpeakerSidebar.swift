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
                                Task { try? await coordinator.speakerLabelManager.rename(
                                    speakerID: speakerID,
                                    to: newLabel
                                ) }
                            },
                            onMerge: { sourceID, targetID in
                                Task {
                                    try? await coordinator.speakerLabelManager.merge(
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

    /// Joins the live `speakers` rows (filtered to those that have
    /// emitted at least one line) with `talkTimeBySpeaker`. Static so
    /// it's testable without a SwiftUI host.
    static func derive(
        meetingID: String,
        store: TranscriptStore,
        coordinator: AppCoordinator
    ) async throws -> [SpeakerRowModel] {
        // The TranscriptStore-internal `speakerRowIDs` cache isn't
        // exposed publicly; the DB is the source of truth. We pull
        // every `speakers` row for the meeting that has at least one
        // segment so far, walk the merge alias for the display label,
        // and join on the in-memory talk-time map.
        let database = coordinator.database
        let rawRows = try await database.queue.read { db -> [Row] in
            try Row.fetchAll(
                db,
                sql: """
                SELECT s.id AS id,
                       s.source AS source,
                       COALESCE(merged.display_label, s.display_label) AS label,
                       COALESCE(s.merged_into_speaker_id, s.id) AS effective_id
                FROM speakers s
                LEFT JOIN speakers merged ON merged.id = s.merged_into_speaker_id
                WHERE s.meeting_id = ?
                  AND s.merged_into_speaker_id IS NULL
                ORDER BY s.source, s.raw_speaker_id
                """,
                arguments: [meetingID]
            )
        }
        return rawRows.compactMap { row -> SpeakerRowModel? in
            guard let id: Int64 = row["id"],
                  let source: String = row["source"],
                  let label: String = row["label"]
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
