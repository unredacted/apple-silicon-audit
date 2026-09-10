import Foundation

/// A `SysctlReading` backed by a `sysctl(8)` text dump (`name: value` lines), so recorded
/// device output becomes a fixture without conversion: `docs/evidence/*.txt` and any
/// contributor's `sysctl -a` capture. Types come from the inventory (there is no OIDFMT in a
/// text file), exactly as on iOS. Used by tests and by `silicon-audit --fixture`.
public struct TextDumpSysctl: SysctlReading {
    public struct Options: Sendable {
        /// Emulate a sandbox that refuses CTL_SYSCTL_NEXT (iOS, watchOS).
        public var walkRefused = false
        /// Keys that read `restricted` regardless of the dump.
        public var restricted: Set<String> = []
        public init(walkRefused: Bool = false, restricted: Set<String> = []) {
            self.walkRefused = walkRefused
            self.restricted = restricted
        }
    }

    public let values: [String: [UInt8]]
    /// Full 12-byte caps buffer when the dump carries a `bytes[0..11]:` line.
    public let inventory: KnownKeyInventory
    public let options: Options
    /// Sorted keys under hw.optional, in the order the walk returns them.
    let walkOrder: [String]

    public init(text: String, inventory: KnownKeyInventory, options: Options = Options()) {
        var values: [String: [UInt8]] = [:]
        for line in text.split(separator: "\n") {
            let s = String(line)
            if s.hasPrefix("#") || s.hasPrefix("##") { continue }
            if let r = s.range(of: " bytes[0..11]: ") {
                let key = String(s[s.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let hex = s[r.upperBound...].split(separator: " ").compactMap { UInt8($0, radix: 16) }
                values[key] = hex
                continue
            }
            guard let colon = s.firstIndex(of: ":") else { continue }
            let key = String(s[s.startIndex..<colon])
            guard key.range(of: #"^[a-z][A-Za-z0-9_.]*$"#, options: .regularExpression) != nil else { continue }
            let value = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // First occurrence wins: evidence dumps append diagnostic sections (`sysctl -t`, `-l`, `-x`)
            // that repeat keys with type names or lengths instead of values.
            if values[key] != nil { continue }
            values[key] = TextDumpSysctl.bytes(for: key, value: value, inventory: inventory)
        }
        self.values = values
        self.inventory = inventory
        self.options = options
        self.walkOrder = values.keys.filter { $0.hasPrefix("hw.optional.") }.sorted()
    }

    public init(contentsOf url: URL, inventory: KnownKeyInventory, options: Options = Options()) throws {
        self.init(text: try String(contentsOf: url, encoding: .utf8), inventory: inventory, options: options)
    }

    static func bytes(for key: String, value: String, inventory: KnownKeyInventory) -> [UInt8] {
        let format = inventory.format(for: key)
        if format?.type == .string || (format == nil && Int64(value) == nil) {
            return Array(value.utf8) + [0]
        }
        guard let n = Int64(value) else { return Array(value.utf8) + [0] }
        let width = format?.declaredIntegerWidth ?? (n > Int64(Int32.max) || n < Int64(Int32.min) ? 8 : 4)
        return (0..<width).map { UInt8(truncatingIfNeeded: UInt64(bitPattern: n) >> (8 * UInt64($0))) }
    }

    // MARK: SysctlReading

    public func read(_ name: String) -> ProbeOutcome {
        if options.restricted.contains(name) { return .restricted }
        guard let bytes = values[name] else { return .absent }
        return .value(SysctlValue(format: inventory.format(for: name), bytes: bytes))
    }

    public func oid(forName name: String) -> [Int32]? {
        if name == MIBWalker.defaultRoot { return [6, 110] }
        return walkOrder.firstIndex(of: name).map { [6, 110, Int32($0 + 1)] }
    }

    public func nextOID(after oid: [Int32]) -> NextOID {
        if options.walkRefused { return .failed(EPERM) }
        let next = oid.count > 2 ? Int(oid[2]) : 0
        return next < walkOrder.count ? .next([6, 110, Int32(next + 1)]) : .end
    }

    public func name(forOID oid: [Int32]) -> String? {
        guard oid.count == 3, oid[2] >= 1, Int(oid[2]) <= walkOrder.count else { return nil }
        return walkOrder[Int(oid[2]) - 1]
    }

    /// No kernel-declared formats in a text dump, as on iOS.
    public func format(forOID oid: [Int32]) -> OIDFormat? { nil }

    public func readOID(_ oid: [Int32]) -> ProbeOutcome {
        guard let name = name(forOID: oid) else { return .absent }
        return read(name)
    }
}
