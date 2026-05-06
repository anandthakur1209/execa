import Foundation

actor AppCoordinator {
    private let database: Database
    private let settings: SettingsStore
    let keychain: KeychainStore

    init() async throws {
        let database = try Database.make()
        self.database = database
        self.settings = SettingsStore(database: database)
        self.keychain = KeychainStore()
    }

    func currentDisplayName() async throws -> String? {
        try await settings.string(forKey: .displayName)
    }

    func setDisplayName(_ name: String) async throws {
        try await settings.setString(name, forKey: .displayName)
    }
}
