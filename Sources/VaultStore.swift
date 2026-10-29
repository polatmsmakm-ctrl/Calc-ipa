import SwiftUI
import CryptoKit
import AVFoundation
import ImageIO
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Model

struct VaultItem: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var isFolder: Bool
    var parent: UUID?
    var size: Int64
    var date: Date
    var ext: String

    var isImage: Bool { !isFolder && Kind.isImage(ext) }
    var isVideo: Bool { !isFolder && Kind.isVideo(ext) }
}

struct FolderChoice: Identifiable {
    let item: VaultItem
    let path: String
    var id: UUID { item.id }
}

enum Kind {
    static let images: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tiff", "tif"]
    static let videos: Set<String> = ["mov", "mp4", "m4v"]

    static func isImage(_ e: String) -> Bool { images.contains(e.lowercased()) }
    static func isVideo(_ e: String) -> Bool { videos.contains(e.lowercased()) }

    static func icon(for item: VaultItem) -> String {
        if item.isFolder { return "folder.fill" }
        switch item.ext.lowercased() {
        case "pdf": return "doc.richtext"
        case "mp3", "m4a", "wav", "aac", "flac": return "waveform"
        case "zip", "rar", "7z", "gz": return "doc.zipper"
        case "txt", "md", "rtf": return "doc.text"
        case "doc", "docx", "pages": return "doc.text.fill"
        case "xls", "xlsx", "numbers", "csv": return "tablecells"
        case "ppt", "pptx", "key": return "rectangle.on.rectangle"
        default:
            if item.isVideo { return "play.rectangle" }
            if item.isImage { return "photo" }
            return "doc"
        }
    }
}

// MARK: - Thumbnails

enum Thumbs {
    static func make(for url: URL, ext: String, id: UUID, key: SymmetricKey, dir: URL) {
        var img: UIImage?
        if Kind.isImage(ext) {
            img = downsample(url, maxPixel: 400)
        } else if Kind.isVideo(ext) {
            img = videoFrame(url)
        }
        guard let image = img,
              let data = image.jpegData(compressionQuality: 0.7),
              let enc = try? Crypto.encryptData(data, key: key) else { return }
        try? enc.write(to: dir.appendingPathComponent("thumbs").appendingPathComponent(id.uuidString), options: .atomic)
    }

    static func downsample(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts) else { return nil }
        let o = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, o) else { return nil }
        return UIImage(cgImage: cg)
    }

    static func videoFrame(_ url: URL) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true
        g.maximumSize = CGSize(width: 400, height: 400)
        guard let cg = try? g.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Picked file (from Photos picker)

struct PickedFile: Transferable {
    let url: URL

    static func make(_ received: ReceivedTransferredFile) throws -> PickedFile {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(received.file.lastPathComponent)
        try FileManager.default.copyItem(at: received.file, to: dst)
        return PickedFile(url: dst)
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try PickedFile.make(received)
        }
        FileRepresentation(importedContentType: .movie) { received in
            try PickedFile.make(received)
        }
    }
}

// MARK: - Sort

enum SortMode: String, CaseIterable, Identifiable {
    case name, date, size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "الاسم"
        case .date: return "الأحدث"
        case .size: return "الحجم"
        }
    }
}

// MARK: - Store

@MainActor
final class VaultStore: ObservableObject {
    @Published private(set) var items: [VaultItem] = []
    @Published var busy = false
    @Published var busyText = ""
    @Published var loadFailed = false

    private let key: SymmetricKey
    private let root: URL
    private let thumbCache = NSCache<NSString, UIImage>()

    nonisolated static var tempDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("vt", isDirectory: true)
    }

    init() {
        key = SecretStore.masterKey()
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CalcCache", isDirectory: true)
        let fm = FileManager.default
        for sub in ["files", "thumbs"] {
            try? fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try? fm.removeItem(at: VaultStore.tempDir)
        loadIndex()
    }

    // MARK: paths

    private var indexURL: URL { root.appendingPathComponent("index.bin") }
    private func fileURL(_ id: UUID) -> URL { root.appendingPathComponent("files").appendingPathComponent(id.uuidString) }
    private func thumbURL(_ id: UUID) -> URL { root.appendingPathComponent("thumbs").appendingPathComponent(id.uuidString) }

    func cleanTemp() {
        try? FileManager.default.removeItem(at: VaultStore.tempDir)
    }

    // MARK: index

    private func loadIndex() {
        guard let enc = try? Data(contentsOf: indexURL) else { return }
        do {
            let plain = try Crypto.decryptData(enc, key: key)
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            items = try dec.decode([VaultItem].self, from: plain)
        } catch {
            loadFailed = true
        }
    }

    private func saveIndex() {
        if loadFailed { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(items),
              let c = try? Crypto.encryptData(data, key: key) else { return }
        try? c.write(to: indexURL, options: .atomic)
    }

    // MARK: queries

    func children(of parent: UUID?, sort: SortMode = .name) -> [VaultItem] {
        items.filter { $0.parent == parent }.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            switch sort {
            case .name:
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .date:
                return a.date > b.date
            case .size:
                if a.size != b.size { return a.size > b.size }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    func search(_ query: String) -> [VaultItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return items
            .filter { $0.name.localizedCaseInsensitiveContains(q) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func item(_ id: UUID) -> VaultItem? {
        items.first { $0.id == id }
    }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    func descendants(of id: UUID) -> [UUID] {
        var out: [UUID] = []
        for c in items where c.parent == id {
            out.append(c.id)
            if c.isFolder { out += descendants(of: c.id) }
        }
        return out
    }

    func pathString(_ it: VaultItem) -> String {
        var parts = [it.name]
        var cur = it.parent
        while let p = cur, let pi = item(p) {
            parts.insert(pi.name, at: 0)
            cur = pi.parent
        }
        return parts.joined(separator: " / ")
    }

    func folderChoices(excluding ids: Set<UUID>) -> [FolderChoice] {
        var blocked = Set<UUID>()
        for id in ids {
            blocked.insert(id)
            for d in descendants(of: id) { blocked.insert(d) }
        }
        return items
            .filter { $0.isFolder && !blocked.contains($0.id) }
            .map { FolderChoice(item: $0, path: pathString($0)) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: mutations

    func createFolder(_ name: String, parent: UUID?) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        items.append(VaultItem(id: UUID(), name: n, isFolder: true, parent: parent, size: 0, date: Date(), ext: ""))
        saveIndex()
    }

    func rename(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].name = n
        if !items[i].isFolder {
            items[i].ext = (n as NSString).pathExtension.lowercased()
        }
        saveIndex()
    }

    func delete(_ ids: Set<UUID>) {
        var all = Set<UUID>()
        for id in ids {
            all.insert(id)
            for d in descendants(of: id) { all.insert(d) }
        }
        let fm = FileManager.default
        for id in all {
            try? fm.removeItem(at: fileURL(id))
            try? fm.removeItem(at: thumbURL(id))
            thumbCache.removeObject(forKey: id.uuidString as NSString)
        }
        items.removeAll { all.contains($0.id) }
        saveIndex()
    }

    func move(_ ids: Set<UUID>, to parent: UUID?) {
        for id in ids {
            guard let i = items.firstIndex(where: { $0.id == id }) else { continue }
            if items[i].isFolder, let p = parent, p == id || descendants(of: id).contains(p) { continue }
            items[i].parent = parent
        }
        saveIndex()
    }

    // MARK: import

    /// يرجع الروابط التي تم استيرادها بنجاح.
    @discardableResult
    func importURLs(_ urls: [URL], parent: UUID?) async -> [URL] {
        busy = true
        var done: [URL] = []
        let total = urls.count
        for (i, url) in urls.enumerated() {
            busyText = "جاري الاستيراد (\(i + 1)/\(total))"
            let scoped = url.startAccessingSecurityScopedResource()
            if await importOne(url, parent: parent) { done.append(url) }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        saveIndex()
        busy = false
        return done
    }

    func importData(_ data: Data, name: String, parent: UUID?) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            return
        }
        await importURLs([url], parent: parent)
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func importOne(_ url: URL, parent: UUID?) async -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

        if isDir.boolValue {
            let folder = VaultItem(id: UUID(), name: url.lastPathComponent, isFolder: true, parent: parent, size: 0, date: Date(), ext: "")
            items.append(folder)
            let kids = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            for k in kids {
                await importOne(k, parent: folder.id)
            }
            return true
        }

        let id = UUID()
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let key = self.key
        let dst = fileURL(id)
        let rootDir = root

        let size: Int64? = await Task.detached(priority: .userInitiated) { () -> Int64? in
            do {
                try Crypto.encryptFile(from: url, to: dst, key: key)
                Thumbs.make(for: url, ext: ext, id: id, key: key, dir: rootDir)
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                return (attrs[.size] as? NSNumber)?.int64Value ?? 0
            } catch {
                try? FileManager.default.removeItem(at: dst)
                return nil
            }
        }.value

        if let s = size {
            items.append(VaultItem(id: id, name: name, isFolder: false, parent: parent, size: s, date: Date(), ext: ext))
            return true
        }
        return false
    }

    // MARK: read

    func loadThumb(_ id: UUID) async -> UIImage? {
        let k = id.uuidString as NSString
        if let c = thumbCache.object(forKey: k) { return c }
        let key = self.key
        let url = thumbURL(id)
        let img: UIImage? = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let enc = try? Data(contentsOf: url),
                  let d = try? Crypto.decryptData(enc, key: key) else { return nil }
            return UIImage(data: d)
        }.value
        if let i = img { thumbCache.setObject(i, forKey: k) }
        return img
    }

    func loadImage(_ item: VaultItem) async -> UIImage? {
        let key = self.key
        let src = fileURL(item.id)
        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let d = try? Crypto.decryptFileToData(from: src, key: key) else { return nil }
            return UIImage(data: d)
        }.value
    }

    /// يفك تشفير الملف إلى مجلد مؤقت (يُحذف عند القفل).
    func exportURL(for item: VaultItem) async throws -> URL {
        let key = self.key
        let src = fileURL(item.id)
        let dirURL = VaultStore.tempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let safe = item.name.replacingOccurrences(of: "/", with: "-")
        let dst = dirURL.appendingPathComponent(safe)
        try await Task.detached(priority: .userInitiated) { () throws -> Void in
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            try Crypto.decryptFile(from: src, to: dst, key: key)
        }.value
        return dst
    }
}
