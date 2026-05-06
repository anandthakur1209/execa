import AppKit
import AVFoundation
import CoreGraphics
import Foundation

actor PermissionsService {
    func microphoneStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    nonisolated func screenRecordingStatus() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    nonisolated func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    @MainActor
    func openScreenRecordingSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    func openMicrophoneSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
