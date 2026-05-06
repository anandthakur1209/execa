import Foundation

actor AppCoordinator {
    private let database: Database
    private let settings: SettingsStore
    let keychain: KeychainStore
    let permissions: PermissionsService
    let audioCapture: AudioCaptureService

    init() async throws {
        let database = try Database.make()
        self.database = database
        let settings = SettingsStore(database: database)
        self.settings = settings
        let keychain = KeychainStore()
        self.keychain = keychain
        let permissions = PermissionsService()
        self.permissions = permissions
        audioCapture = AudioCaptureService(
            mic: MicrophoneSource(),
            system: ScreenCaptureKitSource(),
            permissions: permissions,
            database: database
        )
    }

    func currentDisplayName() async throws -> String? {
        try await settings.string(forKey: .displayName)
    }

    func setDisplayName(_ name: String) async throws {
        try await settings.setString(name, forKey: .displayName)
    }

    func isFirstRunComplete() async throws -> Bool {
        try await settings.bool(forKey: .firstRunComplete)
    }

    func markFirstRunComplete() async throws {
        try await settings.setBool(true, forKey: .firstRunComplete)
    }

    @discardableResult
    func startMeeting() async throws -> URL {
        let id = ULID.generate()
        return try await audioCapture.start(meetingID: id)
    }

    func stopMeeting() async throws {
        _ = try await audioCapture.stop()
    }
}
