@testable import Execa
import Foundation
import Testing

struct SetupWizardSttKeyStepTests {
    @Test func masksTypicalSarvamKey() {
        // 36-character UUID-like keys are the typical Sarvam shape.
        let key = "abcdefghijklmnopqrstuvwxyz0123456789"
        let mask = SetupWizardSttKeyStep.mask(key)
        #expect(mask.hasPrefix("abcd"))
        #expect(mask.hasSuffix("89"))
        #expect(mask.contains("•"), "expected dots in the middle, got \(mask)")
        // Mask must not include any of the middle key characters.
        let middle = String(key.dropFirst(4).dropLast(2))
        for char in middle {
            #expect(!mask.contains(char), "mask leaked character \(char) from middle of key")
        }
    }

    @Test func shortKeysAllDots() {
        let mask = SetupWizardSttKeyStep.mask("abc")
        #expect(mask == "•••")
    }

    @Test func emptyKeyIsEmpty() {
        #expect(SetupWizardSttKeyStep.mask("") == "")
    }
}
