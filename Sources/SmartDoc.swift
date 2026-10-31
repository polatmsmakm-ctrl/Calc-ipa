import SwiftUI

private func b64Part(_ d: Data) -> [String: Any] {
    ["inline_data": ["mime_type": "image/jpeg", "data": d.base64EncodedString()]]
}

// MARK: - اسأل عن مستند

struct DocAskView: View {
    let item: VaultItem
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss

    struct Msg: Identifiable { let id = UUID(); let user: Bool; let text: String }

    @State private var confirmed = false
    @State private var loading = false
    @State private var msgs: [Msg] = []
    @State private var input = ""
    @State private var docText = ""
    @State private var docImages: [Data] = []
    @State private var prepared = false
    @State private var error: String?
    @State private var showSettings = false

    private let system = """
    You answer questions about ONE document the user gives you (text and/or page images). \
    Answer in the user's language (Arabic if they write Arabic). Be accurate and concise; if the answer is not in the document, say so. \
    Use plain text (short paragraphs or simple dashes), no markdown tables.
    """

    private let chips = ["لخّصه", "أهم النقاط", "استخرج التواريخ والمبالغ", "ترجمه للعربية"]

    var body: some View {
        NavigationStack {
            Group {
                if !confirmed { confirmView } else { chatView }
            }
            .background(AppBackground())
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("إغلاق") { dismiss() } }
                if confirmed, !msgs.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            UIPasteboard.general.string = msgs.map { ($0.user ? "أنا: " : "Gemini: ") + $0.text }.joined(separator: "\n\n")
                            store.noticeText = "تم نسخ المحادثة"
                        } label: { Image(systemName: "doc.on.doc") }
                    }
                }
            }
            .sheet(isPresented: $showSettings) { AISettingsView() }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .preferredColorScheme(.dark)
    }

    private var confirmView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(Theme.gradient)
            Text("اسأل Gemini عن هذا الملف").font(.title3.weight(.bold))
            Text(item.isImage || item.ext.lowercased() == "pdf"
                 ? "سيُرسل نص الملف (أو صور صفحاته الأولى لو كان ممسوحاً) إلى Google لتحليله."
                 : "سيُرسل نص الملف إلى Google لتحليله.")
                .font(.callout).multilineTextAlignment(.center).foregroundColor(.secondary)
            Text("لا تستخدمه للمستندات شديدة الحساسية. الملف نفسه يبقى مشفراً عندك.")
                .font(.footnote).multilineTextAlignment(.center).foregroundColor(.orange)
            if GeminiConfig.key.isEmpty {
                Button { showSettings = true } label: { Label("أضف مفتاح Gemini", systemImage: "key.fill") }
                    .buttonStyle(.borderedProminent)
            } else {
                Button { confirmed = true } label: { Label("متابعة", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding(24)
    }

    private var chatView: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        if msgs.isEmpty {
                            Text("اختر سؤالاً سريعاً أو اكتب سؤالك عن الملف")
                                .font(.footnote).foregroundColor(.secondary).padding(.top, 30)
                        }
                        ForEach(msgs) { m in
                            Text(m.text)
                                .textSelection(.enabled)
                                .padding(11)
                                .background(RoundedRectangle(cornerRadius: 14)
                                    .fill(m.user ? Theme.accent.opacity(0.35) : Color.white.opacity(0.09)))
                                .frame(maxWidth: .infinity, alignment: m.user ? .trailing : .leading)
                                .contextMenu {
                                    Button { UIPasteboard.general.string = m.text; store.noticeText = "تم النسخ" } label: {
                                        Label("نسخ", systemImage: "doc.on.doc")
                                    }
                                }
                                .id(m.id)
                        }
                        if loading { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
                        if let e = error {
                            Text(e).font(.footnote).foregroundColor(.red).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: msgs.count) { _ in
                    if let l = msgs.last { withAnimation { proxy.scrollTo(l.id, anchor: .bottom) } }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chips, id: \.self) { c in
                        Button { send(c) } label: {
                            Text(c).font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Capsule().fill(Theme.accent.opacity(0.18)))
                        }
                        .disabled(loading)
                    }
                }
                .padding(.horizontal, 14)
            }
            .padding(.vertical, 6)

            HStack(spacing: 8) {
                TextField("اسأل عن الملف…", text: $input, axis: .vertical)
                    .lineLimit(1...3)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.1)))
                Button { let t = input; input = ""; send(t) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 34)).foregroundColor(Theme.accent)
                }
                .disabled(loading || input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 14).padding(.bottom, 10)
        }
    }

    private func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !loading else { return }
        msgs.append(Msg(user: true, text: t))
        loading = true
        error = nil
        Task { @MainActor in
            defer { loading = false }
            if !prepared {
                let p = await store.aiPayload(item, textLimit: 40000, maxImages: 4)
                docText = p.text
                docImages = p.images
                prepared = true
            }
            if docText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && docImages.isEmpty {
                error = "ما قدرت أقرأ محتوى هذا الملف (النص غير متاح)"
                return
            }
            // أول رسالة تحمل المستند، والباقي محادثة عادية
            var turns: [[String: Any]] = []
            var first = true
            for m in msgs {
                if m.user {
                    var parts: [[String: Any]] = []
                    if first {
                        if !docText.isEmpty { parts.append(["text": "DOCUMENT (\(item.name)):\n\(docText)"]) }
                        parts += docImages.map { b64Part($0) }
                        first = false
                    }
                    parts.append(["text": m.text])
                    turns.append(["role": "user", "parts": parts])
                } else {
                    turns.append(["role": "model", "parts": [["text": m.text]]])
                }
            }
            do {
                let r = try await Gemini.generate(system: system, turns: turns, json: false)
                msgs.append(Msg(user: false, text: r.trimmingCharacters(in: .whitespacesAndNewlines)))
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

// MARK: - تسمية ذكية

struct SmartRenameSheet: View {
    let items: [VaultItem]
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss

    struct Row: Identifiable {
        let id: UUID
        let old: String
        let ext: String
        var name: String
        var on = true
    }

    @State private var confirmed = false
    @State private var loading = false
    @State private var rows: [Row] = []
    @State private var error: String?
    @State private var showSettings = false

    private var files: [VaultItem] { Array(items.filter { store.canAskAI($0) && !$0.isNote }.prefix(12)) }

    private let system = """
    You rename files based on their content. For each FILE n you get its current name and its content (text or image). \
    Suggest a short, descriptive file name WITHOUT extension, max 50 characters, in the same language as the content (Arabic for Arabic content), \
    no slashes or special characters, no date unless it is the key info. Return ONE JSON object: {"names":[{"n":1,"name":"..."}]}.
    """

    var body: some View {
        NavigationStack {
            Group {
                if !confirmed { confirmView }
                else if loading { VStack(spacing: 12) { ProgressView(); Text("Gemini يقرأ الملفات…").font(.footnote).foregroundColor(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { resultView }
            }
            .background(AppBackground())
            .navigationTitle("تسمية ذكية")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("إغلاق") { dismiss() } }
                if confirmed, !loading, !rows.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("تطبيق") { apply() }.disabled(!rows.contains { $0.on })
                    }
                }
            }
            .sheet(isPresented: $showSettings) { AISettingsView() }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .preferredColorScheme(.dark)
    }

    private var confirmView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "wand.and.stars").font(.system(size: 44)).foregroundStyle(Theme.gradient)
            Text("تسمية \(files.count) ملف حسب محتواه").font(.title3.weight(.bold))
            Text("سيُرسل محتوى هذه الملفات (نصوص أو صور) إلى Google ليقترح لكل ملف اسماً مناسباً. تراجع الأسماء قبل التطبيق وتقدر تتراجع بعده.")
                .font(.callout).multilineTextAlignment(.center).foregroundColor(.secondary)
            if items.count > 12 { Text("الحد 12 ملف في المرة الواحدة.").font(.footnote).foregroundColor(.orange) }
            if files.isEmpty {
                Text("لا توجد ملفات مدعومة (PDF، صور، نصوص).").foregroundColor(.red)
            } else if GeminiConfig.key.isEmpty {
                Button { showSettings = true } label: { Label("أضف مفتاح Gemini", systemImage: "key.fill") }
                    .buttonStyle(.borderedProminent)
            } else {
                Button { confirmed = true; run() } label: { Label("ابدأ", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding(24)
    }

    private var resultView: some View {
        List {
            if let e = error {
                Text(e).foregroundColor(.red)
            }
            ForEach($rows) { $r in
                HStack(alignment: .top, spacing: 10) {
                    Toggle("", isOn: $r.on).labelsHidden()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.old).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        TextField("الاسم", text: $r.name)
                            .font(.callout.weight(.semibold))
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func run() {
        loading = true
        error = nil
        Task { @MainActor in
            defer { loading = false }
            var parts: [[String: Any]] = []
            var order: [VaultItem] = []
            for (i, f) in files.enumerated() {
                let p = await store.aiPayload(f, textLimit: 1500, maxImages: 1)
                parts.append(["text": "FILE \(i + 1): current name: \(f.name)\nCONTENT:\n\(p.text.isEmpty ? "(see image or empty)" : p.text)"])
                parts += p.images.map { b64Part($0) }
                order.append(f)
            }
            do {
                let raw = try await Gemini.generate(system: system, turns: [["role": "user", "parts": parts]], json: true)
                var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                s = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
                guard let d = s.data(using: .utf8),
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let arr = j["names"] as? [[String: Any]] else {
                    error = "ما فهمت رد Gemini، جرّب مرة ثانية"
                    return
                }
                var out: [Row] = []
                for e in arr {
                    guard let n = (e["n"] as? Int) ?? (e["n"] as? Double).map({ Int($0) }),
                          n >= 1, n <= order.count, let nm = e["name"] as? String else { continue }
                    let it = order[n - 1]
                    let clean = nm.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if clean.isEmpty { continue }
                    out.append(Row(id: it.id, old: it.name, ext: it.ext, name: clean))
                }
                rows = out
                if out.isEmpty { error = "ما طلع اقتراح مناسب" }
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func apply() {
        store.beginGroup("تسمية ذكية")
        var n = 0
        for r in rows where r.on {
            let full = r.ext.isEmpty ? r.name : r.name + "." + r.ext
            store.rename(r.id, to: full)
            n += 1
        }
        store.endGroup()
        store.noticeText = "تمت تسمية \(n) ملف (تقدر تتراجع من ↩︎)"
        dismiss()
    }
}
