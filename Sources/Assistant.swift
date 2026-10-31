import SwiftUI

// MARK: - Gemini client

enum GeminiConfig {
    static var key: String {
        get { SecretStore.get("gm").flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        set {
            let t = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { SecretStore.remove("gm") } else { SecretStore.set(Data(t.utf8), "gm") }
        }
    }
    static var model: String {
        get { UserDefaults.standard.string(forKey: "ai.model") ?? "gemini-flash-latest" }
        set { UserDefaults.standard.set(newValue, forKey: "ai.model") }
    }
    static var snippets: Bool {
        get { UserDefaults.standard.bool(forKey: "ai.snippets") }
        set { UserDefaults.standard.set(newValue, forKey: "ai.snippets") }
    }
}

enum GeminiError: LocalizedError {
    case noKey, http(Int, String), empty

    var errorDescription: String? {
        switch self {
        case .noKey: return "أضف مفتاح Gemini أولاً (من ⚙︎ أعلى الشاشة)"
        case .http(let c, let m):
            if c == 400 || c == 403 { return "المفتاح غير صالح أو غير مسموح (\(c)) — \(m)" }
            if c == 429 { return "تجاوزت حد الاستخدام المجاني، جرّب بعد قليل" }
            return "خطأ من Gemini (\(c)) — \(m)"
        case .empty: return "رد فارغ من Gemini"
        }
    }
}

enum Gemini {
    static func ask(system: String, user: String) async throws -> String {
        let key = GeminiConfig.key
        guard !key.isEmpty else { throw GeminiError.noKey }
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(GeminiConfig.model):generateContent")!
        var req = URLRequest(url: url, timeoutInterval: 90)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
            "generationConfig": ["temperature": 0.2, "responseMimeType": "application/json"]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            var msg = ""
            if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let e = j["error"] as? [String: Any], let m = e["message"] as? String { msg = String(m.prefix(140)) }
            throw GeminiError.http(code, msg)
        }
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let c = (j["candidates"] as? [[String: Any]])?.first,
              let parts = (c["content"] as? [String: Any])?["parts"] as? [[String: Any]] else { throw GeminiError.empty }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        if text.isEmpty { throw GeminiError.empty }
        return text
    }
}

// MARK: - Assistant model

struct AIMessage: Identifiable, Codable {
    var id = UUID()
    var isUser = false
    var text: String
    var items: [VaultItem] = []
    var groups: [DupGroup] = []
    var compare: CompareResult?
    var plan: AIPlan?
    var trashIDs: [UUID] = []
    var trashLabel = ""
    var applied = false
}

struct PlanGroup: Codable { var name: String; var ids: [UUID] }
struct PlanRename: Codable { var id: UUID; var name: String }

struct AIPlan: Codable {
    var folders: [PlanGroup] = []
    var renames: [PlanRename] = []
    var dateIDs: [UUID] = []
    var parent: UUID?
}

struct ChatSession: Identifiable, Codable {
    var id = UUID()
    var title: String
    var date: Date
    var messages: [AIMessage]
}

@MainActor
final class Assistant: ObservableObject {
    @Published var messages: [AIMessage] = [] {
        didSet { persist() }
    }
    @Published var working = false
    @Published var status = ""
    @Published var sessions: [ChatSession] = []
    private(set) var currentID = UUID()
    private weak var storeRef: VaultStore?
    private var attached = false

    // MARK: chats persistence (مشفّرة بمفتاح الخزنة)

    private var chatsURL: URL? { storeRef?.root.appendingPathComponent("chats.bin") }

    func attach(_ store: VaultStore) {
        guard !attached else { return }
        attached = true
        storeRef = store
        if let u = chatsURL, let enc = try? Data(contentsOf: u),
           let plain = try? Crypto.decryptData(enc, key: store.key) {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            sessions = (try? d.decode([ChatSession].self, from: plain)) ?? []
        }
        // افتح آخر محادثة تلقائياً
        if let last = sessions.sorted(by: { $0.date > $1.date }).first {
            currentID = last.id
            messages = last.messages
        }
    }

    private func persist() {
        guard attached, let store = storeRef, let u = chatsURL else { return }
        if messages.isEmpty {
            sessions.removeAll { $0.id == currentID }
        } else {
            let title = String((messages.first(where: { $0.isUser })?.text ?? "محادثة").prefix(40))
            if let i = sessions.firstIndex(where: { $0.id == currentID }) {
                sessions[i].messages = messages
                sessions[i].date = Date()
            } else {
                sessions.append(ChatSession(id: currentID, title: title, date: Date(), messages: messages))
            }
        }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(sessions), let enc = try? Crypto.encryptData(data, key: store.key) {
            try? enc.write(to: u, options: .atomic)
        }
    }

    func newChat() {
        currentID = UUID()
        messages = []
    }

    func open(_ s: ChatSession) {
        currentID = s.id
        messages = s.messages
    }

    func delete(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        if id == currentID { currentID = UUID(); messages = [] }
        else { persist() }
    }

    private var shortMap: [Int: UUID] = [:]

    private let system = """
    You are the file-organizing assistant inside a private file vault app. The user speaks Arabic (Gulf dialect) or English. \
    You never see file contents unless snippets are given. You receive an INDEX of the user's items: \
    "n|kind(F=folder,f=file)|name|ext|sizeKB|created|lastOpened|folderPath". n is the numeric id you must use. \
    Reply with ONE JSON object only: {"say": "<short friendly Arabic sentence>", "tool": "<tool>", "args": {...}}. Tools:
    - "largest": args {"n": number} — biggest files.
    - "unopened": args {"days": number} — files not opened for that many days.
    - "duplicates": args {} — find duplicate / similar files.
    - "old_backups": args {} — files that look like old backups.
    - "search_name": args {"query": string} — search by file name.
    - "search_content": args {"query": string} — find files containing a word inside their text.
    - "compare": args {"a": n, "b": n} — compare two folders (ids of folders).
    - "organize": args {"groups": [{"folder": "<folder name in Arabic or as appropriate>", "ids": [n,...]}]} — group existing items into folders (e.g. PDFs by topic, files of one project). Only use ids that exist in the INDEX.
    - "rename": args {"renames": [{"id": n, "name": "<new full file name with extension>"}]}.
    - "rename_by_date": args {"ids": [n,...]} — rename images by their capture date (ids of images; if user means all photos, list all image ids).
    - "classify": args {"filter": "pdf" | "docs" | "all"} — classify documents by their CONTENT (the app will fetch text and ask you again).
    - "none": answer in "say" only (questions, chat, or if the request is unclear — ask a short question).
    Never invent ids. Keep "say" short.
    """


    private func buildIndex(_ store: VaultStore) -> String {
        shortMap = [:]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        var lines: [String] = []
        let all = store.items.filter { $0.deletedAt == nil }
        for (i, it) in all.prefix(700).enumerated() {
            let n = i + 1
            shortMap[n] = it.id
            let folder = it.parent.flatMap { store.item($0).map { store.pathString($0) } } ?? ""
            lines.append("\(n)|\(it.isFolder ? "F" : "f")|\(it.name)|\(it.ext)|\(it.size / 1024)|\(f.string(from: it.date))|\(it.opened.map { f.string(from: $0) } ?? "-")|\(folder)")
        }
        if all.count > 700 { lines.append("(… \(all.count - 700) more items not shown)") }
        return lines.joined(separator: "\n")
    }

    private func ids(_ any: Any?) -> [UUID] {
        guard let arr = any as? [Any] else { return [] }
        return arr.compactMap { v -> UUID? in
            if let n = v as? Int { return shortMap[n] }
            if let d = v as? Double { return shortMap[Int(d)] }
            if let s = v as? String, let n = Int(s) { return shortMap[n] }
            return nil
        }
    }

    private func one(_ any: Any?) -> UUID? {
        if let n = any as? Int { return shortMap[n] }
        if let d = any as? Double { return shortMap[Int(d)] }
        if let s = any as? String, let n = Int(s) { return shortMap[n] }
        return nil
    }

    // MARK: entry points

    func ask(_ text: String, store: VaultStore, parent: UUID?) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !working else { return }
        messages.append(AIMessage(isUser: true, text: t))
        working = true
        status = "Gemini يفكر…"
        defer { working = false; status = "" }
        do {
            let hist = messages.dropLast().suffix(8).map { ($0.isUser ? "USER: " : "ASSISTANT: ") + String($0.text.prefix(300)) }.joined(separator: "\n")
            let user = "INDEX:\n\(buildIndex(store))\n\nRECENT CONVERSATION:\n\(hist)\n\nUSER REQUEST:\n\(t)"
            let raw = try await Gemini.ask(system: system, user: user)
            await handle(raw, store: store, parent: parent, original: t)
        } catch {
            messages.append(AIMessage(text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
    }

    private func parse(_ raw: String) -> [String: Any]? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        }
        guard let d = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    private func handle(_ raw: String, store: VaultStore, parent: UUID?, original: String) async {
        guard let j = parse(raw) else {
            messages.append(AIMessage(text: "ما فهمت رد Gemini، جرّب صياغة ثانية"))
            return
        }
        let say = (j["say"] as? String) ?? ""
        let tool = (j["tool"] as? String) ?? "none"
        let args = (j["args"] as? [String: Any]) ?? [:]

        switch tool {
        case "largest":
            let n = min(200, max(1, (args["n"] as? Int) ?? 50))
            messages.append(AIMessage(text: say.isEmpty ? "أكبر \(n) ملف" : say, items: store.largest(n)))
        case "unopened":
            let d = (args["days"] as? Int) ?? 365
            await runUnopened(d, store: store, say: say)
        case "duplicates":
            await runDuplicates(store: store)
        case "old_backups":
            runOldBackups(store: store)
        case "search_name":
            let q = (args["query"] as? String) ?? original
            messages.append(AIMessage(text: say.isEmpty ? "نتائج «\(q)»" : say, items: store.search(q)))
        case "search_content":
            await runContent((args["query"] as? String) ?? original, store: store)
        case "compare":
            if let a = one(args["a"]), let b = one(args["b"]) {
                var m = AIMessage(text: say.isEmpty ? "مقارنة المجلدين" : say)
                m.compare = store.compareFolders(a, b)
                messages.append(m)
            } else {
                messages.append(AIMessage(text: "حدّد المجلدين بالاسم عشان أقارنهم"))
            }
        case "organize":
            let groups: [PlanGroup] = ((args["groups"] as? [[String: Any]]) ?? []).compactMap { g in
                guard let f = g["folder"] as? String else { return nil }
                let i = ids(g["ids"])
                return i.isEmpty ? nil : PlanGroup(name: f, ids: i)
            }
            var m = AIMessage(text: say.isEmpty ? "هذا اقتراح التنظيم" : say)
            if groups.isEmpty { m.text = "ما لقيت ملفات مناسبة للتنظيم" } else { m.plan = AIPlan(folders: groups, parent: parent) }
            messages.append(m)
        case "rename":
            let rs: [PlanRename] = ((args["renames"] as? [[String: Any]]) ?? []).compactMap { r in
                guard let id = one(r["id"]), let n = r["name"] as? String, !n.isEmpty else { return nil }
                return PlanRename(id: id, name: n)
            }
            var m = AIMessage(text: say.isEmpty ? "هذي الأسماء المقترحة" : say)
            if rs.isEmpty { m.text = "ما طلع اقتراح لإعادة التسمية" } else { m.plan = AIPlan(renames: rs) }
            messages.append(m)
        case "rename_by_date":
            let i = ids(args["ids"])
            var m = AIMessage(text: say.isEmpty ? "سأسمّي الصور حسب تاريخ التقاطها" : say)
            if i.isEmpty { m.text = "ما لقيت صور لإعادة تسميتها" } else { m.plan = AIPlan(dateIDs: i) }
            messages.append(m)
        case "classify":
            await runClassify((args["filter"] as? String) ?? "docs", store: store, parent: parent, original: original)
        default:
            messages.append(AIMessage(text: say.isEmpty ? "تمام" : say))
        }
    }

    // MARK: local tools (also used by quick chips)

    func runUnopened(_ days: Int, store: VaultStore, say: String = "") async {
        let list = store.unopened(days: days)
        var m = AIMessage(text: say.isEmpty ? "ملفات ما انفتحت من \(days) يوم (\(list.count))" : say, items: list)
        m.trashIDs = list.map { $0.id }
        m.trashLabel = "نقل الكل للسلة"
        if days >= 300 { m.text += "\nالتتبع يبدأ من أول تشغيل لهذا الإصدار، وقبلها يُحسب تاريخ الإضافة." }
        messages.append(m)
    }

    func runDuplicates(store: VaultStore) async {
        working = true
        defer { working = false; status = "" }
        let g = await store.findDuplicates { [weak self] s in self?.status = s }
        var m = AIMessage(text: g.isEmpty ? "ما لقيت ملفات مكررة 👌" : "لقيت \(g.count) مجموعة (المتطابق = نفس المحتوى، المتشابه = أسماء متقاربة)")
        m.groups = g
        let extra = g.filter { $0.identical }.flatMap { $0.items.dropFirst() }.map { $0.id }
        m.trashIDs = extra
        m.trashLabel = "حذف النسخ المتطابقة (أبقي الأقدم)"
        messages.append(m)
    }

    func runOldBackups(store: VaultStore) {
        let list = store.oldBackups()
        var m = AIMessage(text: list.isEmpty ? "ما لقيت شي يشبه نسخ احتياطية قديمة" : "ملفات تبدو نسخ احتياطية قديمة (\(list.count))", items: list)
        m.trashIDs = list.map { $0.id }
        m.trashLabel = "نقل الكل للسلة"
        messages.append(m)
    }

    func runContent(_ q: String, store: VaultStore) async {
        working = true
        defer { working = false; status = "" }
        let r = await store.contentSearch(q) { [weak self] s in self?.status = s }
        messages.append(AIMessage(text: r.isEmpty ? "ما لقيت «\(q)» داخل المحتوى (أبحث في PDF والنصوص والملاحظات)" : "الملفات اللي فيها «\(q)» (\(r.count))", items: r))
    }

    private func runClassify(_ filter: String, store: VaultStore, parent: UUID?, original: String) async {
        let docExts: Set<String> = ["pdf", "txt", "md", "rtf", "doc", "docx", "pages", "csv", "cnote"]
        let pool = store.items.filter { it in
            guard it.deletedAt == nil, !it.isFolder, !it.isMedia else { return false }
            switch filter {
            case "pdf": return it.ext.lowercased() == "pdf"
            case "all": return true
            default: return docExts.contains(it.ext.lowercased())
            }
        }.prefix(80)
        guard !pool.isEmpty else { messages.append(AIMessage(text: "ما لقيت مستندات للتصنيف")); return }

        shortMap = [:]
        var lines: [String] = []
        for (i, it) in pool.enumerated() {
            shortMap[i + 1] = it.id
            status = "قراءة المستندات \(i + 1)/\(pool.count)"
            var snip = ""
            if GeminiConfig.snippets, let t = await store.readText(it, limit: 350) {
                snip = t.replacingOccurrences(of: "\n", with: " ")
            }
            lines.append("\(i + 1)|\(it.name)|\(snip)")
        }
        status = "Gemini يصنّف…"
        let sys = """
        Group these documents by TOPIC/CONTENT (not extension). Lines are "n|file name|text snippet (may be empty)". \
        Reply with ONE JSON object: {"say":"<short Arabic sentence>","tool":"organize","args":{"groups":[{"folder":"<topic name in Arabic>","ids":[n,...]}]}}. \
        Use 2–8 groups, every file in at most one group.
        """
        do {
            let raw = try await Gemini.ask(system: sys, user: "FILES:\n" + lines.joined(separator: "\n") + "\n\nUSER REQUEST: \(original)")
            await handle(raw, store: store, parent: parent, original: original)
        } catch {
            messages.append(AIMessage(text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
    }

    // MARK: applying

    func apply(_ id: UUID, store: VaultStore) async {
        guard let i = messages.firstIndex(where: { $0.id == id }), let plan = messages[i].plan, !messages[i].applied else { return }
        var report = ""
        if !plan.folders.isEmpty {
            let n = store.organize(plan.folders.map { ($0.name, $0.ids) }, under: plan.parent)
            report = "تم نقل \(n) عنصر"
        }
        if !plan.renames.isEmpty {
            store.beginGroup("إعادة تسمية")
            for r in plan.renames { store.rename(r.id, to: r.name) }
            store.endGroup()
            report = "تمت إعادة تسمية \(plan.renames.count) عنصر"
        }
        if !plan.dateIDs.isEmpty {
            let n = await store.renameByCaptureDate(plan.dateIDs)
            report = "تمت إعادة تسمية \(n) صورة"
        }
        messages[i].applied = true
        messages.append(AIMessage(text: report + " ✅ (تقدر تتراجع من زر ↩︎)"))
    }

    func trashAll(_ id: UUID, store: VaultStore) {
        guard let i = messages.firstIndex(where: { $0.id == id }), !messages[i].applied else { return }
        store.trash(Set(messages[i].trashIDs))
        messages[i].applied = true
        messages.append(AIMessage(text: "نُقلت \(messages[i].trashIDs.count) عنصر إلى السلة ✅ (تقدر تتراجع من زر ↩︎)"))
    }
}

// MARK: - View

struct AssistantView: View {
    let parent: UUID?
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = Assistant()
    @State private var input = ""
    @State private var showSettings = false
    @State private var hasKey = !GeminiConfig.key.isEmpty
    @State private var showHistory = false

    private let chips: [(String, String)] = [
        ("أكبر 50 ملف", "largest"), ("الملفات المكررة", "dups"),
        ("نسخ احتياطية قديمة", "backups"), ("ما فتحتها من سنة", "year")
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .trailing, spacing: 12) {
                            if vm.messages.isEmpty { intro }
                            ForEach(vm.messages) { m in
                                bubble(m).id(m.id)
                            }
                            if vm.working {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text(vm.status).font(.footnote).foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(14)
                    }
                    .onChange(of: vm.messages.count) { _ in
                        if let last = vm.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .top) } }
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chips, id: \.1) { c in
                            Button { runChip(c.1) } label: {
                                Text(c.0).font(.footnote.weight(.semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(Capsule().fill(Theme.accent.opacity(0.18)))
                            }
                            .disabled(vm.working)
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .padding(.vertical, 6)

                HStack(spacing: 8) {
                    TextField("اطلب أي شي: رتب الـ PDF حسب الموضوع…", text: $input, axis: .vertical)
                        .lineLimit(1...3)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.1)))
                    Button { send() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 34))
                            .foregroundColor(Theme.accent)
                    }
                    .disabled(vm.working || input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 14).padding(.bottom, 10)
            }
            .background(AppBackground())
            .navigationTitle("المساعد الذكي")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("إغلاق") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button { vm.newChat() } label: { Image(systemName: "square.and.pencil") }
                        Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    }
                }
            }
            .task { vm.attach(store) }
            .sheet(isPresented: $showHistory) {
                ChatHistoryView(vm: vm)
            }
            .sheet(isPresented: $showSettings, onDismiss: { hasKey = !GeminiConfig.key.isEmpty }) {
                AISettingsView()
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .preferredColorScheme(.dark)
    }

    private var intro: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Text("أنا مساعد ترتيب ملفاتك ✨").font(.headline)
            Text("الأزرار تحت تشتغل بدون إنترنت. والأوامر الحرة تحتاج مفتاح Gemini المجاني:")
                .font(.footnote).foregroundColor(.secondary)
            Text("• «رتب جميع ملفات PDF حسب الموضوع»\n• «اجمع كل ملفات مشروع كذا في مجلد»\n• «اعثر على الملفات اللي فيها كلمة …»\n• «أعد تسمية الصور حسب تاريخ التقاط»\n• «قارن مجلد A و B»")
                .font(.footnote)
            if !hasKey {
                Button { showSettings = true } label: { Label("إضافة مفتاح Gemini", systemImage: "key.fill") }
                    .buttonStyle(.borderedProminent)
            }
            Text("الخصوصية: الأوامر الحرة ترسل لـ Google أسماء ملفاتك وأحجامها وتواريخها فقط، ولا يُرسل أي محتوى إلا لو فعّلت «مقتطفات المحتوى» من الإعدادات.")
                .font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.08)))
    }

    private func runChip(_ c: String) {
        Task { @MainActor in
            switch c {
            case "largest": vm.messages.append(AIMessage(isUser: true, text: "أكبر 50 ملف")); vm.messages.append(AIMessage(text: "أكبر 50 ملف", items: store.largest(50)))
            case "dups": vm.messages.append(AIMessage(isUser: true, text: "اكتشاف المكرر")); await vm.runDuplicates(store: store)
            case "backups": vm.messages.append(AIMessage(isUser: true, text: "نسخ احتياطية قديمة")); vm.runOldBackups(store: store)
            default: vm.messages.append(AIMessage(isUser: true, text: "ما فتحتها من سنة")); await vm.runUnopened(365, store: store)
            }
        }
    }

    private func send() {
        let t = input
        input = ""
        Task { await vm.ask(t, store: store, parent: parent) }
    }

    @ViewBuilder
    private func bubble(_ m: AIMessage) -> some View {
        if m.isUser {
            Text(m.text)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.accent.opacity(0.35)))
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .trailing, spacing: 8) {
                Text(m.text).frame(maxWidth: .infinity, alignment: .leading)

                if !m.items.isEmpty { itemList(m.items) }
                ForEach(m.groups) { g in groupView(g) }
                if let c = m.compare { compareView(c) }
                if let p = m.plan { planView(p) }

                if !m.trashIDs.isEmpty {
                    Button(role: .destructive) { vm.trashAll(m.id, store: store) } label: {
                        Label(m.trashLabel, systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(m.applied)
                }
                if m.plan != nil {
                    Button { Task { await vm.apply(m.id, store: store) } } label: {
                        Label(m.applied ? "تم التطبيق" : "تطبيق", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(m.applied)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.08)))
        }
    }

    private func row(_ it: VaultItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: Kind.icon(for: it)).foregroundColor(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(it.name).font(.subheadline).lineLimit(1)
                Text(store.pathString(it) == it.name ? "الرئيسية" : store.pathString(it))
                    .font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: it.size, countStyle: .file))
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private func itemList(_ list: [VaultItem]) -> some View {
        VStack(spacing: 6) {
            ForEach(list.prefix(100)) { it in row(it) }
            if list.count > 100 { Text("… و\(list.count - 100) غيرها").font(.caption).foregroundColor(.secondary) }
        }
    }

    private func groupView(_ g: DupGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(g.identical ? "متطابقة" : "متشابهة")
                .font(.caption.weight(.bold))
                .foregroundColor(g.identical ? .orange : .yellow)
            ForEach(g.items) { it in row(it) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.2)))
    }

    private func compareView(_ c: CompareResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("متطابق: \(c.same)").font(.footnote)
            section("فقط في «\(c.nameA)»", c.onlyA)
            section("فقط في «\(c.nameB)»", c.onlyB)
            section("مختلف الحجم", c.different)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ list: [String]) -> some View {
        if !list.isEmpty {
            Text("\(title) (\(list.count))").font(.footnote.weight(.bold))
            ForEach(list.prefix(40), id: \.self) { Text($0).font(.caption).lineLimit(1) }
            if list.count > 40 { Text("…").font(.caption) }
        }
    }

    private func planView(_ p: AIPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(p.folders.enumerated()), id: \.offset) { _, g in
                VStack(alignment: .leading, spacing: 2) {
                    Label(g.name, systemImage: "folder.fill").font(.footnote.weight(.bold))
                    ForEach(g.ids.prefix(12), id: \.self) { id in
                        if let it = store.item(id) { Text("• " + it.name).font(.caption).lineLimit(1) }
                    }
                    if g.ids.count > 12 { Text("… و\(g.ids.count - 12)").font(.caption) }
                }
            }
            ForEach(Array(p.renames.prefix(30).enumerated()), id: \.offset) { _, r in
                if let it = store.item(r.id) { Text("\(it.name) ← \(r.name)").font(.caption).lineLimit(2) }
            }
            if !p.dateIDs.isEmpty { Text("\(p.dateIDs.count) صورة ستُسمّى بتاريخ ووقت الالتقاط").font(.caption) }
        }
    }
}

struct AISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = GeminiConfig.key
    @State private var model = GeminiConfig.model
    @State private var snippets = GeminiConfig.snippets

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("مفتاح Gemini API", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Link("احصل على مفتاح مجاني (Google AI Studio)", destination: URL(string: "https://aistudio.google.com/apikey")!)
                } footer: {
                    Text("المفتاح يُحفظ مشفراً في Keychain على جوالك فقط.")
                }
                Section("الموديل") {
                    TextField("gemini-flash-latest", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Toggle("مقتطفات المحتوى للتصنيف", isOn: $snippets)
                } footer: {
                    Text("لو فُعّل: عند «صنّف المستندات حسب محتواها» تُرسل أول سطور من كل مستند إلى Google. لو عُطّل: يُرسل اسم الملف فقط. الخطة المجانية قد يستخدم فيها Google البيانات لتحسين خدماتها، فلا تفعّله للمستندات الحساسة.")
                }
            }
            .navigationTitle("إعدادات الذكاء")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("حفظ") {
                        GeminiConfig.key = key
                        GeminiConfig.model = model.trimmingCharacters(in: .whitespaces).isEmpty ? "gemini-flash-latest" : model
                        GeminiConfig.snippets = snippets
                        dismiss()
                    }
                }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}


struct ChatHistoryView: View {
    @ObservedObject var vm: Assistant
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if vm.sessions.isEmpty {
                    Text("ما فيه محادثات محفوظة بعد").foregroundColor(.secondary)
                }
                ForEach(vm.sessions.sorted { $0.date > $1.date }) { s in
                    Button {
                        vm.open(s)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(s.title).font(.body).lineLimit(1)
                            Text("\(s.messages.count) رسالة • \(s.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .foregroundColor(.primary)
                    .swipeActions {
                        Button(role: .destructive) { vm.delete(s.id) } label: { Label("حذف", systemImage: "trash") }
                    }
                }
            }
            .navigationTitle("المحادثات السابقة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("تم") { dismiss() } }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .preferredColorScheme(.dark)
    }
}
