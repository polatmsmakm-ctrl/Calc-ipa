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

    static func remove(_ name: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name
        ]
        SecItemDelete(q as CFDictionary)
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

    static func remove(_ name: String) {
        Keychain.remove(name)
        try? FileManager.default.removeItem(at: fallbackDir.appendingPathComponent(".k_" + name))
    }

    /// مفتاح التشفير (256 بت) — يُنشأ مرة واحدة لكل خزنة (حقيقية / تمويه).
    static func masterKey(_ name: String = "mk") -> SymmetricKey {
        if let d = get(name), d.count == 32 { return SymmetricKey(data: d) }
        let k = SymmetricKey(size: .bits256)
        k.withUnsafeBytes { raw in
            set(Data(raw), name)
        }
        return k
    }
}

// MARK: - Passcodes (real / decoy / panic)

enum PasscodeKind: String, CaseIterable {
    case real = "pc"
    case decoy = "pd"
    case panic = "pp"
}

enum Passcode {
    static func isSet(_ kind: PasscodeKind = .real) -> Bool {
        SecretStore.get(kind.rawValue) != nil
    }

    static func set(_ code: String, kind: PasscodeKind = .real) {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { buf -> Int32 in
            guard let base = buf.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, 16, base)
        }
        let hash = Data(SHA256.hash(data: salt + Data(code.utf8)))
        SecretStore.set(salt + hash, kind.rawValue)
    }

    static func clear(_ kind: PasscodeKind) {
        SecretStore.remove(kind.rawValue)
    }

    static func verify(_ code: String, kind: PasscodeKind = .real) -> Bool {
        guard let blob = SecretStore.get(kind.rawValue), blob.count == 48 else { return false }
        let bytes = Array(blob)
        let salt = Data(bytes[0..<16])
        let stored = Data(bytes[16..<48])
        let h = Data(SHA256.hash(data: salt + Data(code.utf8)))
        return h == stored
    }

    /// أي رمز يطابق الرقم المكتوب؟
    static func match(_ code: String) -> PasscodeKind? {
        for k in [PasscodeKind.real, .decoy, .panic] where isSet(k) && verify(code, kind: k) {
            return k
        }
        return nil
    }

    /// هل الرمز مستخدم لنوع ثاني؟
    static func conflicts(_ code: String, except: PasscodeKind) -> Bool {
        for k in PasscodeKind.allCases where k != except && isSet(k) && verify(code, kind: k) {
            return true
        }
        return false
    }
}

// MARK: - Failed attempts / lockout / intruder log

enum Attempts {
    private static let d = UserDefaults.standard

    static var consecutive: Int { d.integer(forKey: "calc.fails") }
    static var total: Int { d.integer(forKey: "calc.failsTotal") }
    static var last: Date? { d.object(forKey: "calc.failLast") as? Date }
    static var lockUntil: Date? { d.object(forKey: "calc.lockUntil") as? Date }
    static var shots: Int { d.integer(forKey: "calc.shots") }

    static var isLocked: Bool {
        if let u = lockUntil { return u > Date() }
        return false
    }

    static func recordFail() {
        let n = consecutive + 1
        d.set(n, forKey: "calc.fails")
        d.set(total + 1, forKey: "calc.failsTotal")
        d.set(Date(), forKey: "calc.failLast")
        if n >= 5 {
            let mins = min(60, 1 << min(n - 5, 6))
            d.set(Date().addingTimeInterval(Double(mins) * 60), forKey: "calc.lockUntil")
        }
    }

    static func reset() {
        d.set(0, forKey: "calc.fails")
        d.removeObject(forKey: "calc.lockUntil")
    }

    static func recordShot() {
        d.set(shots + 1, forKey: "calc.shots")
    }

    static func clearLog() {
        d.set(0, forKey: "calc.fails")
        d.set(0, forKey: "calc.failsTotal")
        d.set(0, forKey: "calc.shots")
        d.removeObject(forKey: "calc.failLast")
        d.removeObject(forKey: "calc.lockUntil")
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

    /// [4 bytes length LE][sealed box]
    static func sealedFrame(_ plain: Data, key: SymmetricKey) throws -> Data {
        let c = try encryptData(plain, key: key)
        let n = c.count
        var out = Data([
            UInt8(n & 0xFF),
            UInt8((n >> 8) & 0xFF),
            UInt8((n >> 16) & 0xFF),
            UInt8((n >> 24) & 0xFF)
        ])
        out.append(c)
        return out
    }

    /// يقرأ إطاراً واحداً ويفك تشفيره. يرجع nil عند نهاية الملف.
    static func readFrame(from h: FileHandle, key: SymmetricKey, maxLen: Int) throws -> Data? {
        guard let headData = try h.read(upToCount: 4), headData.count == 4 else { return nil }
        let b = Array(headData)
        let len = Int(b[0]) | (Int(b[1]) << 8) | (Int(b[2]) << 16) | (Int(b[3]) << 24)
        guard len > 0, len <= maxLen else { throw CryptoError.corrupt }
        guard let blob = try h.read(upToCount: len), blob.count == len else { throw CryptoError.corrupt }
        return try decryptData(blob, key: key)
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
                try outH.write(contentsOf: try sealedFrame(d, key: key))
            }
            if done { break }
        }
    }

    /// يحفظ بيانات صغيرة في الذاكرة كملف مشفّر بنفس الصيغة.
    static func encryptDataToFile(_ d: Data, to dst: URL, key: SymmetricKey) throws {
        var out = Data()
        if d.isEmpty {
            out = try sealedFrame(Data(), key: key)
        } else {
            var i = 0
            while i < d.count {
                let end = min(i + chunkSize, d.count)
                out.append(try sealedFrame(d.subdata(in: i..<end), key: key))
                i = end
            }
        }
        try out.write(to: dst, options: .atomic)
    }

    static func decryptChunks(from src: URL, key: SymmetricKey, _ body: (Data) throws -> Void) throws {
        let inH = try FileHandle(forReadingFrom: src)
        defer { try? inH.close() }
        while true {
            var done = false
            try autoreleasepool { () throws -> Void in
                guard let plain = try readFrame(from: inH, key: key, maxLen: chunkSize + 64) else {
                    done = true
                    return
                }
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
