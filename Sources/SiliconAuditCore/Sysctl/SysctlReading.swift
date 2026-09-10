import Darwin
import Foundation

/// Result of one CTL_SYSCTL_NEXT step. `end` (ENOENT) is the only normal way a walk
/// finishes; `failed` after some keys means the inventory is partial, not complete.
public enum NextOID: Equatable, Sendable {
    case next([Int32])
    case end
    case failed(Int32)
}

/// Everything the engine needs from sysctl, as a protocol so fixtures can stand in
/// for a live kernel. `LiveSysctl` is the real thing; tests provide fakes.
public protocol SysctlReading: Sendable {
    /// Read a key by name (size query, then read). Format is attached when available.
    func read(_ name: String) -> ProbeOutcome
    /// Name → OID, or nil if the kernel does not know the name.
    func oid(forName name: String) -> [Int32]?
    /// The next OID in tree order after `oid` (descends into nodes), `.end` at the end,
    /// or `.failed(errno)` when the kernel refused the step.
    func nextOID(after oid: [Int32]) -> NextOID
    /// OID → dotted name, or nil if unresolvable.
    func name(forOID oid: [Int32]) -> String?
    /// Declared type/format for an OID, or nil if unavailable.
    func format(forOID oid: [Int32]) -> OIDFormat?
    /// Read a value by OID (size query, then read).
    func readOID(_ oid: [Int32]) -> ProbeOutcome
}

/// The real kernel, via `sysctlbyname(3)`, `sysctlnametomib(3)`, and the raw
/// `sysctl(2)` meta nodes. Pure POSIX; no platform conditionals.
public struct LiveSysctl: SysctlReading {
    public init() {}

    public func read(_ name: String) -> ProbeOutcome {
        var size = 0
        if sysctlbyname(name, nil, &size, nil, 0) != 0 {
            return ProbeOutcome(errno: errno)
        }
        // Some handlers report 0 on a size probe; give them a generous buffer.
        var buffer = [UInt8](repeating: 0, count: size > 0 ? size : 4096)
        var attempts = 0
        while true {
            size = buffer.count
            if sysctlbyname(name, &buffer, &size, nil, 0) == 0 {
                let format = oid(forName: name).flatMap { self.format(forOID: $0) }
                return .value(SysctlValue(format: format, bytes: Array(buffer[0..<size])))
            }
            let err = errno
            attempts += 1
            guard err == ENOMEM, attempts < 4 else { return ProbeOutcome(errno: err) }
            buffer = [UInt8](repeating: 0, count: buffer.count * 2)
        }
    }

    public func oid(forName name: String) -> [Int32]? {
        var mib = [Int32](repeating: 0, count: SysctlMeta.maxNameComponents)
        var count = mib.count
        guard sysctlnametomib(name, &mib, &count) == 0 else { return nil }
        return Array(mib[0..<count])
    }

    public func nextOID(after oid: [Int32]) -> NextOID {
        switch metaResult(SysctlMeta.next, oid) {
        case .failure(let err):
            return err == ENOENT ? .end : .failed(err)
        case .success(let bytes):
            guard bytes.count % 4 == 0, !bytes.isEmpty else { return .failed(EINVAL) }
            return .next(stride(from: 0, to: bytes.count, by: 4).map { i in
                Int32(bitPattern: UInt32(littleEndian: bytes[i..<(i + 4)]))
            })
        }
    }

    public func name(forOID oid: [Int32]) -> String? {
        guard let bytes = meta(SysctlMeta.name, oid) else { return nil }
        let s = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    public func format(forOID oid: [Int32]) -> OIDFormat? {
        meta(SysctlMeta.oidfmt, oid).flatMap(OIDFormat.init(oidfmtReply:))
    }

    public func readOID(_ oid: [Int32]) -> ProbeOutcome {
        var mib = oid
        var size = 0
        if sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) != 0 {
            return ProbeOutcome(errno: errno)
        }
        var buffer = [UInt8](repeating: 0, count: size > 0 ? size : 4096)
        var attempts = 0
        while true {
            size = buffer.count
            if sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 {
                return .value(SysctlValue(format: format(forOID: oid), bytes: Array(buffer[0..<size])))
            }
            let err = errno
            attempts += 1
            guard err == ENOMEM, attempts < 4 else { return ProbeOutcome(errno: err) }
            buffer = [UInt8](repeating: 0, count: buffer.count * 2)
        }
    }

    /// Calls meta node `{0, op, oid...}` with a fixed 4 KiB reply buffer, the way
    /// sysctl(8) does; the meta handlers do not all support size probing.
    private func meta(_ op: Int32, _ oid: [Int32]) -> [UInt8]? {
        try? metaResult(op, oid).get()
    }

    private func metaResult(_ op: Int32, _ oid: [Int32]) -> Result<[UInt8], Int32> {
        var mib: [Int32] = [0, op] + oid
        var buffer = [UInt8](repeating: 0, count: 4096)
        var size = buffer.count
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return .failure(errno) }
        return .success(Array(buffer[0..<size]))
    }
}

extension UInt32 {
    /// Assembles a little-endian 32-bit word from exactly four bytes.
    init(littleEndian slice: ArraySlice<UInt8>) {
        var v: UInt32 = 0
        for (shift, b) in slice.enumerated() { v |= UInt32(b) << (8 * UInt32(shift)) }
        self = v
    }
}

/// Lets `Result<_, Int32>` carry an errno.
extension Int32: @retroactive Error {}
