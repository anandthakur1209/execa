import SwiftUI

/// Builds the confirmation alert presented before re-running batch
/// diarization on a meeting (Phase 3 Revision 3). Re-running wipes
/// existing speaker labels and merges per Decision 2's authoritative-
/// replace semantics, so we ask once before doing it.
///
/// Used by `MeetingDetailView` via the standard `.alert(...)`
/// modifier; bind the binding to a parent state flag, set it `true`
/// when the user clicks "Re-run diarization", and the alert will
/// fire before calling the handler.
enum RerunDiarizationConfirmation {
    static let title = "Re-run diarization?"
    static let message = """
    Re-running diarization will reset all speaker labels and merges \
    for this meeting. The transcript text and audio recordings are \
    preserved.
    """

    /// Returns a `View` modifier producing the alert. The `confirm`
    /// closure is invoked only on the destructive "Re-run" tap.
    static func alert(
        isPresented: Binding<Bool>,
        confirm: @escaping () -> Void
    ) -> some ViewModifier {
        AlertModifier(isPresented: isPresented, confirm: confirm)
    }

    private struct AlertModifier: ViewModifier {
        @Binding var isPresented: Bool
        let confirm: () -> Void

        func body(content: Content) -> some View {
            content.alert(
                RerunDiarizationConfirmation.title,
                isPresented: $isPresented
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Re-run", role: .destructive) { confirm() }
            } message: {
                Text(RerunDiarizationConfirmation.message)
            }
        }
    }
}
