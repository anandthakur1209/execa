import Foundation

actor AppCoordinator {
    private let database: Database
    private let settings: SettingsStore
    let keychain: KeychainStore
    let permissions: PermissionsService

    init() async throws {
        let database = try Database.make()
        self.database = database
        settings = SettingsStore(database: database)
        keychain = KeychainStore()
        permissions = PermissionsService()
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
}
