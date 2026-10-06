import Foundation
import CZlib

/// zlib による展開。ZIP エントリ (生 deflate) と Kindle フォント (zlib ヘッダー付き) の両方で使う。
enum Inflate {
    enum Format {
        /// zlib ヘッダー無しの生 deflate (ZIP)。
        case raw
        /// zlib ヘッダー付き。
        case zlib
    }

    static func inflate(_ input: [UInt8], format: Format, expectedSize: Int = 0) throws -> [UInt8] {
        if input.isEmpty { return [] }
        var stream = z_stream()
        let windowBits: Int32 = format == .raw ? -15 : 15
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw BookError.invalidData("Failed to initialize zlib.")
        }
        defer { inflateEnd(&stream) }

        var output: [UInt8] = []
        output.reserveCapacity(expectedSize > 0 ? expectedSize : input.count * 4)
        let chunkSize = 64 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var inputCopy = input
        var status: Int32 = Z_OK
        try inputCopy.withUnsafeMutableBufferPointer { inBuf in
            stream.next_in = inBuf.baseAddress
            stream.avail_in = UInt32(inBuf.count)
            repeat {
                let produced: Int = try chunk.withUnsafeMutableBufferPointer { outBuf in
                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = UInt32(chunkSize)
                    status = CZlib.inflate(&stream, Z_NO_FLUSH)
                    if status != Z_OK && status != Z_STREAM_END && status != Z_BUF_ERROR {
                        throw BookError.invalidData("Corrupt deflate data (zlib \(status)).")
                    }
                    return chunkSize - Int(stream.avail_out)
                }
                output.append(contentsOf: chunk[0..<produced])
                if status == Z_BUF_ERROR && produced == 0 { break }
            } while status != Z_STREAM_END && (stream.avail_in > 0 || stream.avail_out == 0)
        }
        return output
    }
}
