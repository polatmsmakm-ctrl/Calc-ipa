import SwiftUI
import Photos
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Root

struct VaultRoot: View {
    @EnvironmentObject var store: VaultStore

    var body: some View {
        NavigationStack {
            FolderView(parent: nil)
                .navigationDestination(for: UUID.self) { id in
                    FolderView(parent: id)
                }
        }
        .overlay {
            if store.busy { BusyOverlay(text: store.busyText) }
        }
        .alert("تعذّر فك التشفير", isPresented: Binding(get: { store.loadFailed }, set: { _ in })) {
            Button("حسناً", role: .cancel) {}
        } message: {
            Text("مفتاح التشفير غير موجود على هذا الجهاز. لن يتم تعديل أو حذف أي بيانات.")
        }
    }
}

struct BusyOverlay: View {
    let text: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().tint(.white).scaleEffect(1.3)
                Text(text).font(.callout).foregroundColor(.white)
            }
            .padding(26)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.15)))
        }
    }
}

// MARK: - Enums for presentation

enum Cover: Identifiable {
    case image(ViewerSpec)
    case preview(URLBox)
    case camera

    var id: String {
        switch self {
        case .image(let s): return "i" + s.id.uuidString
        case .preview(let b): return "p" + b.id.uuidString
        case .camera: return "camera"
        }
    }
}

enum SheetKind: Identifiable {
    case settings
    case move
    case share(ShareBox)

    var id: String {
        switch self {
        case .settings: return "settings"
        case .move: return "move"
        case .share(let b): return "s" + b.id.uuidString
        }
    }
}

// MARK: - Folder view

struct FolderView: View {
    let parent: UUID?

    @EnvironmentObject var store: VaultStore
    @EnvironmentObject var app: AppState

    @State private var selecting = false
    @State private var selection = Set<UUID>()
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: VaultItem?
    @State private var renameText = ""
    @State private var confirmDelete = false
    @State private var cover: Cover?
    @State private var sheet: SheetKind?
    @State private var query = ""
    @AppStorage("calc.sort") private var sortRaw: String = SortMode.name.rawValue

    private var sort: SortMode { SortMode(rawValue: sortRaw) ?? .name }

    private let cols = [GridItem(.adaptive(minimum: 100), spacing: 12)]

    private var title: String {
        if let p = parent, let it = store.item(p) { return it.name }
        return "المحفوظات"
    }

    var body: some View {
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let list = searching ? store.search(query) : store.children(of: parent, sort: sort)
        ScrollView {
            if list.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: searching ? "magnifyingglass" : "tray")
                        .font(.system(size: 44)).foregroundColor(.secondary)
                    Text(searching ? "ما فيه نتائج" : "فاضي — اضغط + للإضافة").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 120)
            }
            LazyVGrid(columns: cols, spacing: 14) {
                ForEach(list) { item in
                    cell(item, list: list)
                }
            }
            .padding(12)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "بحث")
        .toolbar { toolbarContent }
        .photosPicker(isPresented: $showPhotos, selection: $pickerItems, maxSelectionCount: 100,
                      matching: .any(of: [.images, .videos]), photoLibrary: .shared())
        .onChange(of: pickerItems) { picks in importPicked(picks) }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                let target = parent
                Task { @MainActor in
                    await store.importURLs(urls, parent: target)
                }
            }
        }
        .alert("مجلد جديد", isPresented: $showNewFolder) {
            TextField("الاسم", text: $newFolderName)
            Button("إنشاء") {
                store.createFolder(newFolderName, parent: parent)
                newFolderName = ""
            }
            Button("إلغاء", role: .cancel) { newFolderName = "" }
        }
        .alert("إعادة تسمية", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("الاسم", text: $renameText)
            Button("حفظ") {
                if let t = renameTarget { store.rename(t.id, to: renameText) }
                renameTarget = nil
            }
            Button("إلغاء", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog("حذف \(selection.count) عنصر نهائياً؟", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("حذف", role: .destructive) {
                store.delete(selection)
                selection.removeAll()
                selecting = false
            }
        }
        .fullScreenCover(item: $cover) { c in
            switch c {
            case .image(let spec):
                ImageViewer(spec: spec)
            case .preview(let box):
                QuickLookView(url: box.url) { cover = nil }
                    .ignoresSafeArea()
            case .camera:
                CameraPicker { data in
                    cover = nil
                    if let d = data { importCamera(d) }
                }
                .ignoresSafeArea()
            }
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .settings:
                SettingsView()
            case .move:
                MoveSheet(ids: selection) {
                    selection.removeAll()
                    selecting = false
                }
            case .share(let box):
                ShareSheet(urls: box.urls)
            }
        }
    }

    // MARK: toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if parent == nil {
                HStack(spacing: 16) {
                    Button { app.lock() } label: { Image(systemName: "lock.fill") }
                    Button { sheet = .settings } label: { Image(systemName: "gearshape") }
                }
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 16) {
                Button(selecting ? "إلغاء" : "تحديد") {
                    selecting.toggle()
                    selection.removeAll()
                }
                Menu {
                    Picker("ترتيب", selection: $sortRaw) {
                        ForEach(SortMode.allCases) { m in
                            Text(m.title).tag(m.rawValue)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down.circle")
                }
                Menu {
                    Button { showNewFolder = true } label: { Label("مجلد جديد", systemImage: "folder.badge.plus") }
                    Button { showPhotos = true } label: { Label("من الصور", systemImage: "photo.on.rectangle") }
                    Button { showFiles = true } label: { Label("من الملفات", systemImage: "doc.badge.plus") }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { cover = .camera } label: { Label("تصوير", systemImage: "camera") }
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            if selecting {
                Button { shareItems(selectedItems()) } label: { Image(systemName: "square.and.arrow.up") }
                    .disabled(selection.isEmpty)
                Spacer()
                Button { sheet = .move } label: { Image(systemName: "folder") }
                    .disabled(selection.isEmpty)
                Spacer()
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .disabled(selection.isEmpty)
            }
        }
    }

    // MARK: cells

    @ViewBuilder
    private func cell(_ item: VaultItem, list: [VaultItem]) -> some View {
        if selecting {
            ItemTile(item: item, selected: selection.contains(item.id))
                .onTapGesture {
                    if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
                }
        } else if item.isFolder {
            NavigationLink(value: item.id) {
                ItemTile(item: item, selected: false)
            }
            .buttonStyle(.plain)
            .contextMenu { menu(for: item) }
        } else {
            ItemTile(item: item, selected: false)
                .onTapGesture { open(item, list: list) }
                .contextMenu { menu(for: item) }
        }
    }

    @ViewBuilder
    private func menu(for item: VaultItem) -> some View {
        Button {
            renameText = item.name
            renameTarget = item
        } label: { Label("إعادة تسمية", systemImage: "pencil") }

        Button {
            selection = [item.id]
            sheet = .move
        } label: { Label("نقل", systemImage: "folder") }

        if !item.isFolder {
            Button { shareItems([item]) } label: { Label("مشاركة / حفظ خارجي", systemImage: "square.and.arrow.up") }
        }

        Button(role: .destructive) {
            selection = [item.id]
            confirmDelete = true
        } label: { Label("حذف", systemImage: "trash") }
    }

    // MARK: actions

    private func selectedItems() -> [VaultItem] {
        selection.compactMap { store.item($0) }
    }

    private func open(_ item: VaultItem, list: [VaultItem]) {
        if item.isImage {
            let imgs = list.filter { $0.isImage }
            let idx = imgs.firstIndex(where: { $0.id == item.id }) ?? 0
            cover = .image(ViewerSpec(items: imgs, start: idx))
        } else {
            Task { @MainActor in
                store.busy = true
                store.busyText = "جاري التجهيز…"
                if let url = try? await store.exportURL(for: item) {
                    cover = .preview(URLBox(url: url))
                }
                store.busy = false
            }
        }
    }

    private func shareItems(_ its: [VaultItem]) {
        let files = its.filter { !$0.isFolder }
        guard !files.isEmpty else { return }
        Task { @MainActor in
            store.busy = true
            store.busyText = "جاري التجهيز…"
            var urls: [URL] = []
            for f in files {
                if let u = try? await store.exportURL(for: f) { urls.append(u) }
            }
            store.busy = false
            if !urls.isEmpty { sheet = .share(ShareBox(urls: urls)) }
        }
    }

    private func importPicked(_ picks: [PhotosPickerItem]) {
        guard !picks.isEmpty else { return }
        let target = parent
        pickerItems = []
        let wipe = UserDefaults.standard.bool(forKey: "calc.delOrig")
        Task { @MainActor in
            store.busy = true
            store.busyText = "جاري التحميل…"
            var urls: [URL] = []
            var idFor: [URL: String] = [:]
            for p in picks {
                if let f = try? await p.loadTransferable(type: PickedFile.self) {
                    urls.append(f.url)
                    if let id = p.itemIdentifier { idFor[f.url] = id }
                }
            }
            let ok = await store.importURLs(urls, parent: target)
            for u in urls { try? FileManager.default.removeItem(at: u.deletingLastPathComponent()) }
            if wipe {
                await PhotoCleaner.delete(ok.compactMap { idFor[$0] })
            }
        }
    }

    private func importCamera(_ data: Data) {
        let target = parent
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        let name = "IMG_" + f.string(from: Date()) + ".jpg"
        Task { @MainActor in
            await store.importData(data, name: name, parent: target)
        }
    }
}

// MARK: - Tile

struct ItemTile: View {
    let item: VaultItem
    let selected: Bool
    @EnvironmentObject var store: VaultStore
    @State private var thumb: UIImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(white: 0.16))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { content }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, .blue)
                        .padding(6)
                }
            }
            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundColor(.primary)
        }
        .contentShape(Rectangle())
        .task(id: item.id) {
            if thumb == nil && (item.isImage || item.isVideo) {
                thumb = await store.loadThumb(item.id)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let t = thumb {
            ZStack {
                Image(uiImage: t).resizable().scaledToFill()
                if item.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.title)
                        .foregroundColor(.white.opacity(0.9))
                }
            }
        } else {
            Image(systemName: Kind.icon(for: item))
                .font(.system(size: 34))
                .foregroundColor(item.isFolder ? .yellow : .secondary)
        }
    }
}

// MARK: - Image viewer

struct ImageViewer: View {
    let spec: ViewerSpec
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

    init(spec: ViewerSpec) {
        self.spec = spec
        _index = State(initialValue: spec.start)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(spec.items.enumerated()), id: \.offset) { pair in
                    ZoomableImage(item: pair.element).tag(pair.offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundColor(.white.opacity(0.8))
                    .padding()
            }
        }
    }
}

struct ZoomableImage: View {
    let item: VaultItem
    @EnvironmentObject var store: VaultStore
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(magnify)
                    .simultaneousGesture(drag)
                    .onTapGesture(count: 2) {
                        withAnimation { resetZoom() }
                    }
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { image = await store.loadImage(item) }
    }

    private func resetZoom() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }

    private var magnify: some Gesture {
        MagnificationGesture()
            .onChanged { v in
                scale = max(1, min(baseScale * v, 6))
            }
            .onEnded { _ in
                baseScale = scale
                if scale <= 1 { offset = .zero; baseOffset = .zero }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { v in
                guard scale > 1 else { return }
                offset = CGSize(width: baseOffset.width + v.translation.width,
                                height: baseOffset.height + v.translation.height)
            }
            .onEnded { _ in
                baseOffset = offset
            }
    }
}

// MARK: - Move

struct MoveSheet: View {
    let ids: Set<UUID>
    let onDone: () -> Void
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button { go(nil) } label: { Label("الرئيسية", systemImage: "house") }
                ForEach(store.folderChoices(excluding: ids)) { c in
                    Button { go(c.item.id) } label: { Label(c.path, systemImage: "folder") }
                }
            }
            .navigationTitle("نقل إلى")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("إلغاء") { dismiss() }
                }
            }
        }
    }

    private func go(_ target: UUID?) {
        store.move(ids, to: target)
        onDone()
        dismiss()
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var newCode = ""
    @State private var confirm = ""
    @State private var msg = ""
    @State private var bio = Bio.enabled
    @AppStorage("calc.delOrig") private var delOrig = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("الرمز الجديد (٤ أرقام على الأقل)", text: $newCode)
                        .keyboardType(.numberPad)
                    SecureField("تأكيد الرمز", text: $confirm)
                        .keyboardType(.numberPad)
                    Button("حفظ الرمز") { saveCode() }
                    if !msg.isEmpty {
                        Text(msg).font(.footnote).foregroundColor(.secondary)
                    }
                } header: {
                    Text("الرمز السري")
                } footer: {
                    Text("تكتب الرمز في الحاسبة وتضغط = لفتح الخزنة.")
                }

                if Bio.available {
                    Section {
                        Toggle("الفتح بالبصمة / الوجه", isOn: $bio)
                    } footer: {
                        Text("اضغط مطوّلاً على شاشة الأرقام في الحاسبة.")
                    }
                }

                Section {
                    Toggle("حذف الأصل من الصور بعد الاستيراد", isOn: $delOrig)
                } footer: {
                    Text("iOS يطلب تأكيدك قبل الحذف، والمحذوف يبقى ٣٠ يوم في «المحذوفة مؤخراً» في الصور — احذفه منها بنفسك.")
                }

                Section {
                    LabeledContent("الحجم", value: ByteCountFormatter.string(fromByteCount: store.totalSize, countStyle: .file))
                    LabeledContent("عدد الملفات", value: "\(store.items.filter { !$0.isFolder }.count)")
                } header: {
                    Text("التخزين")
                }
            }
            .navigationTitle("الإعدادات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("تم") { dismiss() }
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
    }

    private func saveCode() {
        let digitsOnly = newCode.allSatisfy { "0123456789".contains($0) }
        guard digitsOnly, newCode.count >= 4, newCode.count <= 12 else {
            msg = "الرمز أرقام فقط، من ٤ إلى ١٢ رقم."
            return
        }
        guard newCode == confirm else {
            msg = "الرمزان غير متطابقين."
            return
        }
        Passcode.set(newCode)
        newCode = ""
        confirm = ""
        msg = "تم تغيير الرمز."
    }
}
