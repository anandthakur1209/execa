@testable import Execa
import Foundation
import Testing

/// Non-keychain-touching `AppCoordinator` tests. The keychain-mutating
/// Dismiss test lives in `TranscriptionServiceTests` (which is
/// `.serialized`) so all wipe-then-restore tests share one serialised
/// suite — see the comment on that struct.
struct AppCoordinatorTests {
    /// `dismissError()` must be a no-op when the state isn't
    /// `.error(...)` — guards against a misrouted Dismiss click
    /// silently aborting an in-progress meeting. Tests against the
    /// `.idle` baseline (the simplest non-error state) — calling
    /// dismiss while already idle should leave the state unchanged.
    @Test func dismissingFromIdleIsHarmless() async throws {
        let coordinator = try await AppCoordinator()
        await coordinator.dismissError()
        let state = await coordinator.audioCapture.state
        if case .idle = state {
            // ok
        } else {
            Issue.record("expected .idle after dismissError() from idle; got \(state)")
        }
    }
}
