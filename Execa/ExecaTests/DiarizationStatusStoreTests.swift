@testable import Execa
import Foundation
import Testing

/// MainActor `@Observable` round-trip on `DiarizationStatusStore`.
/// Verifies the publish path that `DiarizationService` uses to surface
/// state transitions to SwiftUI.
@MainActor
struct DiarizationStatusStoreTests {
    @Test func unsetMeetingReadsAsNotRequested() {
        let store = DiarizationStatusStore()
        #expect(store.status(forMeetingID: "missing") == .notRequested)
    }

    @Test func updateRoundTrips() {
        let store = DiarizationStatusStore()
        store.update(meetingID: "m1", status: .pending)
        #expect(store.status(forMeetingID: "m1") == .pending)

        let now = Date()
        store.update(meetingID: "m1", status: .completed(at: now))
        #expect(store.status(forMeetingID: "m1") == .completed(at: now))

        store.update(meetingID: "m1", status: .failed(message: "Sarvam 502"))
        #expect(store.status(forMeetingID: "m1") == .failed(message: "Sarvam 502"))
    }

    @Test func multipleMeetingsCoexist() {
        let store = DiarizationStatusStore()
        store.update(meetingID: "m1", status: .pending)
        store.update(meetingID: "m2", status: .completed(at: Date()))
        store.update(meetingID: "m3", status: .failed(message: "x"))

        #expect(store.status(forMeetingID: "m1") == .pending)
        if case .completed = store.status(forMeetingID: "m2") {
            // ok
        } else {
            Issue.record("m2 should be .completed")
        }
        if case let .failed(message) = store.status(forMeetingID: "m3") {
            #expect(message == "x")
        } else {
            Issue.record("m3 should be .failed")
        }
    }
}
