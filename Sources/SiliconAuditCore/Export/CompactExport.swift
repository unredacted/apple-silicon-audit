import Compression
import Foundation

/// Compact export wire format (SPEC §8): compact-variant JSON → zlib deflate → Base45
/// (RFC 9285, the alphabet QR alphanumeric mode encodes most densely). Used by the tvOS QR
/// export and the watch ShareLink fallback; decoded by the companion app and the CLI.
public enum CompactExport {
    public enum Error: Swift.Error, Equatable {
        case compressionFailed
        case decompressionFailed
        case invalidBase45
    }

    public static func encode(_ report: Report) throws -> String {
        let json = try report.compact().jsonData(pretty: false)
        let compressed = try compress(json)
        return Base45.encode(compressed)
    }

    public static func decode(_ text: String) throws -> Report {
        let compressed = try Base45.decode(text)
        let json = try decompress(compressed)
        return try Report.decode(json)
    }

    static func compress(_ data: Data) throws -> Data {
        try transcode(data, operation: COMPRESSION_STREAM_ENCODE, capacity: max(64, data.count), error: .compressionFailed)
    }

    static func decompress(_ data: Data) throws -> Data {
        try transcode(data, operation: COMPRESSION_STREAM_DECODE, capacity: max(1024, data.count * 8), error: .decompressionFailed)
    }

    private static func transcode(_ input: Data, operation: compression_stream_operation, capacity: Int, error: Error) throws -> Data {
        var output = Data()
        var dst = [UInt8](repeating: 0, count: capacity)
        try input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            var stream = compression_stream(dst_ptr: dst.withUnsafeMutableBufferPointer { $0.baseAddress! }, dst_size: 0,
                                            src_ptr: src.bindMemory(to: UInt8.self).baseAddress!, src_size: 0, state: nil)
            guard compression_stream_init(&stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw error }
            defer { compression_stream_destroy(&stream) }
            stream.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = src.count
            repeat {
                let status: compression_status = dst.withUnsafeMutableBufferPointer { buf in
                    stream.dst_ptr = buf.baseAddress!
                    stream.dst_size = buf.count
                    return compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                let produced = capacity - stream.dst_size
                output.append(contentsOf: dst[0..<produced])
                switch status {
                case COMPRESSION_STATUS_END: return
                case COMPRESSION_STATUS_OK: continue
                default: throw error
                }
            } while true
        }
        return output
    }
}

/// RFC 9285 Base45.
public enum Base45 {
    static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:")
    static let index: [Character: Int] = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })

    public static func encode(_ data: Data) -> String {
        var out: [Character] = []
        out.reserveCapacity(data.count * 3 / 2 + 3)
        let bytes = [UInt8](data)
        var i = 0
        while i + 1 < bytes.count {
            var n = Int(bytes[i]) * 256 + Int(bytes[i + 1])
            let c = n % 45; n /= 45
            let d = n % 45; n /= 45
            out.append(alphabet[c]); out.append(alphabet[d]); out.append(alphabet[n])
            i += 2
        }
        if i < bytes.count {
            let n = Int(bytes[i])
            out.append(alphabet[n % 45]); out.append(alphabet[n / 45])
        }
        return String(out)
    }

    public static func decode(_ text: String) throws -> Data {
        let chars = Array(text)
        guard chars.count % 3 != 1 else { throw CompactExport.Error.invalidBase45 }
        var out = Data()
        var i = 0
        while i < chars.count {
            let remaining = chars.count - i
            if remaining >= 3 {
                guard let c = index[chars[i]], let d = index[chars[i + 1]], let e = index[chars[i + 2]] else { throw CompactExport.Error.invalidBase45 }
                let n = c + d * 45 + e * 45 * 45
                guard n <= 0xFFFF else { throw CompactExport.Error.invalidBase45 }
                out.append(UInt8(n / 256)); out.append(UInt8(n % 256))
                i += 3
            } else {
                guard let c = index[chars[i]], let d = index[chars[i + 1]] else { throw CompactExport.Error.invalidBase45 }
                let n = c + d * 45
                guard n <= 0xFF else { throw CompactExport.Error.invalidBase45 }
                out.append(UInt8(n))
                i += 2
            }
        }
        return out
    }
}
