import Foundation

/// Decodes `hw.optional.arm.caps` (one bit per FEAT extension, `CAP_BIT_*`) and checks it
/// against the individual `FEAT_*` keys. The bitmask and the keys come from the same kernel
/// table, so any disagreement is either an engine bug or a finding; both must be surfaced.
public struct CapsDecode: Equatable, Sendable {
    /// Names of set bits that the public header names, in bit order.
    public let namedBits: [String]
    /// Set bit positions the public header does not name (reserved or newer than the SDK).
    public let unnamedBits: [Int]
    public let popcount: Int
    public let byteCount: Int

    public func isSet(_ name: String) -> Bool { namedBits.contains(name) }
}

public enum CapsDecoder {
    public static func decode(_ bytes: [UInt8], table: CapsBitTable) -> CapsDecode {
        let names = table.nameByBit
        var named: [String] = []
        var unnamed: [Int] = []
        var count = 0
        for bit in 0..<(bytes.count * 8) where (bytes[bit / 8] >> (bit % 8)) & 1 == 1 {
            count += 1
            if let n = names[bit] { named.append(n) } else { unnamed.append(bit) }
        }
        return CapsDecode(namedBits: named, unnamedBits: unnamed, popcount: count, byteCount: bytes.count)
    }

    /// Compares each named bit with the matching `hw.optional.arm.<NAME>` key that was read.
    /// Returns one line per disagreement, empty when consistent.
    public static func mismatches(_ decode: CapsDecode, table: CapsBitTable, outcome: (String) -> ProbeOutcome?) -> [String] {
        var lines: [String] = []
        for entry in table.entries {
            let key = "hw.optional.arm." + entry.name
            guard let flag = outcome(key)?.flagIsSet else { continue }
            let bit = decode.isSet(entry.name)
            if flag != bit {
                lines.append("\(entry.name): caps bit \(entry.bit)=\(bit ? 1 : 0), \(key)=\(flag ? 1 : 0)")
            }
        }
        return lines
    }
}
