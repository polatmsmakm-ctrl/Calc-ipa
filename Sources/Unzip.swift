import Foundation
import Compression

enum ZipError: LocalizedError {
    case invalid, unsupported(String), encrypted

    var errorDescription: String? {
        switch self {
        case .invalid: return "ملف ZIP غير صالح"
        case .unsupported(let s): return s
        case .encrypted: return "الملف محمي بكلمة مرور"
        }
    }
}

/// فك ضغط ZIP بدون مكتبات خارجية (stored + deflate)، مع حماية من مسارات الخروج (zip-slip).
enum ZipReader {
    private struct Entry {
        var name: String
        var method: UInt16
        var flags: UInt16
        var compSize: UInt64
        var size: UInt64
        var offset: UInt64
    }

    private static func u16(_ d: Data, _ i: Int) -> UInt16 {
        UInt16(d[d.startIndex + i]) | (UInt16(d[d.startIndex + i + 1]) << 8)
    }
    private static func u32(_ d: Data, _ i: Int) -> UInt32 {
        UInt32(u16(d, i)) | (UInt32(u16(d, i + 2)) << 16)
    }

    /// يرجع عدد الملفات المفكوكة.
    @discardableResult
    static func extract(from zip: URL, to dest: URL) throws -> Int {
        let fh = try FileHandle(forReadingFrom: zip)
        defer { try? fh.close() }
        let fileSize = try fh.seekToEnd()
        guard fileSize >= 22 else { throw ZipError.invalid }

        // نهاية الدليل المركزي
        let tailLen = Int(min(fileSize, 66_000))
        try fh.seek(toOffset: fileSize - UInt64(tailLen))
        let tail = try fh.read(upToCount: tailLen) ?? Data()
        var eocd = -1
        var i = tail.count - 22
        while i >= 0 {
            if u32(tail, i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.invalid }
        let count = Int(u16(tail, eocd + 10))
        let cdSize = UInt64(u32(tail, eocd + 12))
        let cdOffset = UInt64(u32(tail, eocd + 16))
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            throw ZipError.unsupported("ملفات ZIP64 الضخمة غير مدعومة")
        }
        guard cdOffset + cdSize <= fileSize else { throw ZipError.invalid }

        try fh.seek(toOffset: cdOffset)
        let cd = try fh.read(upToCount: Int(cdSize)) ?? Data()

        var entries: [Entry] = []
        var p = 0
        while p + 46 <= cd.count, u32(cd, p) == 0x02014b50 {
            let flags = u16(cd, p + 8)
            let method = u16(cd, p + 10)
            let comp = UInt64(u32(cd, p + 20))
            let size = UInt64(u32(cd, p + 24))
            let nl = Int(u16(cd, p + 28)), el = Int(u16(cd, p + 30)), cl = Int(u16(cd, p + 32))
            let off = UInt64(u32(cd, p + 42))
            guard p + 46 + nl <= cd.count else { throw ZipError.invalid }
            let nameData = cd.subdata(in: (cd.startIndex + p + 46)..<(cd.startIndex + p + 46 + nl))
            let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? "file"
            entries.append(Entry(name: name, method: method, flags: flags, compSize: comp, size: size, offset: off))
            p += 46 + nl + el + cl
        }
        guard !entries.isEmpty else { throw ZipError.invalid }

        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let base = dest.standardizedFileURL.path
        var written = 0

        for e in entries {
            if e.flags & 1 != 0 { throw ZipError.encrypted }
            // تنظيف المسار
            let parts = e.name.replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
                .filter { $0 != "." && $0 != ".." }
            if parts.isEmpty || parts.first == "__MACOSX" { continue }
            let isDir = e.name.hasSuffix("/")
            var url = dest
            for part in parts { url.appendPathComponent(part) }
            guard url.standardizedFileURL.path.hasPrefix(base) else { continue }

            if isDir {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

            // رأس الملف المحلي
            try fh.seek(toOffset: e.offset)
            let lh = try fh.read(upToCount: 30) ?? Data()
            guard lh.count == 30, u32(lh, 0) == 0x04034b50 else { throw ZipError.invalid }
            let dataStart = e.offset + 30 + UInt64(u16(lh, 26)) + UInt64(u16(lh, 28))

            fm.createFile(atPath: url.path, contents: nil)
            let out = try FileHandle(forWritingTo: url)
            do {
                switch e.method {
                case 0: try copy(fh, from: dataStart, count: e.compSize, to: out)
                case 8: try inflate(fh, from: dataStart, count: e.compSize, to: out)
                default: throw ZipError.unsupported("طريقة ضغط غير مدعومة")
                }
                try out.close()
            } catch {
                try? out.close()
                throw error
            }
            written += 1
        }
        return written
    }

    private static func copy(_ fh: FileHandle, from off: UInt64, count: UInt64, to out: FileHandle) throws {
        try fh.seek(toOffset: off)
        var left = count
        while left > 0 {
            let n = Int(min(left, 256 * 1024))
            guard let d = try fh.read(upToCount: n), !d.isEmpty else { throw ZipError.invalid }
            try out.write(contentsOf: d)
            left -= UInt64(d.count)
        }
    }

    private static func inflate(_ fh: FileHandle, from off: UInt64, count: UInt64, to out: FileHandle) throws {
        let dummy = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { dummy.deallocate() }
        var stream = compression_stream(dst_ptr: dummy, dst_size: 0, src_ptr: UnsafePointer(dummy), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError.invalid
        }
        defer { compression_stream_destroy(&stream) }

        let outCap = 256 * 1024
        var outBuf = [UInt8](repeating: 0, count: outCap)
        try fh.seek(toOffset: off)
        var remaining = count
        var finished = false

        while !finished {
            var chunk = Data()
            if remaining > 0 {
                chunk = try fh.read(upToCount: Int(min(remaining, 64 * 1024))) ?? Data()
                if chunk.isEmpty { throw ZipError.invalid }
                remaining -= UInt64(chunk.count)
            }
            let isFinal = remaining == 0
            let flags: Int32 = isFinal ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0

            try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(dummy)
                stream.src_size = chunk.count
                var more = true
                while more {
                    var produced = 0
                    var status = COMPRESSION_STATUS_OK
                    try outBuf.withUnsafeMutableBufferPointer { ob in
                        stream.dst_ptr = ob.baseAddress!
                        stream.dst_size = outCap
                        status = compression_stream_process(&stream, flags)
                        produced = outCap - stream.dst_size
                        if produced > 0 {
                            try out.write(contentsOf: Data(bytes: ob.baseAddress!, count: produced))
                        }
                    }
                    if status == COMPRESSION_STATUS_ERROR { throw ZipError.invalid }
                    if status == COMPRESSION_STATUS_END { finished = true; more = false }
                    else { more = stream.src_size > 0 || produced == outCap }
                }
            }
            if isFinal { finished = true }
        }
    }
}
