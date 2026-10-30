import SwiftUI
import UniformTypeIdentifiers

// MARK: - Media tab

struct MediaTab: View {
    @EnvironmentObject var store: VaultStore
    @StateObject private var p = Presenter()

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        let media = store.allMedia
        let photos = media.filter { $0.isImage }.count
        let videos = media.count - photos

        ScrollView {
            if media.isEmpty {
                EmptyState(icon: "photo.on.rectangle.angled", text: "ما فيه صور أو فيديوهات بعد.\nأضفها من تبويب الملفات.")
            } else {
                HStack {
                    Text("\(photos) صورة · \(videos) فيديو")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)

                LazyVGrid(columns: cols, spacing: 2) {
                    ForEach(media) { it in
                        Color.clear
                            .aspectRatio(1, contentMode: .fit)
                            .overlay { ThumbView(item: it).clipped() }
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture { p.open(it, in: media, store: store) }
                    }
                }
            }
        }
        .background(AppBackground())
        .navigationTitle("الوسائط")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) { LockButton() }
        }
        .presentations(p)
    }
}

// MARK: - Favorites + tags

struct FavoritesTab: View {
    @EnvironmentObject var store: VaultStore
    @StateObject private var p = Presenter()
    @State private var tag: String?

    private let cols = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        let tags = store.allTags
        let list = tag == nil ? store.favorites : store.items(withTag: tag ?? "")

        ScrollView {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button { tag = nil } label: {
                        Chip(title: "المفضلة", icon: "star.fill", selected: tag == nil)
                    }
                    ForEach(tags, id: \.self) { t in
                        Button { tag = t } label: {
                            Chip(title: t, icon: "tag.fill", selected: tag == t)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }

            if list.isEmpty {
                EmptyState(
                    icon: tag == nil ? "star" : "tag",
                    text: tag == nil ? "ما فيه مفضلة بعد.\nاضغط مطوّلاً على أي ملف وأضفه للمفضلة." : "ما فيه عناصر بهذا الوسم."
                )
            } else {
                LazyVGrid(columns: cols, spacing: 14) {
                    ForEach(list) { item in
                        if item.isFolder {
                            NavigationLink(value: item.id) {
                                ItemTile(item: item, selected: false, count: store.folderCount(item.id))
                            }
                            .buttonStyle(.plain)
                        } else {
                            ItemTile(item: item, selected: false, count: 0)
                                .onTapGesture { p.open(item, in: list, store: store) }
                                .contextMenu {
                                    Button { store.toggleFav(item.id) } label: {
                                        Label("إزالة من المفضلة", systemImage: "star.slash")
                                    }
                                    Button { p.sheet = .tags(item) } label: { Label("وسوم", systemImage: "tag") }
                                }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }
        }
        .background(AppBackground())
        .navigationTitle("المفضلة")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) { LockButton() }
        }
        .presentations(p)
    }
}

struct TagsSheet: View {
    let item: VaultItem
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("مثال: عمل، شخصي، مهم", text: $text)
                } header: {
                    Text("الوسوم")
                } footer: {
                    Text("افصل بين الوسوم بفاصلة.")
                }

                let existing = store.allTags
                if !existing.isEmpty {
                    Section("وسوم موجودة") {
                        ForEach(existing, id: \.self) { t in
                            Button(t) { append(t) }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") {
                        let parts = text
                            .replacingOccurrences(of: "،", with: ",")
                            .split(separator: ",")
                            .map { String($0) }
                        store.setTags(item.id, parts)
                        dismiss()
                    }
                }
            }
            .onAppear {
                text = (store.item(item.id)?.tags ?? []).joined(separator: ", ")
            }
        }
    }

    private func append(_ t: String) {
        let cur = text
            .replacingOccurrences(of: "،", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if !cur.contains(t) {
            text = (cur + [t]).joined(separator: ", ")
        }
    }
}

// MARK: - Notes

struct NotesTab: View {
    @EnvironmentObject var store: VaultStore
    @StateObject private var p = Presenter()
    @State private var query = ""

    var body: some View {
        let all = store.notes
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = q.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(q) }

        Group {
            if list.isEmpty {
                ScrollView {
                    EmptyState(icon: "note.text", text: q.isEmpty ? "ما فيه ملاحظات.\nاضغط + لإضافة ملاحظة أو كلمات سر مشفّرة." : "ما فيه نتائج")
                }
            } else {
                List {
                    ForEach(list) { n in
                        Button { p.open(n, in: list, store: store) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "note.text")
                                    .font(.title3)
                                    .foregroundStyle(Theme.gradient)
                                    .frame(width: 38, height: 38)
                                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(n.name).font(.body.weight(.medium)).foregroundColor(.primary)
                                    Text(n.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if n.isFavorite {
                                    Image(systemName: "star.fill").font(.caption).foregroundColor(.yellow)
                                }
                            }
                        }
                        .listRowBackground(Color.white.opacity(0.05))
                        .swipeActions {
                            Button(role: .destructive) { store.trash([n.id]) } label: {
                                Label("حذف", systemImage: "trash")
                            }
                            Button { store.toggleFav(n.id) } label: {
                                Label("مفضلة", systemImage: "star")
                            }
                            .tint(.yellow)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(AppBackground())
        .navigationTitle("الملاحظات")
        .searchable(text: $query, prompt: "بحث")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) { LockButton() }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { p.sheet = .note(NoteSpec(item: nil, parent: nil)) } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
        }
        .presentations(p)
    }
}

struct NoteEditor: View {
    let spec: NoteSpec
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var text = ""
    @State private var fields: [NoteField] = []
    @State private var origTitle = ""
    @State private var origText = ""
    @State private var origFields: [NoteField] = []
    @State private var loaded = false
    @State private var revealed = Set<UUID>()
    @State private var confirmClose = false

    private var changed: Bool {
        title != origTitle || text != origText || fields != origFields
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("العنوان", text: $title)
                        .font(.headline)
                }
                Section("النص") {
                    TextEditor(text: $text)
                        .frame(minHeight: 150)
                }
                Section {
                    ForEach($fields) { $f in
                        fieldRow($f)
                    }
                    .onDelete { fields.remove(atOffsets: $0) }

                    Button {
                        fields.append(NoteField(label: "", value: "", secret: false))
                    } label: {
                        Label("إضافة حقل", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("حقول (مثل: اسم المستخدم، كلمة السر)")
                } footer: {
                    Text("الحقل السري يظهر مخفي، والنسخ يُمسح من الحافظة بعد ٤٥ ثانية.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle(spec.item == nil ? "ملاحظة جديدة" : "ملاحظة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إغلاق") {
                        if changed { confirmClose = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") { save() }
                        .disabled(!loaded)
                }
            }
            .confirmationDialog("تجاهل التعديلات؟", isPresented: $confirmClose, titleVisibility: .visible) {
                Button("تجاهل", role: .destructive) { dismiss() }
                Button("متابعة التحرير", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(changed)
        .task { await load() }
    }

    private func fieldRow(_ f: Binding<NoteField>) -> some View {
        let id = f.wrappedValue.id
        let hidden = f.wrappedValue.secret && !revealed.contains(id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                TextField("اسم الحقل", text: f.label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if f.wrappedValue.secret {
                    Button {
                        if revealed.contains(id) { revealed.remove(id) } else { revealed.insert(id) }
                    } label: {
                        Image(systemName: revealed.contains(id) ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
                Button { copy(f.wrappedValue.value) } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                Button { f.wrappedValue.secret.toggle() } label: {
                    Image(systemName: f.wrappedValue.secret ? "lock.fill" : "lock.open")
                        .foregroundColor(f.wrappedValue.secret ? Theme.accent : .secondary)
                }
                .buttonStyle(.borderless)
            }
            if hidden {
                SecureField("القيمة", text: f.value)
            } else {
                TextField("القيمة", text: f.value)
            }
        }
        .padding(.vertical, 2)
    }

    private func copy(_ value: String) {
        UIPasteboard.general.setItems(
            [["public.utf8-plain-text": value]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(45)
            ]
        )
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func load() async {
        guard !loaded else { return }
        if let it = spec.item {
            title = it.name
            if let c = await store.loadNote(it) {
                text = c.body
                fields = c.fields
            }
        }
        origTitle = title
        origText = text
        origFields = fields
        loaded = true
    }

    private func save() {
        let content = NoteContent(body: text, fields: fields.filter { !$0.label.isEmpty || !$0.value.isEmpty })
        store.saveNote(id: spec.item?.id, title: title, content: content, parent: spec.parent)
        dismiss()
    }
}

// MARK: - Trash

struct TrashView: View {
    @EnvironmentObject var store: VaultStore
    @State private var confirmEmpty = false

    var body: some View {
        let list = store.trashed

        Group {
            if list.isEmpty {
                ScrollView {
                    EmptyState(icon: "trash", text: "المحذوفات فاضية.\nالمحذوف يبقى هنا ٧ أيام قبل الحذف النهائي.")
                }
            } else {
                List {
                    ForEach(list) { it in
                        HStack(spacing: 12) {
                            Image(systemName: Kind.icon(for: it))
                                .foregroundStyle(it.isFolder ? AnyShapeStyle(Theme.folderGradient) : AnyShapeStyle(Theme.gradient))
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(it.name).lineLimit(1)
                                Text(remaining(it))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .listRowBackground(Color.white.opacity(0.05))
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { store.permanentlyDelete([it.id]) } label: {
                                Label("حذف نهائي", systemImage: "xmark.bin")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button { store.restore(it.id) } label: {
                                Label("استرجاع", systemImage: "arrow.uturn.backward")
                            }
                            .tint(.green)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(AppBackground())
        .navigationTitle("المحذوفات")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !list.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("تفريغ", role: .destructive) { confirmEmpty = true }
                }
            }
        }
        .confirmationDialog("حذف كل المحذوفات نهائياً؟", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("حذف نهائي", role: .destructive) { store.emptyTrash() }
        }
    }

    private func remaining(_ it: VaultItem) -> String {
        guard let d = it.deletedAt else { return "" }
        let left = 7 - Calendar.current.dateComponents([.day], from: d, to: Date()).day!
        return left <= 0 ? "يُحذف اليوم" : "يُحذف بعد \(left) يوم"
    }
}

// MARK: - Settings

enum SettingsSheet: Identifiable {
    case code(PasscodeKind)
    case backup
    case restore

    var id: String {
        switch self {
        case .code(let k): return "code-" + k.rawValue
        case .backup: return "backup"
        case .restore: return "restore"
        }
    }
}

struct SettingsTab: View {
    @EnvironmentObject var store: VaultStore
    @AppStorage("calc.delOrig") private var delOrig = false
    @AppStorage("calc.lockFlip") private var lockFlip = false
    @AppStorage("calc.lockShake") private var lockShake = false
    @State private var bio = Bio.enabled
    @State private var sheet: SettingsSheet?
    @State private var logTick = 0
    @State private var iconName: String? = UIApplication.shared.alternateIconName
    @State private var iconMsg = ""

    private let icons: [(title: String, name: String?, preview: String)] = [
        ("اللعبة", nil, "PrevCalc"),
        ("ملاحظات", "IconNotes", "PrevNotes"),
        ("طقس", "IconWeather", "PrevWeather"),
        ("ساعة", "IconClock", "PrevClock")
    ]

    private var isReal: Bool { store.mode == .real }

    var body: some View {
        Form {
            if isReal {
                codesSection
                securitySection
                intruderSection
            }

            privacySection
            iconSection

            if isReal {
                backupSection
            }

            storageSection
        }
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle("الإعدادات")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) { LockButton() }
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .code(let k): CodeSheet(kind: k)
            case .backup: BackupSheet()
            case .restore: RestoreSheet()
            }
        }
        .onChange(of: bio) { v in
            if v {
                Bio.authenticate { ok in
                    if ok { Bio.enabled = true } else { bio = false }
                }
            } else {
                Bio.enabled = false
            }
        }
    }

    // MARK: sections

    private var codesSection: some View {
        Section {
            Button { sheet = .code(.real) } label: {
                row("تغيير الرمز السري", icon: "key.fill", color: Theme.accent, value: nil)
            }
            Button { sheet = .code(.decoy) } label: {
                row("رمز التمويه", icon: "theatermasks.fill", color: .orange,
                    value: Passcode.isSet(.decoy) ? "مفعّل" : "غير مفعّل")
            }
            Button { sheet = .code(.panic) } label: {
                row("رمز الطوارئ", icon: "exclamationmark.triangle.fill", color: .red,
                    value: Passcode.isSet(.panic) ? "مفعّل" : "غير مفعّل")
            }
        } header: {
            Text("الرموز")
        } footer: {
            Text("التمويه: يفتح خزنة وهمية منفصلة. الطوارئ: يمسح خزنتك الحقيقية بصمت ويفتح الوهمية.")
        }
    }

    private var securitySection: some View {
        Section {
            if Bio.available {
                Toggle(isOn: $bio) {
                    rowLabel("الفتح بالبصمة / الوجه", icon: "faceid", color: .green)
                }
            }
            Toggle(isOn: $lockFlip) {
                rowLabel("قفل عند قلب الجوال", icon: "iphone.gen3.radiowaves.left.and.right", color: .purple)
            }
            Toggle(isOn: $lockShake) {
                rowLabel("قفل عند الهز", icon: "waveform.path", color: .pink)
            }
        } header: {
            Text("القفل")
        } footer: {
            Text("البصمة: اضغط مطوّلاً على عنوان اللعبة (PUFF DASH) في الشاشة الرئيسية. القفل بالقلب والهز يشتغل من الفتح القادم. والتطبيق يقفل تلقائياً عند الخروج منه، ويحجب الشاشة أثناء تسجيل الشاشة.")
        }
    }

    private var intruderSection: some View {
        Section {
            LabeledContent("محاولات فاشلة", value: "\(Attempts.total)")
            if let d = Attempts.last {
                LabeledContent("آخر محاولة", value: d.formatted(date: .abbreviated, time: .shortened))
            }
            LabeledContent("لقطات شاشة داخل الخزنة", value: "\(Attempts.shots)")
            Button("مسح السجل", role: .destructive) {
                Attempts.clearLog()
                logTick += 1
            }
        } header: {
            Text("سجل المحاولات")
        } footer: {
            Text("بعد ٥ محاولات خاطئة متتالية يتأخر الفتح (دقيقة وتتضاعف، حتى ساعة).")
        }
        .id(logTick)
    }

    private var privacySection: some View {
        Section {
            Toggle(isOn: $delOrig) {
                rowLabel("حذف الأصل من الصور بعد الاستيراد", icon: "photo.badge.minus", color: .teal)
            }
        } header: {
            Text("الخصوصية")
        } footer: {
            Text("iOS يطلب تأكيدك قبل الحذف، والمحذوف يبقى ٣٠ يوم في «المحذوفة مؤخراً» في الصور، فاحذفه منها بنفسك.")
        }
    }

    private var iconSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(icons, id: \.preview) { opt in
                        Button { setIcon(opt.name) } label: {
                            VStack(spacing: 6) {
                                Image(opt.preview)
                                    .resizable()
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                                            .stroke(iconName == opt.name ? Theme.accent : Color.clear, lineWidth: 3)
                                    )
                                Text(opt.title)
                                    .font(.caption)
                                    .foregroundColor(iconName == opt.name ? Theme.accent : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            }
            if !iconMsg.isEmpty {
                Text(iconMsg).font(.footnote).foregroundColor(.secondary)
            }
        } header: {
            Text("أيقونة التطبيق")
        } footer: {
            Text("تغيّر شكل الأيقونة فقط. اسم التطبيق يبقى «Puff Dash».")
        }
    }

    private var backupSection: some View {
        Section {
            Button { sheet = .backup } label: {
                row("إنشاء نسخة احتياطية مشفّرة", icon: "externaldrive.fill.badge.checkmark", color: .blue, value: nil)
            }
            Button { sheet = .restore } label: {
                row("استعادة من نسخة", icon: "arrow.down.doc.fill", color: .indigo, value: nil)
            }
        } header: {
            Text("النسخ الاحتياطي")
        } footer: {
            Text("النسخة ملف واحد مشفّر بكلمة سر تحددها أنت، احفظه في مكان آمن. بدون الكلمة ما تنفتح.")
        }
    }

    private var storageSection: some View {
        Section {
            LabeledContent("الحجم", value: ByteCountFormatter.string(fromByteCount: store.totalSize, countStyle: .file))
            LabeledContent("عدد الملفات", value: "\(store.liveFileCount)")
            NavigationLink {
                TrashView()
            } label: {
                HStack {
                    rowLabel("المحذوفات", icon: "trash.fill", color: .gray)
                    Spacer()
                    if !store.trashed.isEmpty {
                        Text("\(store.trashed.count)").foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Text("التخزين")
        }
    }

    // MARK: helpers

    private func rowLabel(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.gradient))
            Text(title)
        }
    }

    private func row(_ title: String, icon: String, color: Color, value: String?) -> some View {
        HStack {
            rowLabel(title, icon: icon, color: color)
            Spacer()
            if let value { Text(value).foregroundColor(.secondary) }
            Image(systemName: "chevron.left")
                .font(.caption.weight(.semibold))
                .foregroundColor(Color(white: 0.4))
        }
        .foregroundColor(.primary)
    }

    private func setIcon(_ name: String?) {
        guard UIApplication.shared.supportsAlternateIcons else {
            iconMsg = "الجهاز ما يدعم تغيير الأيقونة."
            return
        }
        UIApplication.shared.setAlternateIconName(name) { err in
            DispatchQueue.main.async {
                if let err {
                    iconMsg = "تعذّر تغيير الأيقونة: " + err.localizedDescription
                } else {
                    iconName = name
                    iconMsg = ""
                }
            }
        }
    }
}

// MARK: - Passcode sheet

struct CodeSheet: View {
    let kind: PasscodeKind
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var confirm = ""
    @State private var msg = ""

    private var title: String {
        switch kind {
        case .real: return "تغيير الرمز السري"
        case .decoy: return "رمز التمويه"
        case .panic: return "رمز الطوارئ"
        }
    }

    private var explanation: String {
        switch kind {
        case .real:
            return "تكتبه في شاشة CODE في اللعبة وتضغط OK لفتح خزنتك."
        case .decoy:
            return "رمز ثاني يفتح خزنة وهمية منفصلة تقدر تحط فيها ملفات عادية. استخدمه لو أحد أجبرك تفتح التطبيق."
        case .panic:
            return "تحذير: لما تكتب هذا الرمز وتضغط = تنمسح خزنتك الحقيقية كاملة بصمت وبدون تأكيد، ويفتح التطبيق الخزنة الوهمية. سوّ نسخة احتياطية قبل."
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("الرمز الجديد (٤ إلى ١٢ رقم)", text: $code)
                        .keyboardType(.numberPad)
                    SecureField("تأكيد الرمز", text: $confirm)
                        .keyboardType(.numberPad)
                    Button("حفظ") { save() }
                    if !msg.isEmpty {
                        Text(msg).font(.footnote).foregroundColor(.red)
                    }
                } footer: {
                    Text(explanation)
                }

                if kind != .real && Passcode.isSet(kind) {
                    Section {
                        Button("إلغاء هذا الرمز", role: .destructive) {
                            Passcode.clear(kind)
                            dismiss()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إغلاق") { dismiss() }
                }
            }
        }
    }

    private func save() {
        let digitsOnly = code.allSatisfy { "0123456789".contains($0) }
        guard digitsOnly, code.count >= 4, code.count <= 12 else {
            msg = "الرمز أرقام فقط، من ٤ إلى ١٢ رقم."
            return
        }
        guard code == confirm else {
            msg = "الرمزان غير متطابقين."
            return
        }
        guard !Passcode.conflicts(code, except: kind) else {
            msg = "هذا الرمز مستخدم لشي ثاني، اختر رمزاً مختلفاً."
            return
        }
        Passcode.set(code, kind: kind)
        dismiss()
    }
}

// MARK: - Backup / restore

struct BackupSheet: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var pw = ""
    @State private var pw2 = ""
    @State private var msg = ""
    @State private var working = false
    @State private var shareBox: ShareBox?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("كلمة سر النسخة", text: $pw)
                    SecureField("تأكيد الكلمة", text: $pw2)
                } footer: {
                    Text("احفظ الكلمة: ما فيه طريقة لاسترجاعها. الملف النهائي تحفظه في «الملفات» أو أي مكان تختاره.")
                }

                Section {
                    Button {
                        start()
                    } label: {
                        HStack {
                            if working { ProgressView() }
                            Text(working ? "جاري التشفير…" : "إنشاء النسخة")
                        }
                    }
                    .disabled(working || pw.count < 6)

                    if !msg.isEmpty {
                        Text(msg).font(.footnote).foregroundColor(.red)
                    }
                } footer: {
                    Text("كلمة السر ٦ أحرف على الأقل. إذا الخزنة كبيرة قد تأخذ وقتاً، وتحتاج مساحة فاضية بحجمها تقريباً.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("نسخة احتياطية")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إغلاق") { dismiss() }
                }
            }
            .sheet(item: $shareBox) { b in
                ShareSheet(urls: b.urls)
            }
        }
    }

    private func start() {
        guard pw == pw2 else {
            msg = "الكلمتان غير متطابقتين."
            return
        }
        msg = ""
        working = true
        Task { @MainActor in
            do {
                let url = try await store.makeBackup(password: pw)
                working = false
                shareBox = ShareBox(urls: [url])
            } catch {
                working = false
                msg = "فشل إنشاء النسخة."
            }
        }
    }
}

struct RestoreSheet: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var picked: URL?
    @State private var pw = ""
    @State private var msg = ""
    @State private var ok = false
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showImporter = true
                    } label: {
                        Label(picked?.lastPathComponent ?? "اختيار ملف النسخة", systemImage: "doc.badge.plus")
                    }
                    SecureField("كلمة سر النسخة", text: $pw)
                }

                Section {
                    Button {
                        start()
                    } label: {
                        HStack {
                            if working { ProgressView() }
                            Text(working ? "جاري الاستعادة…" : "استعادة")
                        }
                    }
                    .disabled(working || picked == nil || pw.isEmpty)

                    if !msg.isEmpty {
                        Text(msg).font(.footnote).foregroundColor(ok ? .green : .red)
                    }
                } footer: {
                    Text("الاستعادة تضيف الملفات الناقصة ولا تحذف شي موجود عندك.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("استعادة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إغلاق") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .item], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result { picked = urls.first }
            }
        }
    }

    private func start() {
        guard let url = picked else { return }
        working = true
        msg = ""
        Task { @MainActor in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let n = try await store.restoreBackup(from: url, password: pw)
                working = false
                ok = true
                msg = n > 0 ? "تمت الاستعادة: \(n) عنصر." : "ما فيه شي جديد للإضافة."
            } catch BackupError.badPassword {
                working = false
                ok = false
                msg = "كلمة السر غير صحيحة."
            } catch {
                working = false
                ok = false
                msg = "الملف تالف أو ليس نسخة صالحة."
            }
        }
    }
}
