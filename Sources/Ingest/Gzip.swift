import Foundation
import Compression

/// Minimal gzip via Apple's Compression framework. The bundles are a few MB of
/// very repetitive JSON, so this is most of the "storage efficient" promise for
/// roughly twenty lines and no dependency.
public enum Gzip {
    public enum Failure: Error { case corrupt }

    private static let header: [UInt8] = [0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0x13]

    public static func compress(_ data: Data) throws -> Data {
        var out = Data(header)
        out.append(try codec(data, operation: COMPRESSION_STREAM_ENCODE))
        var crc = crc32(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }

    public static func decompress(_ data: Data) throws -> Data {
        guard data.count > 18, data[0] == 0x1f, data[1] == 0x8b else { throw Failure.corrupt }
        // Fixed 10-byte header; we only ever read files we wrote, which set no
        // optional fields.
        let body = data.subdata(in: 10..<(data.count - 8))
        return try codec(body, operation: COMPRESSION_STREAM_DECODE)
    }

    private static func codec(
        _ input: Data, operation: compression_stream_operation
    ) throws -> Data {
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
        else { throw Failure.corrupt }
        defer { compression_stream_destroy(&stream) }

        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var output = Data()
        let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)

        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw Failure.corrupt
            }
            stream.src_ptr = base
            stream.src_size = input.count
            repeat {
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize
                switch compression_stream_process(&stream, flags) {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    output.append(buffer, count: bufferSize - stream.dst_size)
                    if stream.dst_size != 0 { return }
                default:
                    throw Failure.corrupt
                }
            } while true
        }
        return output
    }

    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
