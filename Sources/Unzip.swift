import Foundation
import Compression

enum ZipError: LocalizedError {
    case invalid, unsupported(String), encrypted, noSpace

    var errorDescription: String? {
        switch self {
        case .invalid: return "ملف الأرشيف غير صالح"
        case .unsupported(let s): return s
        case .encrypted: return "الملف محمي بكلمة مرور"
        case .noSpace: return "المساحة على الجوال لا تكفي"
        }
    }
}

struct ZipEntry {
    var name: String
    var method: UInt16
    var flags: UInt16
    var compSize: UInt64
    var size: UInt64
    var offset: UInt64
    var isDir: Bool { name.hasSuffix("/") }

    /// مسار آمن (بدون .. أو مجلدات نظام) كمكوّنات.
    var parts: [String] {
        name.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." && $0 != ".." }
    }
}

/// قارئ ZIP (يدعم ZIP64، stored + deflate) بدون مكتبات خارجية، ويعمل بالتدفق فلا يحمّل الملف بالذاكرة.
enum ZipReader {
    private static func u16(_ d: Data, _ i: Int) -> UInt16 {
        UInt16(d[d.startIndex + i]) | (UInt16(d[d.startIndex + i + 1]) << 8)
    }
    private static func u32(_ d: Data, _ i: Int) -> UInt32 {
        UInt32(u16(d, i)) | (UInt32(u16(d, i + 2)) << 16)
    }
    private static func u64(_ d: Data, _ i: Int) -> UInt64 {
        UInt64(u32(d, i)) | (UInt64(u32(d, i + 4)) << 32)
    }

    static func entries(of zip: URL) throws -> [ZipEntry] {
        let fh = try FileHandle(forReadingFrom: zip)
        defer { try? fh.close() }
        let fileSize = try fh.seekToEnd()
        guard fileSize >= 22 else { throw ZipError.invalid }

        let tailLen = Int(min(fileSize, 70_000))
        try fh.seek(toOffset: fileSize - UInt64(tailLen))
        let tail = try fh.read(upToCount: tailLen) ?? Data()
        var eocd = -1
        var i = tail.count - 22
        while i >= 0 {
            if u32(tail, i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.invalid }

        var count = UInt64(u16(tail, eocd + 10))
        var cdSize = UInt64(u32(tail, eocd + 12))
        var cdOffset = UInt64(u32(tail, eocd + 16))

        // ZIP64
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            let loc = eocd - 20
            guard loc >= 0, u32(tail, loc) == 0x07064b50 else { throw ZipError.invalid }
            let z64 = u64(tail, loc + 8)
            try fh.seek(toOffset: z64)
            let rec = try fh.read(upToCount: 56) ?? Data()
            guard rec.count >= 56, u32(rec, 0) == 0x06064b50 else { throw ZipError.invalid }
            count = u64(rec, 32)
            cdSize = u64(rec, 40)
            cdOffset = u64(rec, 48)
        }
        guard cdOffset + cdSize <= fileSize, cdSize < 1_500_000_000 else { throw ZipError.invalid }

        try fh.seek(toOffset: cdOffset)
        let cd = try fh.read(upToCount: Int(cdSize)) ?? Data()

        var out: [ZipEntry] = []
        out.reserveCapacity(Int(min(count, 200_000)))
        var p = 0
        while p + 46 <= cd.count, u32(cd, p) == 0x02014b50 {
            let flags = u16(cd, p + 8)
            let method = u16(cd, p + 10)
            var comp = UInt64(u32(cd, p + 20))
            var size = UInt64(u32(cd, p + 24))
            let nl = Int(u16(cd, p + 28)), el = Int(u16(cd, p + 30)), cl = Int(u16(cd, p + 32))
            var off = UInt64(u32(cd, p + 42))
            guard p + 46 + nl + el <= cd.count else { throw ZipError.invalid }

            let nameData = cd.subdata(in: (cd.startIndex + p + 46)..<(cd.startIndex + p + 46 + nl))
            let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? "file"

            // حقل ZIP64 الإضافي
            if size == 0xFFFF_FFFF || comp == 0xFFFF_FFFF || off == 0xFFFF_FFFF {
                var q = p + 46 + nl
                let end = q + el
                while q + 4 <= end {
                    let id = u16(cd, q), len = Int(u16(cd, q + 2))
                    if id == 0x0001 {
                        var r = q + 4
                        if size == 0xFFFF_FFFF, r + 8 <= end { size = u64(cd, r); r += 8 }
                        if comp == 0xFFFF_FFFF, r + 8 <= end { comp = u64(cd, r); r += 8 }
                        if off == 0xFFFF_FFFF, r + 8 <= end { off = u64(cd, r); r += 8 }
                        break
                    }
                    q += 4 + len
                }
            }
            out.append(ZipEntry(name: name, method: method, flags: flags, compSize: comp, size: size, offset: off))
            p += 46 + nl + el + cl
        }
        guard !out.isEmpty else { throw ZipError.invalid }
        return out
    }

    /// يفك ملفاً واحداً إلى المسار المعطى.
    static func extract(_ e: ZipEntry, from zip: URL, to url: URL) throws {
        if e.flags & 1 != 0 { throw ZipError.encrypted }
        let fh = try FileHandle(forReadingFrom: zip)
        defer { try? fh.close() }
        try fh.seek(toOffset: e.offset)
        let lh = try fh.read(upToCount: 30) ?? Data()
        guard lh.count == 30, u32(lh, 0) == 0x04034b50 else { throw ZipError.invalid }
        let dataStart = e.offset + 30 + UInt64(u16(lh, 26)) + UInt64(u16(lh, 28))

        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        do {
            switch e.method {
            case 0: try copy(fh, from: dataStart, count: e.compSize, to: out)
            case 8: try inflate(fh, from: dataStart, count: e.compSize, to: out)
            default: throw ZipError.unsupported("طريقة الضغط (\(e.method)) غير مدعومة")
            }
            try out.close()
        } catch {
            try? out.close()
            throw error
        }
    }

    private static func copy(_ fh: FileHandle, from off: UInt64, count: UInt64, to out: FileHandle) throws {
        try fh.seek(toOffset: off)
        var left = count
        while left > 0 {
            let n = Int(min(left, 512 * 1024))
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

        let outCap = 512 * 1024
        var outBuf = [UInt8](repeating: 0, count: outCap)
        try fh.seek(toOffset: off)
        var remaining = count
        var finished = false

        while !finished {
            var chunk = Data()
            if remaining > 0 {
                chunk = try fh.read(upToCount: Int(min(remaining, 256 * 1024))) ?? Data()
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

// MARK: - Writer

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }
    static func update(_ crc: UInt32, _ data: UnsafeBufferPointer<UInt8>) -> UInt32 {
        var c = crc
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c
    }
}

/// كاتب ZIP بالتدفق (deflate). كل ملف حتى 4GB.
final class ZipWriter {
    private let fh: FileHandle
    private var offset: UInt64 = 0
    private var central = Data()
    private var count = 0

    init(to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fh = try FileHandle(forWritingTo: url)
    }

    private func put16(_ d: inout Data, _ v: UInt16) { d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8)) }
    private func put32(_ d: inout Data, _ v: UInt32) { put16(&d, UInt16(v & 0xFFFF)); put16(&d, UInt16(v >> 16)) }

    private func write(_ d: Data) throws {
        try fh.write(contentsOf: d)
        offset += UInt64(d.count)
    }

    func addDirectory(_ path: String) throws {
        let name = (path.hasSuffix("/") ? path : path + "/").data(using: .utf8) ?? Data()
        let lhOffset = offset
        var h = Data()
        put32(&h, 0x04034b50); put16(&h, 20); put16(&h, 0x0800); put16(&h, 0)
        put16(&h, 0); put16(&h, 0x21); put32(&h, 0); put32(&h, 0); put32(&h, 0)
        put16(&h, UInt16(name.count)); put16(&h, 0)
        h.append(name)
        try write(h)
        appendCentral(name: name, flags: 0x0800, method: 0, crc: 0, comp: 0, size: 0, lhOffset: lhOffset, dir: true)
    }

    func addFile(_ path: String, from src: URL) throws {
        let name = path.data(using: .utf8) ?? Data()
        let lhOffset = offset
        var h = Data()
        // flag 3 = data descriptor، flag 11 = UTF-8
        put32(&h, 0x04034b50); put16(&h, 20); put16(&h, 0x0808); put16(&h, 8)
        put16(&h, 0); put16(&h, 0x21); put32(&h, 0); put32(&h, 0); put32(&h, 0)
        put16(&h, UInt16(name.count)); put16(&h, 0)
        h.append(name)
        try write(h)

        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }

        let dummy = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { dummy.deallocate() }
        var stream = compression_stream(dst_ptr: dummy, dst_size: 0, src_ptr: UnsafePointer(dummy), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError.invalid
        }
        defer { compression_stream_destroy(&stream) }

        var crc: UInt32 = 0xFFFF_FFFF
        var total: UInt64 = 0
        var comp: UInt64 = 0
        let outCap = 256 * 1024
        var outBuf = [UInt8](repeating: 0, count: outCap)
        var done = false

        while !done {
            let chunk = try input.read(upToCount: 256 * 1024) ?? Data()
            let isFinal = chunk.isEmpty
            total += UInt64(chunk.count)
            if total >= 0xFFFF_FFFF { throw ZipError.unsupported("ملف أكبر من 4GB لا يمكن ضغطه هنا") }
            chunk.withUnsafeBytes { raw in
                let b = raw.bindMemory(to: UInt8.self)
                crc = CRC32.update(crc, b)
            }
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
                            try write(Data(bytes: ob.baseAddress!, count: produced))
                            comp += UInt64(produced)
                        }
                    }
                    if status == COMPRESSION_STATUS_ERROR { throw ZipError.invalid }
                    if status == COMPRESSION_STATUS_END { done = true; more = false }
                    else { more = stream.src_size > 0 || produced == outCap }
                }
            }
            if isFinal { done = true }
        }
        crc ^= 0xFFFF_FFFF
        guard offset < 0xFFFF_FFFF else { throw ZipError.unsupported("الأرشيف أكبر من 4GB") }

        var dd = Data()
        put32(&dd, 0x08074b50); put32(&dd, crc); put32(&dd, UInt32(comp)); put32(&dd, UInt32(total))
        try write(dd)
        appendCentral(name: name, flags: 0x0808, method: 8, crc: crc, comp: UInt32(comp), size: UInt32(total), lhOffset: lhOffset, dir: false)
    }

    private func appendCentral(name: Data, flags: UInt16, method: UInt16, crc: UInt32, comp: UInt32, size: UInt32, lhOffset: UInt64, dir: Bool) {
        var c = central
        put32(&c, 0x02014b50); put16(&c, 20); put16(&c, 20); put16(&c, flags); put16(&c, method)
        put16(&c, 0); put16(&c, 0x21); put32(&c, crc); put32(&c, comp); put32(&c, size)
        put16(&c, UInt16(name.count)); put16(&c, 0); put16(&c, 0); put16(&c, 0); put16(&c, 0)
        put32(&c, dir ? 0x10 : 0); put32(&c, UInt32(truncatingIfNeeded: lhOffset))
        c.append(name)
        central = c
        count += 1
    }

    func finish() throws {
        let cdStart = offset
        try write(central)
        var e = Data()
        put32(&e, 0x06054b50); put16(&e, 0); put16(&e, 0)
        put16(&e, UInt16(min(count, 0xFFFF))); put16(&e, UInt16(min(count, 0xFFFF)))
        put32(&e, UInt32(central.count)); put32(&e, UInt32(truncatingIfNeeded: cdStart)); put16(&e, 0)
        try write(e)
        try fh.close()
    }
}
