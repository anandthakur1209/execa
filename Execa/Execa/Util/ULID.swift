import Foundation

enum ULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func generate(now: Date = Date()) -> String {
        let ms = UInt64(now.timeIntervalSince1970 * 1000)
        var randomBytes = [UInt8](repeating: 0, count: 10)
        for index in 0 ..< 10 {
            randomBytes[index] = UInt8.random(in: 0 ... 255)
        }

        var hi: UInt64 = 0
        for index in 0 ..< 6 {
            let shift = (5 - index) * 8
            hi |= UInt64((ms >> shift) & 0xFF) << ((7 - index) * 8)
        }
        for index in 0 ..< 2 {
            hi |= UInt64(randomBytes[index]) << ((1 - index) * 8)
        }

        var lo: UInt64 = 0
        for index in 0 ..< 8 {
            lo |= UInt64(randomBytes[index + 2]) << ((7 - index) * 8)
        }

        return encode128(hi: hi, lo: lo)
    }

    private static func encode128(hi: UInt64, lo: UInt64) -> String {
        var chars = [Character]()
        chars.reserveCapacity(26)
        for charIndex in 0 ..< 26 {
            var value = 0
            for bitOffset in 0 ..< 5 {
                let paddedBit = charIndex * 5 + bitOffset
                let originalBit = paddedBit - 2
                value = (value << 1) | (originalBit < 0 ? 0 : bit(at: originalBit, hi: hi, lo: lo))
            }
            chars.append(alphabet[value])
        }
        return String(chars)
    }

    private static func bit(at index: Int, hi: UInt64, lo: UInt64) -> Int {
        if index < 64 {
            return Int((hi >> (63 - index)) & 1)
        }
        return Int((lo >> (63 - (index - 64))) & 1)
    }
}
