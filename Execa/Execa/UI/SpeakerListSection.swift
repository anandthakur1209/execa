import SwiftUI

/// Shared speaker-list rendering used by both `SpeakerSidebar` (live)
/// and `MeetingDetailView` (post-meeting). Each row carries a label
/// (sidebar-rename-editable in live mode), a `(mm:ss)` talk-time
/// readout, a "Merge into…" picker, and a voice-sample button (only
/// enabled post-meeting per Decision 5).
///
/// The view is data-driven by the parent: the parent composes a
/// `[SpeakerRowModel]` list (typically by joining `speakers` with the
/// merge alias and per-speaker talk-time map) and passes callbacks
/// for the user-driven actions. The view itself doesn't know whether
/// the meeting is live or post.
struct SpeakerListSection: View {
    /// One row per displayed speaker (alias rows are filtered out
    /// upstream — only canonical speakers appear).
    let speakers: [SpeakerRowModel]

    /// `true` when the meeting is still recording. Disables the voice
    /// sample button and adds the live-rename caveat tooltip per
    /// Phase 3 plan.
    let isLive: Bool

    /// Pool of merge targets (typically the same `speakers` list,
    /// minus the row being merged from). The picker supports
    /// cross-source merge per Decision 4.
    let mergeTargets: [SpeakerRowModel]

    let onRename: (Int64, String) -> Void
    let onMerge: (Int64, Int64) -> Void
    let onPlayVoiceSample: ((Int64) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(speakers) { speaker in
                SpeakerRowView(
                    speaker: speaker,
                    isLive: isLive,
                    mergeTargets: mergeTargets.filter { $0.id != speaker.id },
                    onRename: { newLabel in onRename(speaker.id, newLabel) },
                    onMerge: { targetID in onMerge(speaker.id, targetID) },
                    onPlayVoiceSample: onPlayVoiceSample.map { play in { play(speaker.id) } }
                )
            }
        }
    }
}

/// View-model carried by `SpeakerListSection`. Built from a
/// SQL JOIN of `speakers` + the `talkTimeBySpeaker` map (live) or
/// `SpeakerQueries.talkTimeAggregated` (post-meeting).
struct SpeakerRowModel: Identifiable, Hashable {
    let id: Int64
    /// Display label as resolved through the merge alias; for an
    /// un-merged speaker this is the row's own `display_label`.
    let label: String
    /// `"mic"` or `"system"`. Used for the picker's source caption.
    let source: String
    /// Total talk-time in seconds. `nil` if not yet computed (live UI
    /// shows `--` until the first final lands).
    let talkTimeSeconds: TimeInterval?
}

private struct SpeakerRowView: View {
    let speaker: SpeakerRowModel
    let isLive: Bool
    let mergeTargets: [SpeakerRowModel]
    let onRename: (String) -> Void
    let onMerge: (Int64) -> Void
    let onPlayVoiceSample: (() -> Void)?

    @State private var isEditing: Bool = false
    @State private var draftLabel: String = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if isEditing {
                    TextField("Speaker label", text: $draftLabel)
                        .textFieldStyle(.roundedBorder)
                        .focused($isFieldFocused)
                        .onSubmit(commitRename)
                        .onChange(of: isFieldFocused) {
                            if !isFieldFocused { commitRename() }
                        }
                        .help(
                            isLive
                                ? """
                                This rename applies to the live transcript. Final speaker labels are \
                                assigned after the meeting ends.
                                """
                                : "Renames apply retroactively across all this speaker's segments."
                        )
                } else {
                    Text(speaker.label)
                        .font(.body)
                        .onTapGesture {
                            draftLabel = speaker.label
                            isEditing = true
                            isFieldFocused = true
                        }
                }
                Spacer(minLength: 8)
                Text(formatTalkTime(speaker.talkTimeSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text(speaker.source == "mic" ? "mic" : "system")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if !mergeTargets.isEmpty {
                    Menu("Merge into…") {
                        ForEach(mergeTargets) { target in
                            Button(
                                action: { onMerge(target.id) },
                                label: { Text("\(target.label) · \(target.source)") }
                            )
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .font(.caption)
                }
                if let onPlayVoiceSample {
                    Button(action: onPlayVoiceSample) {
                        Label("Voice sample", systemImage: "speaker.wave.2.fill")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isLive)
                    .help(isLive ? "Available after meeting" : "Play 3 s of this speaker's audio.")
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private func commitRename() {
        let trimmed = draftLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != speaker.label {
            onRename(trimmed)
        }
        isEditing = false
    }

    private func formatTalkTime(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite else { return "--" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
