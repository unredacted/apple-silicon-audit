import Foundation

/// Type/format information for one sysctl OID, as returned by the kernel's
/// CTL_SYSCTL_OIDFMT meta node (`{0, 4, <oid...>}`).
///
/// The reply is a 32-bit `kind` word (CTLTYPE in the low nibble, CTLFLAG_* above)
/// followed by a NUL-terminated format string such as `I`, `IU`, `Q`, `L`, `A`, `S,foo`, `N`.
///
/// Constants below are copied from `<sys/sysctl.h>` in the macOS 26 SDK. The public
/// header does not name the CTL_SYSCTL_* meta nodes; those live in `SysctlMeta`.
public struct OIDFormat: Equatable, Hashable, Sendable {
    /// Raw kind word: CTLTYPE | CTLFLAG_*.
    public let kind: UInt32
    /// Format string, e.g. "I" (int), "IU" (unsigned int), "Q" (int64), "L" (long), "A" (string), "S,x" (struct), "N" (node).
    public let formatString: String

    public init(kind: UInt32, formatString: String) {
        self.kind = kind
        self.formatString = formatString
    }

    /// `CTLTYPE` values from `<sys/sysctl.h>`.
    public enum CTLType: UInt32, Sendable {
        case node = 1
        case int = 2
        case string = 3
        case quad = 4
        case opaque = 5
    }

    /// `CTLTYPE` mask and the flags this engine cares about, from `<sys/sysctl.h>`.
    public enum Flags {
        public static let typeMask: UInt32 = 0xf
        /// "deprecated variable, do not display" — hidden by sysctl(8), still returned by the kernel's NEXT walk.
        public static let masked: UInt32 = 0x0400_0000
        public static let readable: UInt32 = 0x8000_0000
        public static let anybody: UInt32 = 0x1000_0000
    }

    public var type: CTLType? { CTLType(rawValue: kind & Flags.typeMask) }
    public var isMasked: Bool { kind & Flags.masked != 0 }
    /// True when the format string marks the integer as unsigned (`IU`, `QU`, `LU`).
    public var isUnsigned: Bool { formatString.contains("U") }

    /// Byte width the format string promises for an integer OID: `I` → 4, `L` → pointer
    /// size (8 on every supported platform), `Q` → 8. Nil for non-integer types. A value
    /// whose returned length differs from this is kept as raw bytes (spec §4.1).
    public var declaredIntegerWidth: Int? {
        switch type {
        case .int:
            return formatString.hasPrefix("L") ? MemoryLayout<Int>.size : 4
        case .quad:
            return 8
        case .string, .opaque, .node, nil:
            return nil
        }
    }

    /// Name as sysctl(8) `-t` prints it, for display and export.
    public var typeName: String {
        switch type {
        case .node: return "node"
        case .int: return formatString.hasPrefix("L") ? "long" : "integer"
        case .string: return "string"
        case .quad: return "int64_t"
        case .opaque: return "opaque"
        case nil: return "unknown"
        }
    }

    // Convenience values for fixtures and tests.
    public static let int = OIDFormat(kind: Flags.readable | CTLType.int.rawValue, formatString: "I")
    public static let unsignedInt = OIDFormat(kind: Flags.readable | CTLType.int.rawValue, formatString: "IU")
    public static let long = OIDFormat(kind: Flags.readable | CTLType.int.rawValue, formatString: "L")
    public static let quad = OIDFormat(kind: Flags.readable | CTLType.quad.rawValue, formatString: "Q")
    public static let string = OIDFormat(kind: Flags.readable | CTLType.string.rawValue, formatString: "A")
    public static let opaque = OIDFormat(kind: Flags.readable | CTLType.opaque.rawValue, formatString: "S")
    public static let node = OIDFormat(kind: Flags.readable | CTLType.node.rawValue, formatString: "N")

    /// Parses an OIDFMT reply buffer. Returns nil if it is too short to hold the kind word.
    public init?(oidfmtReply bytes: [UInt8]) {
        guard bytes.count >= 4 else { return nil }
        let kind = UInt32(littleEndian: bytes[0..<4])
        let rest = bytes[4...].prefix { $0 != 0 }
        self.init(kind: kind, formatString: String(decoding: rest, as: UTF8.self))
    }
}

/// The CTL_SYSCTL meta node numbers under root OID 0. XNU registers 1–5; the public
/// SDK header does not export these names. `{0, 5}` (OIDDESCR) exists but returns
/// empty strings on XNU, so it is intentionally unused.
public enum SysctlMeta {
    public static let name: Int32 = 1
    public static let next: Int32 = 2
    public static let name2oid: Int32 = 3
    public static let oidfmt: Int32 = 4
    /// `CTL_MAXNAME` from `<sys/sysctl.h>`.
    public static let maxNameComponents = 12
}
