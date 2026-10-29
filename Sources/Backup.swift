import Foundation
import CryptoKit
import CommonCrypto

enum BackupError: Error {
    case badPassword
    case corrupt
}

/// صيغة النسخة الاحتياطية:
/// "CLCBK1" + salt(16) ثم سلسلة إطارات AES-GCM، كل إطار = [نوع(1)][محتوى].
/// 0x00 تحقق، 0x01 فهرس JSON، 0x02 بداية ملف (UUID)، 0x03 بيانات، 0x04 نهاية ملف، 0x05 صورة مصغرة (UUID + JPEG)
enum Backup {
    static let magic = Data("CLCBK1".utf8)
    static let maxFrame = 1 << 26

    static func deriveKey(password: String, salt: Data) -> SymmetricKey {
        var out = [UInt8](repeating: 0, count: 32)
        let saltBytes = [UInt8](salt)
        _ = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            password,
            password.utf8.count,
            saltBytes,
            saltBytes.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            200_000,
            &out,
            32
        )
        return SymmetricKey(data: Data(out))
    }

    private static func record(_ type: UInt8, _ payload: Data, _ key: SymmetricKey) throws -> Data {
        var d = Data([type])
        d.append(payload)
        return try Crypto.sealedFrame(d, key: key)
    }

    private static func uuidData(_ id: UUID) -> Data {
        let u = id.uuid
        return Data([u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15])
    }

    private static func uuid(from d: Data) -> UUID? {
        guard d.count >= 16 else { return nil }
        let b = [UInt8](d.prefix(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    // MARK: export

    static func export(items: [VaultItem], filesDir: URL, thumbsDir: URL, vaultKey: SymmetricKey,
                       password: String, to dst: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dst)
        guard fm.createFile(atPath: dst.path, contents: nil) else { throw BackupError.corrupt }
        let out = try FileHandle(forWritingTo: dst)
        defer { try? out.close() }

        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, 16, base)
        }
        let bk = deriveKey(password: password, salt: salt)

        try out.write(contentsOf: magic)
        try out.write(contentsOf: salt)
        try out.write(contentsOf: record(0x00, Data("OK".utf8), bk))

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try out.write(contentsOf: record(0x01, try enc.encode(items), bk))

        for it in items where !it.isFolder {
            let src = filesDir.appendingPathComponent(it.id.uuidString)
            guard fm.fileExists(atPath: src.path) else { continue }

            try out.write(contentsOf: record(0x02, uuidData(it.id), bk))
            try Crypto.decryptChunks(from: src, key: vaultKey) { plain in
                try out.write(contentsOf: try record(0x03, plain, bk))
            }
            try out.write(contentsOf: record(0x04, Data(), bk))

            let t = thumbsDir.appendingPathComponent(it.id.uuidString)
            if let encThumb = try? Data(contentsOf: t),
               let jpg = try? Crypto.decryptData(encThumb, key: vaultKey) {
                try out.write(contentsOf: record(0x05, uuidData(it.id) + jpg, bk))
            }
        }
    }

    // MARK: restore

    static func restore(from src: URL, password: String, vaultKey: SymmetricKey,
                        filesDir: URL, thumbsDir: URL) throws -> [VaultItem] {
        let fm = FileManager.default
        let h = try FileHandle(forReadingFrom: src)
        defer { try? h.close() }

        guard let head = try h.read(upToCount: 22), head.count == 22,
              Data(head.prefix(6)) == magic else { throw BackupError.corrupt }
        let salt = Data(head.suffix(16))
        let bk = deriveKey(password: password, salt: salt)

        guard let first = try? Crypto.readFrame(from: h, key: bk, maxLen: maxFrame),
              first.first == 0x00 else { throw BackupError.badPassword }

        var items: [VaultItem] = []
        var cur: FileHandle?
        defer { try? cur?.close() }

        while true {
            guard let rec = try Crypto.readFrame(from: h, key: bk, maxLen: maxFrame) else { break }
            guard let type = rec.first else { continue }
            let payload = Data(rec.dropFirst())

            switch type {
            case 0x01:
                let dec = JSONDecoder()
                dec.dateDecodingStrategy = .iso8601
                items = try dec.decode([VaultItem].self, from: payload)

            case 0x02:
                try? cur?.close()
                cur = nil
                guard let id = uuid(from: payload) else { throw BackupError.corrupt }
                let dst = filesDir.appendingPathComponent(id.uuidString)
                try? fm.removeItem(at: dst)
                guard fm.createFile(atPath: dst.path, contents: nil) else { throw BackupError.corrupt }
                cur = try FileHandle(forWritingTo: dst)

            case 0x03:
                guard let c = cur else { throw BackupError.corrupt }
                try c.write(contentsOf: try Crypto.sealedFrame(payload, key: vaultKey))

            case 0x04:
                try? cur?.close()
                cur = nil

            case 0x05:
                guard let id = uuid(from: payload) else { continue }
                let jpg = Data(payload.dropFirst(16))
                let encThumb = try Crypto.encryptData(jpg, key: vaultKey)
                try encThumb.write(to: thumbsDir.appendingPathComponent(id.uuidString), options: .atomic)

            default:
                break
            }
        }
        return items
    }
}
