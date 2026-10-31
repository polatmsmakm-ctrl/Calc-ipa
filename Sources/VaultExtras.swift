import SwiftUI
import CryptoKit
import PDFKit
import ImageIO
import SWCompression

// MARK: - Result types

struct DupGroup: Identifiable, Codable {
    var id = UUID()
    var identical: Bool
    var items: [VaultItem]
}

struct CompareResult: Codable {
    var onlyA: [String] = []
    var onlyB: [String] = []
    var different: [String] = []
    var same = 0
    var nameA = ""
    var nameB = ""
}

struct DragPayload: Codable, Transferable {
    var ids: [UUID]
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

private struct StopReading: Error {}

extension VaultStore {
    // MARK: undo

    func snapshot(_ label: String) {
        if undoSuppress > 0 { return }
        undoStack.append(UndoEntry(label: label, before: items))
        if undoStack.count > 15 { undoStack.removeFirst() }
    }

    func beginGroup(_ label: String) {
        snapshot(label)
        undoSuppress += 1
    }

    func endGroup() { undoSuppress = max(0, undoSuppress - 1) }

    var undoLabel: String? { undoStack.last?.label }

    @discardableResult
    func undo() -> String? {
        guard let e = undoStack.popLast() else { return nil }
        let fm = FileManager.default
        let keep = Set(e.before.map { $0.id })
        for it in items where !keep.contains(it.id) {
            try? fm.removeItem(at: fileURL(it.id))
            try? fm.removeItem(at: thumbURL(it.id))
        }
        items = e.before.filter { $0.isFolder || fm.fileExists(atPath: fileURL($0.id).path) }
        saveIndex()
        return e.label
    }

    func markOpened(_ id: UUID) {
        guard let i = index(of: id) else { return }
        items[i].opened = Date()
        saveIndex()
    }

    // MARK: copy

    @discardableResult
    func duplicate(_ ids: Set<UUID>, to target: UUID?) async -> Int {
        beginGroup("نسخ")
        defer { endGroup() }
        var jobs: [(UUID, UUID)] = []
        var count = 0

        func copyOne(_ it: VaultItem, parent: UUID?, rename: Bool) {
            let nid = UUID()
            var c = it
            c.id = nid
            c.parent = parent
            c.deletedAt = nil
            c.opened = nil
            c.date = Date()
            c.modified = nil
            if rename {
                let ns = it.name as NSString
                let base = ns.deletingPathExtension
                let e = ns.pathExtension
                c.name = it.isFolder || e.isEmpty ? it.name + " نسخة" : base + " نسخة." + e
            }
            items.append(c)
            count += 1
            if it.isFolder {
                for k in items.filter({ $0.parent == it.id && $0.deletedAt == nil }) where k.id != nid {
                    copyOne(k, parent: nid, rename: false)
                }
            } else {
                jobs.append((it.id, nid))
            }
        }

        for id in ids {
            guard let it = item(id) else { continue }
            copyOne(it, parent: target, rename: it.parent == target)
        }
        busy = true
        busyText = "جاري النسخ…"
        let files = root.appendingPathComponent("files"), thumbs = root.appendingPathComponent("thumbs")
        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            for (old, new) in jobs {
                try? fm.copyItem(at: files.appendingPathComponent(old.uuidString), to: files.appendingPathComponent(new.uuidString))
                try? fm.copyItem(at: thumbs.appendingPathComponent(old.uuidString), to: thumbs.appendingPathComponent(new.uuidString))
            }
        }.value
        busy = false
        saveIndex()
        return count
    }

    // MARK: archives

    private func freeSpace() -> Int64? {
        let v = try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    func isArchive(_ it: VaultItem) -> Bool {
        !it.isFolder && ["zip", "7z"].contains(it.ext.lowercased())
    }

    /// يفك ZIP / 7Z داخل مجلد باسم الملف، ويستورد كل ملف أولاً بأول (لا يحتاج مساحة مضاعفة).
    func extractArchive(_ item: VaultItem) async -> String {
        let ext = item.ext.lowercased()
        if ext == "rar" { return "صيغة RAR غير مدعومة (مغلقة الترخيص)، الأفضل تحويلها إلى ZIP" }
        guard ext == "zip" || ext == "7z" else { return "هذا ليس أرشيفاً مدعوماً" }
        if let free = freeSpace(), free < item.size + 300_000_000 {
            return "المساحة لا تكفي: تحتاج على الأقل حجم الأرشيف (\(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))) فارغاً مؤقتاً"
        }
        busy = true
        busyText = "جاري تجهيز الأرشيف…"
        beginGroup("فك ضغط")
        defer { busy = false; endGroup() }

        var src: URL?
        do {
            let url = try await exportURL(for: item)
            src = url
            let base = (item.name as NSString).deletingPathExtension
            let rootID = UUID()
            items.append(VaultItem(id: rootID, name: base.isEmpty ? "ملفات" : base, isFolder: true,
                                   parent: item.parent, size: 0, date: Date(), ext: ""))
            var folders: [String: UUID] = [:]

            func ensure(_ parts: [String]) -> UUID {
                var cur = rootID
                var key = ""
                for part in parts {
                    key += "/" + part
                    if let f = folders[key] { cur = f; continue }
                    let nid = UUID()
                    items.append(VaultItem(id: nid, name: part, isFolder: true, parent: cur, size: 0, date: Date(), ext: ""))
                    folders[key] = nid
                    cur = nid
                }
                return cur
            }

            var done = 0
            let work = VaultStore.tempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }

            if ext == "zip" {
                let list = try await Task.detached { try ZipReader.entries(of: url) }.value
                let total = list.count
                for (n, e) in list.enumerated() {
                    let parts = e.parts
                    if parts.isEmpty || parts.first == "__MACOSX" || parts.last == ".DS_Store" { continue }
                    if e.isDir { _ = ensure(parts); continue }
                    busyText = "فك الضغط (\(n + 1)/\(total))"
                    let parent = ensure(Array(parts.dropLast()))
                    let dir = work.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    let tmp = dir.appendingPathComponent(parts.last!)
                    try await Task.detached(priority: .userInitiated) { try ZipReader.extract(e, from: url, to: tmp) }.value
                    if await importOne(tmp, parent: parent) { done += 1 }
                    try? FileManager.default.removeItem(at: dir)
                    if done % 25 == 0 { saveIndex() }
                }
            } else {
                if item.size > 1_200_000_000 { throw ZipError.unsupported("أرشيف 7Z كبير جداً (الحد 1.2GB)، حوّله إلى ZIP") }
                busyText = "جاري قراءة 7Z…"
                let entries = try await Task.detached(priority: .userInitiated) { () throws -> [(String, Bool, Data?)] in
                    let data = try Data(contentsOf: url, options: .alwaysMapped)
                    return try SevenZipContainer.open(container: data).map { en in
                        (en.info.name, en.info.type == .directory, en.data)
                    }
                }.value
                for (n, e) in entries.enumerated() {
                    let parts = e.0.replacingOccurrences(of: "\\", with: "/")
                        .split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                        .filter { $0 != "." && $0 != ".." }
                    if parts.isEmpty { continue }
                    if e.1 { _ = ensure(parts); continue }
                    busyText = "فك الضغط (\(n + 1)/\(entries.count))"
                    let parent = ensure(Array(parts.dropLast()))
                    let dir = work.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let tmp = dir.appendingPathComponent(parts.last!)
                    try (e.2 ?? Data()).write(to: tmp)
                    if await importOne(tmp, parent: parent) { done += 1 }
                    try? FileManager.default.removeItem(at: dir)
                }
            }
            saveIndex()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            return "تم فك الضغط: \(done) ملف"
        } catch {
            if let u = src { try? FileManager.default.removeItem(at: u.deletingLastPathComponent()) }
            saveIndex()
            return (error as? LocalizedError)?.errorDescription ?? "تعذر فك الضغط: \(error.localizedDescription)"
        }
    }

    /// يضغط العناصر المحددة إلى ZIP داخل الخزنة.
    func makeZip(_ ids: Set<UUID>) async -> String {
        var files: [(String, VaultItem)] = []
        var dirs: [String] = []

        func walk(_ it: VaultItem, prefix: String) {
            if it.isFolder {
                let path = prefix + it.name
                dirs.append(path)
                for k in children(of: it.id, sort: .name) { walk(k, prefix: path + "/") }
            } else if !it.isNote {
                files.append((prefix + it.name, it))
            }
        }
        let roots = ids.compactMap { item($0) }
        for r in roots { walk(r, prefix: "") }
        guard !files.isEmpty || !dirs.isEmpty else { return "لا يوجد ما يمكن ضغطه" }

        busy = true
        busyText = "جاري الضغط…"
        beginGroup("ضغط")
        defer { busy = false; endGroup() }

        let work = VaultStore.tempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let zipName = (roots.count == 1 ? roots[0].name : "أرشيف") + ".zip"
        let zipURL = work.appendingPathComponent(zipName)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let writer = try ZipWriter(to: zipURL)
            for d in dirs { try writer.addDirectory(d) }
            for (n, f) in files.enumerated() {
                busyText = "جاري الضغط (\(n + 1)/\(files.count))"
                let tmp = try await exportURL(for: f.1)
                try await Task.detached(priority: .userInitiated) { try writer.addFile(f.0, from: tmp) }.value
                try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
            }
            try writer.finish()
            busyText = "جاري التشفير…"
            let ok = await importOne(zipURL, parent: roots.first?.parent)
            try? FileManager.default.removeItem(at: work)
            saveIndex()
            return ok ? "تم إنشاء \(zipName)" : "تعذر حفظ الأرشيف"
        } catch {
            try? FileManager.default.removeItem(at: work)
            return (error as? LocalizedError)?.errorDescription ?? "تعذر الضغط"
        }
    }

    // MARK: content reading

    private static let textExts: Set<String> = ["txt", "md", "csv", "json", "xml", "html", "htm", "log", "rtf", "swift", "py", "js", "css", "yml", "yaml", "ini"]

    func canReadText(_ it: VaultItem) -> Bool {
        guard !it.isFolder else { return false }
        let e = it.ext.lowercased()
        return it.isNote || e == "pdf" || VaultStore.textExts.contains(e)
    }

    /// نص الملف (حتى حد معين) أو nil. يعمل خارج الخيط الرئيسي.
    func readText(_ it: VaultItem, limit: Int = 600) async -> String? {
        guard canReadText(it), it.size < 60_000_000 else { return nil }
        let key = self.key, src = fileURL(it.id), e = it.ext.lowercased(), isNote = it.isNote
        return await Task.detached(priority: .utility) { () -> String? in
            if isNote {
                guard let d = try? Crypto.decryptFileToData(from: src, key: key),
                      let n = try? JSONDecoder().decode(NoteContent.self, from: d) else { return nil }
                return String(n.body.prefix(limit))
            }
            if e == "pdf" {
                guard let d = try? Crypto.decryptFileToData(from: src, key: key),
                      let doc = PDFDocument(data: d) else { return nil }
                var out = ""
                for i in 0..<min(doc.pageCount, 3) {
                    out += (doc.page(at: i)?.string ?? "") + "\n"
                    if out.count >= limit { break }
                }
                return String(out.prefix(limit))
            }
            var acc = Data()
            do {
                try Crypto.decryptChunks(from: src, key: key) { chunk in
                    acc.append(chunk)
                    if acc.count >= limit * 4 { throw StopReading() }
                }
            } catch is StopReading {} catch { return nil }
            let s = String(decoding: acc, as: UTF8.self)
            return String(s.prefix(limit))
        }.value
    }

    // MARK: smart tools

    func largest(_ n: Int) -> [VaultItem] {
        Array(live.filter { !$0.isFolder }.sorted { $0.size > $1.size }.prefix(n))
    }

    func unopened(days: Int) -> [VaultItem] {
        let limit = Date().addingTimeInterval(-Double(days) * 86400)
        return live.filter { !$0.isFolder && ($0.opened ?? $0.modified ?? $0.date) < limit }
            .sorted { ($0.opened ?? $0.date) < ($1.opened ?? $1.date) }
    }

    func oldBackups() -> [VaultItem] {
        let words = ["backup", "bak", "old", "copy", "copie", "نسخة", "قديم", "احتياط", "~", "archive", "tmp", "temp"]
        let exts: Set<String> = ["bak", "old", "tmp", "backup", "orig", "swp"]
        let cutoff = Date().addingTimeInterval(-180 * 86400)
        return live.filter { it in
            guard !it.isFolder else { return false }
            let n = it.name.lowercased()
            if exts.contains(it.ext.lowercased()) { return true }
            if words.contains(where: { n.contains($0) }) { return true }
            if n.range(of: #"\(\d+\)"#, options: .regularExpression) != nil { return true }
            if ["zip", "7z", "rar", "gz"].contains(it.ext.lowercased()), (it.opened ?? it.date) < cutoff { return true }
            return false
        }.sorted { $0.date < $1.date }
    }

    private func normalized(_ name: String) -> String {
        var n = (name as NSString).deletingPathExtension.lowercased()
        for w in [" copy", "_copy", "-copy", " نسخة", "copy of ", " - copy"] { n = n.replacingOccurrences(of: w, with: "") }
        n = n.replacingOccurrences(of: #"\s*\(\d+\)\s*$"#, with: "", options: .regularExpression)
        n = n.replacingOccurrences(of: #"[\s_\-]+\d{1,2}$"#, with: "", options: .regularExpression)
        return n.trimmingCharacters(in: .whitespaces)
    }

    func findDuplicates(progress: @escaping (String) -> Void = { _ in }) async -> [DupGroup] {
        let files = live.filter { !$0.isFolder && !$0.isNote && $0.size > 0 }
        var bySize: [Int64: [VaultItem]] = [:]
        for f in files { bySize[f.size, default: []].append(f) }
        let key = self.key
        var groups: [DupGroup] = []
        var used = Set<UUID>()

        let cands = bySize.values.filter { $0.count > 1 }
        var n = 0
        for g in cands {
            n += 1
            progress("فحص \(n)/\(cands.count)")
            var byHash: [String: [VaultItem]] = [:]
            for f in g {
                let src = fileURL(f.id)
                let big = f.size > 500_000_000
                let h: String? = await Task.detached(priority: .utility) { () -> String? in
                    if big { return "big-" + String(f.size) }   // الملفات الضخمة: نكتفي بالحجم + الاسم
                    var sha = SHA256()
                    do {
                        try Crypto.decryptChunks(from: src, key: key) { sha.update(data: $0) }
                    } catch { return nil }
                    return sha.finalize().map { String(format: "%02x", $0) }.joined()
                }.value
                if let h { byHash[big ? h + normalized(f.name) : h, default: []].append(f) }
            }
            for (_, v) in byHash where v.count > 1 {
                groups.append(DupGroup(identical: true, items: v.sorted { $0.date < $1.date }))
                v.forEach { used.insert($0.id) }
            }
        }

        var byName: [String: [VaultItem]] = [:]
        for f in files where !used.contains(f.id) {
            byName[normalized(f.name) + "." + f.ext.lowercased(), default: []].append(f)
        }
        for (_, v) in byName where v.count > 1 {
            groups.append(DupGroup(identical: false, items: v.sorted { $0.date < $1.date }))
        }
        return groups.sorted { ($0.items.first?.size ?? 0) * Int64($0.items.count) > ($1.items.first?.size ?? 0) * Int64($1.items.count) }
    }

    func contentSearch(_ word: String, progress: @escaping (String) -> Void = { _ in }) async -> [VaultItem] {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return [] }
        var out: [VaultItem] = []
        let cands = live.filter { canReadText($0) }
        for (i, it) in cands.enumerated() {
            progress("بحث في المحتوى \(i + 1)/\(cands.count)")
            if it.name.localizedCaseInsensitiveContains(w) { out.append(it); continue }
            if let t = await readText(it, limit: 200_000), t.localizedCaseInsensitiveContains(w) { out.append(it) }
        }
        return out
    }

    private func relMap(_ folder: UUID, prefix: String = "") -> [String: VaultItem] {
        var m: [String: VaultItem] = [:]
        for k in live where k.parent == folder {
            let p = prefix + k.name
            if k.isFolder { m.merge(relMap(k.id, prefix: p + "/")) { a, _ in a } }
            else { m[p] = k }
        }
        return m
    }

    func compareFolders(_ a: UUID, _ b: UUID) -> CompareResult {
        let ma = relMap(a), mb = relMap(b)
        var r = CompareResult()
        r.nameA = item(a)?.name ?? "A"
        r.nameB = item(b)?.name ?? "B"
        for (k, v) in ma {
            if let o = mb[k] {
                if o.size == v.size { r.same += 1 } else { r.different.append(k) }
            } else { r.onlyA.append(k) }
        }
        for k in mb.keys where ma[k] == nil { r.onlyB.append(k) }
        r.onlyA.sort(); r.onlyB.sort(); r.different.sort()
        return r
    }

    /// تسمية الصور حسب تاريخ الالتقاط (EXIF) ويرجع عدد ما تغيّر.
    func renameByCaptureDate(_ ids: [UUID]) async -> Int {
        let imgs = ids.compactMap { item($0) }.filter { $0.isImage }
        guard !imgs.isEmpty else { return 0 }
        busy = true
        busyText = "قراءة تواريخ الصور…"
        beginGroup("إعادة تسمية الصور")
        defer { busy = false; endGroup() }
        let key = self.key
        var taken: [UUID?: Set<String>] = [:]
        for it in live { taken[it.parent, default: []].insert(it.name.lowercased()) }
        var n = 0
        for (i, it) in imgs.enumerated() {
            busyText = "إعادة تسمية الصور (\(i + 1)/\(imgs.count))"
            let src = fileURL(it.id)
            let d: Date? = await Task.detached(priority: .utility) { () -> Date? in
                guard let data = try? Crypto.decryptFileToData(from: src, key: key),
                      let cg = CGImageSourceCreateWithData(data as CFData, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(cg, 0, nil) as? [CFString: Any],
                      let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
                      let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy:MM:dd HH:mm:ss"
                return f.date(from: s)
            }.value
            let date = d ?? it.date
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let base = f.string(from: date)
            let ext = it.ext.isEmpty ? "jpg" : it.ext
            var name = "\(base).\(ext)"
            var k = 2
            while taken[it.parent]?.contains(name.lowercased()) == true && name.lowercased() != it.name.lowercased() {
                name = "\(base) (\(k)).\(ext)"; k += 1
            }
            if name != it.name {
                taken[it.parent, default: []].insert(name.lowercased())
                rename(it.id, to: name)
                n += 1
            }
        }
        return n
    }

    /// ينقل مجموعات من العناصر إلى مجلدات (ينشئ المجلد لو ما وُجد).
    @discardableResult
    func organize(_ groups: [(String, [UUID])], under parent: UUID?) -> Int {
        beginGroup("تنظيم")
        defer { endGroup() }
        var moved = 0
        for (name, ids) in groups {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !ids.isEmpty else { continue }
            var fid = live.first { $0.isFolder && $0.parent == parent && $0.name == clean }?.id
            if fid == nil {
                let nid = UUID()
                items.append(VaultItem(id: nid, name: clean, isFolder: true, parent: parent, size: 0, date: Date(), ext: ""))
                fid = nid
            }
            let movable = Set(ids.filter { $0 != fid })
            move(movable, to: fid)
            moved += movable.count
        }
        saveIndex()
        return moved
    }
}
