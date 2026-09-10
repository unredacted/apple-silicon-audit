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

    /// True when the buffer covers every bit the header defines. An ordinary `sysctl -a`
    /// dump prints only the declared 8-byte scalar, which silently drops bits 64–91.
    public func covers(_ table: CapsBitTable) -> Bool { byteCount * 8 >= table.capBitNB }
}

/// Result of comparing the bitmask with the individual `FEAT_*` keys.
public struct CapsCrossCheck: Equatable, Sendable {
    /// One line per disagreement.
    public let mismatches: [String]
    /// Named bits whose key was compared.
    public let compared: Int
    /// Named bits whose `hw.optional.arm.<NAME>` key could not be compared (absent, restricted,
    /// undecodable). An empty `mismatches` with a non-empty `unchecked` is not a clean bill.
    public let unchecked: [String]

    public var isComplete: Bool { unchecked.isEmpty }
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

    /// Compares each named bit with the matching `hw.optional.arm.<NAME>` key that was read,
    /// and records which comparisons could not be made.
    public static func crossCheck(_ decode: CapsDecode, table: CapsBitTable, outcome: (String) -> ProbeOutcome?) -> CapsCrossCheck {
        var lines: [String] = []
        var compared = 0
        var unchecked: [String] = []
        for entry in table.entries {
            let key = "hw.optional.arm." + entry.name
            let bit = decode.isSet(entry.name)
            switch outcome(key) {
            case .some(.absent):
                // The header names the bit but this kernel registers no key: the bit must be clear.
                compared += 1
                if bit { lines.append("\(entry.name): caps bit \(entry.bit)=1 but \(key) is absent from this kernel") }
            case .some(let o):
                guard let flag = o.flagIsSet else { unchecked.append(entry.name); continue }
                compared += 1
                if flag != bit {
                    lines.append("\(entry.name): caps bit \(entry.bit)=\(bit ? 1 : 0), \(key)=\(flag ? 1 : 0)")
                }
            case nil:
                unchecked.append(entry.name)
            }
        }
        return CapsCrossCheck(mismatches: lines, compared: compared, unchecked: unchecked)
    }
}
