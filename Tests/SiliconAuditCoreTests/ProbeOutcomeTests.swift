import Foundation
import Testing
@testable import SiliconAuditCore

@Suite("ProbeOutcome and SysctlValue decoding")
struct ProbeOutcomeTests {
    @Test("errno mapping keeps absent, restricted, and other errors distinct")
    func errnoMapping() {
        #expect(ProbeOutcome(errno: ENOENT) == .absent)
        #expect(ProbeOutcome(errno: EPERM) == .restricted)
        #expect(ProbeOutcome(errno: EACCES) == .restricted)
        #expect(ProbeOutcome(errno: ENOTSUP) == .notApplicable)
        #expect(ProbeOutcome.notApplicable.errnoValue == ENOTSUP)
        #expect(ProbeOutcome(errno: EINVAL) == .error(EINVAL))
        #expect(ProbeOutcome(errno: ENOMEM) == .error(ENOMEM))
    }

    @Test("4-byte int decodes signed; hw.cpufamily round-trips to unsigned hex")
    func int32() {
        let v = SysctlValue(format: .int, bytes: le(UInt32(0xf76c_5b1a)))
        #expect(v.payload == .int(-143_893_734))
        #expect(v.length == 4)
        let unsigned = UInt32(bitPattern: Int32(v.payload.integerValue!))
        #expect(String(format: "0x%08x", unsigned) == "0xf76c5b1a")
    }

    @Test("unsigned format yields uint payload")
    func uint32() {
        let v = SysctlValue(format: .unsignedInt, bytes: le(UInt32(0xffff_ffff)))
        #expect(v.payload == .uint(0xffff_ffff))
        #expect(v.payload.integerValue == 0xffff_ffff)
    }

    @Test("8-byte quad and 8-byte long both decode as Int64")
    func int64() {
        #expect(SysctlValue(format: .quad, bytes: le(UInt64(137_438_953_472))).payload == .int(137_438_953_472))
        #expect(SysctlValue(format: .long, bytes: le(UInt64(bitPattern: -1))).payload == .int(-1))
    }

    @Test("declared int64_t but 12 bytes returned stays bytes (the caps trap)")
    func capsTrap() {
        let bytes = [UInt8](repeating: 0xab, count: 12)
        let v = SysctlValue(format: .quad, bytes: bytes)
        #expect(v.payload == .bytes(bytes))
        #expect(v.length == 12)
        #expect(v.hex == String(repeating: "ab", count: 12))
        #expect(ProbeOutcome.value(v).flagIsSet == nil, "a bitmask is not a flag")
    }

    @Test("declared int but wrong width is not guessed")
    func wrongWidth() {
        #expect(SysctlValue(format: .int, bytes: [1, 0]).payload == .bytes([1, 0]))
        #expect(SysctlValue(format: .int, bytes: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).payload.bytesValue?.count == 12)
    }

    @Test("strings drop trailing NULs and opaque stays bytes")
    func stringsAndOpaque() {
        #expect(SysctlValue(format: .string, bytes: Array("Mac17,7".utf8) + [0, 0]).payload == .string("Mac17,7"))
        #expect(SysctlValue(format: .opaque, bytes: [1, 2, 3]).payload == .bytes([1, 2, 3]))
        #expect(SysctlValue(format: nil, bytes: [1, 0, 0, 0]).payload == .bytes([1, 0, 0, 0]), "no format, no guessing")
    }

    @Test("flag interpretation: nonzero set, zero clear, non-integer nil")
    func flags() {
        #expect(ProbeOutcome.value(SysctlValue(format: .int, bytes: le(UInt32(1)))).flagIsSet == true)
        #expect(ProbeOutcome.value(SysctlValue(format: .int, bytes: le(UInt32(0)))).flagIsSet == false)
        #expect(ProbeOutcome.absent.flagIsSet == nil)
        #expect(ProbeOutcome.restricted.flagIsSet == nil)
        #expect(ProbeOutcome.value(SysctlValue(format: .string, bytes: [49, 0])).flagIsSet == nil)
    }

    @Test("OIDFMT reply parses kind word and format string")
    func oidfmtParse() {
        var reply = le(OIDFormat.Flags.readable | OIDFormat.Flags.masked | OIDFormat.CTLType.quad.rawValue)
        reply += Array("QU".utf8) + [0]
        let f = OIDFormat(oidfmtReply: reply)!
        #expect(f.type == .quad)
        #expect(f.isMasked)
        #expect(f.isUnsigned)
        #expect(f.typeName == "int64_t")
        #expect(OIDFormat(oidfmtReply: [1, 2]) == nil)
    }
}
