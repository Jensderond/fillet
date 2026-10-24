import Compression
import Foundation

/// CRC-32 (IEEE 802.3, as used by ZIP).
public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for byte in buf { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// Errors writing a ZIP archive.
public enum ZipError: Error, Hashable, Sendable {
    /// An entry or the archive exceeds the 4 GB limit of non-ZIP64 archives.
    case tooLarge
}

/// Minimal ZIP archive writer (no ZIP64, no encryption): stored or raw-DEFLATE
/// entries, CRC-32, local headers, central directory and end record.
public struct ZipWriter: Sendable {
    public enum Method: Sendable {
        case stored
        /// Raw DEFLATE via Apple's Compression framework; falls back to
        /// stored when it does not make the entry smaller.
        case deflate
    }

    private struct Entry {
        var name: Data
        var method: UInt16
        var crc: UInt32
        var compressedSize: UInt32
        var size: UInt32
        var offset: UInt32
    }

    private var body = Data()
    private var entries: [Entry] = []
    private let dosTime: UInt16
    private let dosDate: UInt16

    /// - Parameter date: modification time stamped on every entry.
    public init(date: Date = Date()) {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone.current, from: date)
        let year = max(1980, min(2107, parts.year ?? 1980))
        dosDate = UInt16((year - 1980) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        dosTime = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
    }

    /// Appends a file. `path` uses forward slashes, no leading slash.
    public mutating func add(path: String, data: Data, method: Method = .deflate) throws {
        guard data.count < Int(UInt32.max), body.count < Int(UInt32.max) else { throw ZipError.tooLarge }
        let name = Data(path.utf8)
        var payload = data
        var methodCode: UInt16 = 0
        if method == .deflate, let compressed = ZipWriter.deflate(data), compressed.count < data.count {
            payload = compressed
            methodCode = 8
        }
        let entry = Entry(
            name: name, method: methodCode, crc: CRC32.checksum(data), compressedSize: UInt32(payload.count),
            size: UInt32(data.count), offset: UInt32(body.count))

        var header = Data()
        header.append(le32: 0x0403_4B50)
        header.append(le16: 20)  // version needed
        header.append(le16: 0x0800)  // UTF-8 names
        header.append(le16: entry.method)
        header.append(le16: dosTime)
        header.append(le16: dosDate)
        header.append(le32: entry.crc)
        header.append(le32: entry.compressedSize)
        header.append(le32: entry.size)
        header.append(le16: UInt16(name.count))
        header.append(le16: 0)  // extra length
        header.append(name)
        body.append(header)
        body.append(payload)
        entries.append(entry)
    }

    /// The complete archive.
    public func finish() throws -> Data {
        var central = Data()
        for e in entries {
            central.append(le32: 0x0201_4B50)
            central.append(le16: 20)  // version made by
            central.append(le16: 20)  // version needed
            central.append(le16: 0x0800)
            central.append(le16: e.method)
            central.append(le16: dosTime)
            central.append(le16: dosDate)
            central.append(le32: e.crc)
            central.append(le32: e.compressedSize)
            central.append(le32: e.size)
            central.append(le16: UInt16(e.name.count))
            central.append(le16: 0)  // extra
            central.append(le16: 0)  // comment
            central.append(le16: 0)  // disk number
            central.append(le16: 0)  // internal attributes
            central.append(le32: 0)  // external attributes
            central.append(le32: e.offset)
            central.append(e.name)
        }
        guard body.count + central.count < Int(UInt32.max), entries.count < Int(UInt16.max) else {
            throw ZipError.tooLarge
        }
        var out = body
        out.append(central)
        out.append(le32: 0x0605_4B50)
        out.append(le16: 0)  // this disk
        out.append(le16: 0)  // central directory disk
        out.append(le16: UInt16(entries.count))
        out.append(le16: UInt16(entries.count))
        out.append(le32: UInt32(central.count))
        out.append(le32: UInt32(body.count))
        out.append(le16: 0)  // comment length
        return out
    }

    /// Raw DEFLATE (RFC 1951) — what `COMPRESSION_ZLIB` produces.
    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + data.count / 8 + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                    let s = src.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_encode_buffer(d, capacity, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.count = written
        return out
    }
}

extension Data {
    mutating func append(le16 v: UInt16) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append(le32 v: UInt32) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append(leFloat v: Float) { append(le32: v.bitPattern) }
}
