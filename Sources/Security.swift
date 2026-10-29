import Foundation
import Security
import CryptoKit
import LocalAuthentication

// MARK: - Keychain + fallback

enum Keychain {
    static let service = "com.rashid.calc.store"

    static func set(_ data: Data, for name: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ name: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}

enum SecretStore {
    private static var fallbackDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CalcCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func get(_ name: String) -> Data? {
        if let d = Keychain.get(name) { return d }
        return try? Data(contentsOf: fallbackDir.appendingPathComponent(".k_" + name))
    }

    static func set(_ data: Data, _ name: String) {
        let f = fallbackDir.appendingPathComponent(".k_" + name)
        if Keychain.set(data, for: name) {
            try? FileManager.default.removeItem(at: f)
        } else {
            try? data.write(to: f, options: [.atomic])
        }
    }

    /// المفتاح الرئيسي للتشفير (256 بت) — يُنشأ مرة واحدة.
    static func masterKey() -> SymmetricKey {
        if let d = get("mk"), d.count == 32 { return SymmetricKey(data: d) }
        let k = SymmetricKey(size: .bits256)
        k.withUnsafeBytes { raw in
            set(Data(raw), "mk")
        }
        return k
    }
}

// MARK: - Passcode

enum Passcode {
    static var isSet: Bool { SecretStore.get("pc") != nil }

    static func set(_ code: String) {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, 16, base)
        }
        let hash = Data(SHA256.hash(data: salt + Data(code.utf8)))
        SecretStore.set(salt + hash, "pc")
    }

    static func verify(_ code: String) -> Bool {
        guard let blob = SecretStore.get("pc"), blob.count == 48 else { return false }
        let bytes = Array(blob)
        let salt = Data(bytes[0..<16])
        let stored = Data(bytes[16..<48])
        let h = Data(SHA256.hash(data: salt + Data(code.utf8)))
        return h == stored
    }
}

// MARK: - Biometrics

enum Bio {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "calc.bio") }
        set { UserDefaults.standard.set(newValue, forKey: "calc.bio") }
    }

    static var available: Bool {
        var e: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &e)
    }

    static func authenticate(_ done: @escaping (Bool) -> Void) {
        let ctx = LAContext()
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "تأكيد الهوية") { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }
}

// MARK: - Crypto (AES-GCM, chunked)

enum CryptoError: Error { case corrupt }

enum Crypto {
    static let chunkSize = 1 << 20

    static func encryptData(_ d: Data, key: SymmetricKey) throws -> Data {
        guard let c = try AES.GCM.seal(d, using: key).combined else { throw CryptoError.corrupt }
        return c
    }

    static func decryptData(_ d: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: d)
        return try AES.GCM.open(box, using: key)
    }

    static func encryptFile(from src: URL, to dst: URL, key: SymmetricKey) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dst)
        guard fm.createFile(atPath: dst.path, contents: nil) else { throw CryptoError.corrupt }
        let inH = try FileHandle(forReadingFrom: src)
        let outH = try FileHandle(forWritingTo: dst)
        defer {
            try? inH.close()
            try? outH.close()
        }
        while true {
            var done = false
            try autoreleasepool { () throws -> Void in
                let d = try inH.read(upToCount: chunkSize) ?? Data()
                if d.isEmpty { done = true; return }
                let c = try encryptData(d, key: key)
                let n = c.count
                let head = Data([
                    UInt8(n & 0xFF),
                    UInt8((n >> 8) & 0xFF),
                    UInt8((n >> 16) & 0xFF),
                    UInt8((n >> 24) & 0xFF)
                ])
                try outH.write(contentsOf: head)
                try outH.write(contentsOf: c)
            }
            if done { break }
        }
    }

    static func decryptChunks(from src: URL, key: SymmetricKey, _ body: (Data) throws -> Void) throws {
        let inH = try FileHandle(forReadingFrom: src)
        defer { try? inH.close() }
        while true {
            var done = false
            try autoreleasepool { () throws -> Void in
                guard let headData = try inH.read(upToCount: 4), headData.count == 4 else {
                    done = true
                    return
                }
                let h = Array(headData)
                let len = Int(h[0]) | (Int(h[1]) << 8) | (Int(h[2]) << 16) | (Int(h[3]) << 24)
                guard len > 0, len <= chunkSize + 64 else { throw CryptoError.corrupt }
                guard let blob = try inH.read(upToCount: len), blob.count == len else { throw CryptoError.corrupt }
                let plain = try decryptData(blob, key: key)
                try body(plain)
            }
            if done { break }
        }
    }

    static func decryptFile(from src: URL, to dst: URL, key: SymmetricKey) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dst)
        guard fm.createFile(atPath: dst.path, contents: nil) else { throw CryptoError.corrupt }
        let outH = try FileHandle(forWritingTo: dst)
        defer { try? outH.close() }
        try decryptChunks(from: src, key: key) { plain in
            try outH.write(contentsOf: plain)
        }
    }

    static func decryptFileToData(from src: URL, key: SymmetricKey) throws -> Data {
        var out = Data()
        try decryptChunks(from: src, key: key) { plain in
            out.append(plain)
        }
        return out
    }
}
