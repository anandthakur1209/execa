import Foundation
import Testing

@testable import Execa

struct KeychainStoreTests {
    @Test func roundTrip() throws {
        let store = KeychainStore()
        let service = "com.anandthakur.execa.test.\(UUID().uuidString)"
        let account = "default"
        let value = "secret-\(UUID().uuidString)"

        defer { try? store.delete(service: service, account: account) }

        try store.set(value, service: service, account: account)
        let fetched = try store.get(service: service, account: account)
        #expect(fetched == value)

        let updated = "rotated-\(UUID().uuidString)"
        try store.set(updated, service: service, account: account)
        #expect(try store.get(service: service, account: account) == updated)

        try store.delete(service: service, account: account)
        #expect(try store.get(service: service, account: account) == nil)
    }

    @Test func serviceNamePrefix() {
        #expect(KeychainStore.serviceName(forProvider: "sarvam") == "com.anandthakur.execa.sarvam")
        #expect(KeychainStore.serviceName(forProvider: "anthropic") == "com.anandthakur.execa.anthropic")
    }
}
