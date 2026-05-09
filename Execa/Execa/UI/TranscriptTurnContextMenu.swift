import SwiftUI

/// Right-click context-menu modifier for a transcript turn. Phase 3
/// Revision 7 keeps this surface to ONE item — "Split into new
/// speaker…" — opening a popover with a TextField. Submitting calls
/// `SpeakerLabelManager.split(segmentID:intoNewLabel:)`. Used by both
/// `LiveMeetingView` (in-progress meetings) and `MeetingDetailView`
/// (post-meeting).
///
/// Rename is sidebar-only; cluster-merge is sidebar-only. Putting
/// either on the transcript turn would crowd the gesture surface and
/// confuse the click semantics (Phase 5 will add a click-to-seek
/// scrubber to the same turn rows; conflating click and right-click
/// across multiple ops is the path to UI sadness).
///
/// `databaseSegmentID == nil` (e.g. interim lines that haven't hit
/// the DB yet) suppresses the menu entirely — split needs a real DB
/// row to attach the new speaker to.
struct TranscriptTurnContextMenu: ViewModifier {
    let databaseSegmentID: Int64?
    let onSplit: (Int64, String) -> Void

    @State private var isPopoverPresented: Bool = false
    @State private var draftLabel: String = ""

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if databaseSegmentID != nil {
                    Button("Split into new speaker…") {
                        draftLabel = ""
                        isPopoverPresented = true
                    }
                }
            }
            .popover(isPresented: $isPopoverPresented) {
                splitPopover
            }
    }

    private var splitPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Split into new speaker")
                .font(.headline)
            Text("This turn will be reassigned to a new speaker.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Label (e.g. Maya, Dev Lead)", text: $draftLabel)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel") { isPopoverPresented = false }
                Button("Split", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draftLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    private func commit() {
        let trimmed = draftLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let segmentID = databaseSegmentID else { return }
        onSplit(segmentID, trimmed)
        isPopoverPresented = false
    }
}

extension View {
    /// Convenience modifier matching the `databaseSegmentID == nil`
    /// convention so call sites read as
    /// `.transcriptTurnContextMenu(segmentID:line.databaseSegmentID, ...)`.
    func transcriptTurnContextMenu(
        segmentID: Int64?,
        onSplit: @escaping (Int64, String) -> Void
    ) -> some View {
        modifier(TranscriptTurnContextMenu(databaseSegmentID: segmentID, onSplit: onSplit))
    }
}
