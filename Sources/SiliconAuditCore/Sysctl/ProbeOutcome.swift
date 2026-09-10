import Foundation

/// The decoded payload of a successful sysctl read.
public enum SysctlPayload: Equatable, Hashable, Sendable {
    /// Signed integer (`I`, `L`, `Q` formats of the matching width).
    case int(Int64)
    /// Unsigned integer (`IU`, `LU`, `QU` formats of the matching width).
    case uint(UInt64)
    /// NUL-terminated string (`A` format), trailing NULs stripped.
    case string(String)
    /// Anything else, including declared-integer values whose length does not match
    /// their declared width (the 12-byte `hw.optional.arm.caps` is the canonical case).
    case bytes([UInt8])

    /// Integer view when the payload is numeric and fits in Int64.
    public var integerValue: Int64? {
        switch self {
        case .int(let v): return v
        case .uint(let v): return v <= UInt64(Int64.max) ? Int64(v) : nil
        case .string, .bytes: return nil
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var bytesValue: [UInt8]? {
        if case .bytes(let b) = self { return b }
        return nil
    }
}

/// One successfully read sysctl value with everything needed to interpret it honestly.
public struct SysctlValue: Equatable, Hashable, Sendable {
    /// Declared type/format, if the kernel supplied it. Nil means OIDFMT was unavailable.
    public let format: OIDFormat?
    /// Actual byte count the kernel returned. Never assume this from `format`.
    public let length: Int
    public let payload: SysctlPayload
    /// Raw bytes exactly as returned, for export as hex and for re-decoding.
    public let rawBytes: [UInt8]

    public init(format: OIDFormat?, bytes: [UInt8]) {
        self.format = format
        self.length = bytes.count
        self.rawBytes = bytes
        self.payload = SysctlValue.decode(format: format, bytes: bytes)
    }

    /// Decoding rules (spec §4.1): trust the declared type only when the returned
    /// length matches it. Otherwise keep bytes.
    static func decode(format: OIDFormat?, bytes: [UInt8]) -> SysctlPayload {
        switch format?.type {
        case .string:
            let trimmed = bytes.reversed().drop { $0 == 0 }.reversed()
            return .string(String(decoding: trimmed, as: UTF8.self))
        case .int where bytes.count == 4, .quad where bytes.count == 8, .int where bytes.count == 8:
            return integer(bytes, unsigned: format?.isUnsigned ?? false)
        case .int, .quad, .opaque, .node, nil:
            return .bytes(bytes)
        }
    }

    private static func integer(_ bytes: [UInt8], unsigned: Bool) -> SysctlPayload {
        var raw: UInt64 = 0
        for (i, b) in bytes.enumerated() { raw |= UInt64(b) << (8 * UInt64(i)) }
        if unsigned { return .uint(raw) }
        switch bytes.count {
        case 4: return .int(Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: raw))))
        default: return .int(Int64(bitPattern: raw))
        }
    }

    /// Lowercase hex of the raw bytes, for export.
    public var hex: String { rawBytes.map { String(format: "%02x", $0) }.joined() }
}

/// Result of one sysctl read. The distinctions matter (spec §4.1): `absent` means the
/// kernel does not know the key; a zero value means it knows the key and reports it off.
public enum ProbeOutcome: Equatable, Hashable, Sendable {
    case value(SysctlValue)
    /// `ENOENT`: this kernel has no such key.
    case absent
    /// `EPERM` / `EACCES`: sandbox or kernel policy denied the read.
    case restricted
    /// `ENOTSUP`: the key is registered but does not apply to this architecture
    /// (the x86 `hw.optional.*` table on arm64, and vice versa). sysctl(8) hides these.
    case notApplicable
    /// Any other errno.
    case error(Int32)

    /// Maps an errno from a failed sysctl call.
    public init(errno code: Int32) {
        switch code {
        case ENOENT: self = .absent
        case EPERM, EACCES: self = .restricted
        case ENOTSUP: self = .notApplicable
        default: self = .error(code)
        }
    }

    public var value: SysctlValue? {
        if case .value(let v) = self { return v }
        return nil
    }

    /// The errno behind a failed outcome, or nil on success.
    public var errnoValue: Int32? {
        switch self {
        case .value: return nil
        case .absent: return ENOENT
        case .restricted: return EPERM
        case .notApplicable: return ENOTSUP
        case .error(let e): return e
        }
    }

    /// For flag-style keys: true when the value is a nonzero integer, false when zero,
    /// nil when there is no integer value to judge.
    public var flagIsSet: Bool? {
        guard let n = value?.payload.integerValue else { return nil }
        return n != 0
    }
}
