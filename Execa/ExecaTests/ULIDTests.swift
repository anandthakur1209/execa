@testable import Execa
import Foundation
import Testing

struct ULIDTests {
    @Test func generatedIDsAre26CharsCrockford() {
        let id = ULID.generate()
        #expect(id.count == 26)
        let allowed = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        for char in id {
            #expect(allowed.contains(char), "unexpected character \(char) in ULID")
        }
    }

    @Test func sequentiallyGeneratedIDsAreLexicographicallyIncreasing() {
        var ids: [String] = []
        let baseDate = Date()
        for offset in 0 ..< 100 {
            let when = baseDate.addingTimeInterval(Double(offset) * 0.001)
            ids.append(ULID.generate(now: when))
        }
        let sorted = ids.sorted()
        #expect(ids == sorted, "ULIDs generated in time order should sort lexicographically")
    }

    @Test func timestampPrefixReflectsGenerationTime() {
        let earlier = ULID.generate(now: Date(timeIntervalSince1970: 1_700_000_000))
        let later = ULID.generate(now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(String(earlier.prefix(10)) < String(later.prefix(10)))
    }
}
