import SwiftUI
import Photos
import PhotosUI
import AVKit
import UniformTypeIdentifiers

// MARK: - Presentation specs

struct NoteSpec: Identifiable {
    let id = UUID()
    let item: VaultItem?
    let parent: UUID?
}

struct MoveSpec: Identifiable {
    let id = UUID()
    let ids: Set<UUID>
    var copy = false
    let onDone: () -> Void
}

enum Cover: Identifiable {
    case media(ViewerSpec)
    case video(VaultItem)
    case preview(URLBox)
    case camera(UUID?)
    case scanner(UUID?)
    case files(UUID?)
    case folder(UUID?)

    var id: String {
        switch self {
        case .media(let s): return "m" + s.id.uuidString
        case .video(let v): return "v" + v.id.uuidString
        case .preview(let b): return "p" + b.id.uuidString
        case .camera: return "camera"
        case .scanner: return "scanner"
        case .files: return "files"
        case .folder: return "folder"
        }
    }
}

enum SheetKind: Identifiable {
    case note(NoteSpec)
    case tags(VaultItem)
    case share(ShareBox)
    case move(MoveSpec)
    case assistant(UUID?)

    var id: String {
        switch self {
        case .note(let s): return "n" + s.id.uuidString
        case .tags(let i): return "t" + i.id.uuidString
        case .share(let b): return "s" + b.id.uuidString
        case .move(let m): return "mv" + m.id.uuidString
        case .assistant: return "assistant"
        }
    }
}

// MARK: - Presenter

@MainActor
final class Presenter: ObservableObject {
    @Published var cover: Cover?
    @Published var sheet: SheetKind?

    func open(_ item: VaultItem, in list: [VaultItem], store: VaultStore) {
        store.markOpened(item.id)
        if item.isNote {
            sheet = .note(NoteSpec(item: item, parent: item.parent))
            return
        }
        if item.isVideo {
            cover = .video(item)          // الفيديو يُفتح لحاله: السحب يمين/يسار لا ينقل لفيديو ثاني
            return
        }
        if item.isImage {
            let imgs = list.filter { $0.isImage }
            let idx = imgs.firstIndex(where: { $0.id == item.id }) ?? 0
            cover = .media(ViewerSpec(items: imgs.isEmpty ? [item] : imgs, start: idx))
            return
        }
        Task { @MainActor in
            store.busy = true
            store.busyText = "جاري التجهيز…"
            if let url = try? await store.exportURL(for: item) {
                cover = .preview(URLBox(url: url))
            }
            store.busy = false
        }
    }

    func share(_ items: [VaultItem], store: VaultStore) {
        let files = items.filter { !$0.isFolder && !$0.isNote }
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
}

struct Presentations: ViewModifier {
    @ObservedObject var p: Presenter
    @EnvironmentObject var store: VaultStore

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $p.cover) { c in
                switch c {
                case .media(let spec):
                    MediaViewer(spec: spec)
                case .video(let item):
                    VideoPlayerScreen(item: item)
                        .environmentObject(store)
                case .preview(let box):
                    QuickLookView(url: box.url) { p.cover = nil }
                        .ignoresSafeArea()
                case .camera(let parent):
                    CameraPicker { data in
                        p.cover = nil
                        if let d = data {
                            let f = DateFormatter()
                            f.dateFormat = "yyyyMMdd_HHmmss"
                            let name = "IMG_" + f.string(from: Date()) + ".jpg"
                            Task { await store.importData(d, name: name, parent: parent) }
                        }
                    }
                    .ignoresSafeArea()
                case .files(let parent):
                    // asCopy: النظام ينسخ الملفات (ويحمّلها من iCloud لو لزم) إلى مجلد مؤقت عندنا
                    DocumentPicker(folder: false) { urls in
                        p.cover = nil
                        guard !urls.isEmpty else { return }
                        Task { @MainActor in
                            await store.importURLs(urls, parent: parent)
                            for u in urls { try? FileManager.default.removeItem(at: u) }
                        }
                    }
                    .ignoresSafeArea()
                case .folder(let parent):
                    DocumentPicker(folder: true) { urls in
                        p.cover = nil
                        guard !urls.isEmpty else { return }
                        Task { @MainActor in
                            await store.importURLs(urls, parent: parent)
                        }
                    }
                    .ignoresSafeArea()
                case .scanner(let parent):
                    DocumentScanner { imgs in
                        p.cover = nil
                        guard !imgs.isEmpty else { return }
                        let data = PDFTools.pdfData(from: imgs)
                        let f = DateFormatter()
                        f.dateFormat = "yyyy-MM-dd HH.mm"
                        let name = "مسح " + f.string(from: Date()) + ".pdf"
                        Task { await store.importData(data, name: name, parent: parent) }
                    }
                    .ignoresSafeArea()
                }
            }
            .sheet(item: $p.sheet) { s in
                switch s {
                case .note(let spec):
                    NoteEditor(spec: spec)
                case .tags(let it):
                    TagsSheet(item: it)
                case .share(let b):
                    ShareSheet(urls: b.urls)
                case .move(let m):
                    MoveSheet(spec: m)
                case .assistant(let parent):
                    AssistantView(parent: parent)
                        .environmentObject(store)
                }
            }
    }
}

extension View {
    func presentations(_ p: Presenter) -> some View {
        modifier(Presentations(p: p))
    }

    func folderDestinations() -> some View {
        navigationDestination(for: UUID.self) { id in
            FolderView(parent: id)
        }
    }
}

// MARK: - Root

struct VaultRoot: View {
    @EnvironmentObject var store: VaultStore
    @EnvironmentObject var app: AppState
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                FolderView(parent: nil)
                    .folderDestinations()
            }
            .environment(\.tabBG, "BG1")
            .tabItem { Label("الملفات", systemImage: "folder.fill") }
            .tag(0)

            NavigationStack {
                MediaTab()
            }
            .environment(\.tabBG, "BG2")
            .tabItem { Label("الوسائط", systemImage: "photo.stack.fill") }
            .tag(1)

            NavigationStack {
                FavoritesTab()
                    .folderDestinations()
            }
            .environment(\.tabBG, "BG3")
            .tabItem { Label("المفضلة", systemImage: "star.fill") }
            .tag(2)

            NavigationStack {
                NotesTab()
            }
            .environment(\.tabBG, "BG4")
            .tabItem { Label("الملاحظات", systemImage: "note.text") }
            .tag(3)

            NavigationStack {
                SettingsTab()
            }
            .environment(\.tabBG, "BG5")
            .tabItem { Label("الإعدادات", systemImage: "gearshape.fill") }
            .tag(4)
        }
        .tint(Theme.accent)
        .environment(\.layoutDirection, .rightToLeft)
        .overlay {
            if store.busy { BusyOverlay(text: store.busyText) }
        }
        .onChange(of: store.noticeText) { t in
            if let t { app.toast = t; store.noticeText = nil }
        }
        .alert("تعذّر فك التشفير", isPresented: Binding(get: { store.loadFailed }, set: { _ in })) {
            Button("حسناً", role: .cancel) {}
        } message: {
            Text("مفتاح التشفير غير موجود على هذا الجهاز. لن يتم تعديل أو حذف أي بيانات.")
        }
    }
}

// MARK: - Folder view

struct FolderView: View {
    let parent: UUID?

    @EnvironmentObject var store: VaultStore
    @StateObject private var p = Presenter()

    @State private var selecting = false
    @State private var selection = Set<UUID>()
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: VaultItem?
    @State private var renameText = ""
    @State private var query = ""
    @State private var archiveTarget: VaultItem?
    @AppStorage("calc.sort") private var sortRaw: String = SortMode.name.rawValue

    private var sort: SortMode { SortMode(rawValue: sortRaw) ?? .name }

    private let cols = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    private var title: String {
        if let pid = parent, let it = store.item(pid) { return it.name }
        return "الملفات"
    }

    var body: some View {
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let list = searching ? store.search(query, in: parent, sort: sort) : store.children(of: parent, sort: sort)
        let folders = list.filter { $0.isFolder }
        let files = list.filter { !$0.isFolder }

        ScrollView {
            if list.isEmpty {
                EmptyState(
                    icon: searching ? "magnifyingglass" : "tray.fill",
                    text: searching ? "ما فيه نتائج" : "فاضي — اضغط + للإضافة"
                )
            }
            if !folders.isEmpty {
                SectionTitle(title: "المجلدات", count: folders.count)
                LazyVGrid(columns: cols, spacing: 14) {
                    ForEach(folders) { item in
                        cell(item, list: list)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
            if !files.isEmpty {
                SectionTitle(title: "الملفات", count: files.count)
                LazyVGrid(columns: cols, spacing: 14) {
                    ForEach(files) { item in
                        cell(item, list: list)
                    }
                }
                .padding(.horizontal, 14)
            }
            Color.clear.frame(height: 90)
        }
        .background(AppBackground())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(parent == nil ? .large : .inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: parent == nil ? "بحث في كل الخزنة" : "بحث في هذا المجلد")
        .toolbar { toolbarContent }
        .overlay(alignment: .bottomLeading) {
            if !selecting { fab }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting { selectionBar }
        }
        .background(
            Color.clear
                .photosPicker(isPresented: $showPhotos, selection: $pickerItems, maxSelectionCount: 100,
                              matching: .any(of: [.images, .videos]), photoLibrary: .shared())
        )
        .onChange(of: pickerItems) { picks in importPicked(picks) }
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
        .alert("فك الضغط", isPresented: Binding(get: { archiveTarget != nil }, set: { if !$0 { archiveTarget = nil } })) {
            Button("فك الضغط هنا") {
                if let t = archiveTarget {
                    Task { @MainActor in store.noticeText = await store.extractArchive(t) }
                }
                archiveTarget = nil
            }
            Button("إلغاء", role: .cancel) { archiveTarget = nil }
        } message: {
            Text("سيُنشأ مجلد جديد بمحتوى «\(archiveTarget?.name ?? "")». أبقِ التطبيق مفتوحاً حتى ينتهي.")
        }
        .presentations(p)
    }

    // MARK: toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if parent == nil { LockButton() }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 14) {
                if store.mode == .real {
                    Button { p.sheet = .assistant(parent) } label: { Image(systemName: "sparkles") }
                }
                if let label = store.undoLabel {
                    Button {
                        if let l = store.undo() { store.noticeText = "تم التراجع عن: \(l)" }
                    } label: { Image(systemName: "arrow.uturn.backward.circle") }
                    .accessibilityLabel("تراجع عن \(label)")
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
                if selecting {
                    Button("الكل") {
                        let all = store.children(of: parent, sort: sort).map { $0.id }
                        selection = Set(all)
                    }
                }
                Button(selecting ? "إلغاء" : "تحديد") {
                    selecting.toggle()
                    selection.removeAll()
                }
            }
        }
    }

    private var fab: some View {
        Menu {
            Button { showNewFolder = true } label: { Label("مجلد جديد", systemImage: "folder.badge.plus") }
            Button { p.sheet = .note(NoteSpec(item: nil, parent: parent)) } label: { Label("ملاحظة جديدة", systemImage: "note.text.badge.plus") }
            Button { showPhotos = true } label: { Label("من الصور", systemImage: "photo.on.rectangle") }
            Button { p.cover = .files(parent) } label: { Label("ملفات من تطبيق الملفات", systemImage: "doc.badge.plus") }
            Button { p.cover = .folder(parent) } label: { Label("مجلد كامل من الملفات", systemImage: "folder.badge.gearshape") }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { p.cover = .camera(parent) } label: { Label("تصوير", systemImage: "camera") }
            }
            if DocumentScanner.isSupported {
                Button { p.cover = .scanner(parent) } label: { Label("مسح مستند (PDF)", systemImage: "doc.viewfinder") }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 60, height: 60)
                .background(Theme.gradient, in: Circle())
                .shadow(color: Theme.accent.opacity(0.45), radius: 12, x: 0, y: 6)
        }
        .padding(20)
    }

    private var selectionBar: some View {
        HStack(spacing: 22) {
            barButton("square.and.arrow.up") { p.share(selectedItems(), store: store) }
            barButton("doc.on.doc") {
                p.sheet = .move(MoveSpec(ids: selection, copy: true, onDone: { exitSelect() }))
            }
            barButton("archivebox") {
                let ids = selection
                exitSelect()
                Task { @MainActor in store.noticeText = await store.makeZip(ids) }
            }
            barButton("star") {
                for id in selection { store.setFav(id, true) }
                exitSelect()
            }
            barButton("folder") {
                p.sheet = .move(MoveSpec(ids: selection, onDone: { exitSelect() }))
            }
            barButton("trash", destructive: true) {
                store.trash(selection)
                exitSelect()
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 6)
        .opacity(selection.isEmpty ? 0.5 : 1)
        .disabled(selection.isEmpty)
    }

    private func barButton(_ icon: String, destructive: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(destructive ? .red : Theme.accent)
        }
    }

    // MARK: cells

    @ViewBuilder
    private func cell(_ item: VaultItem, list: [VaultItem]) -> some View {
        let sel = selection.contains(item.id)
        if selecting {
            ItemTile(item: item, selected: sel, count: store.folderCount(item.id))
                .onTapGesture {
                    if sel { selection.remove(item.id) } else { selection.insert(item.id) }
                }
        } else if item.isFolder {
            NavigationLink(value: item.id) {
                ItemTile(item: item, selected: false, count: store.folderCount(item.id))
            }
            .buttonStyle(.plain)
            .contextMenu { menu(for: item) }
            .draggable(DragPayload(ids: [item.id]))
            .dropDestination(for: DragPayload.self) { drops, _ in
                let ids = Set(drops.flatMap { $0.ids }).subtracting([item.id])
                guard !ids.isEmpty else { return false }
                store.move(ids, to: item.id)
                store.noticeText = "تم النقل إلى «\(item.name)»"
                return true
            }
        } else {
            ItemTile(item: item, selected: false, count: 0)
                .onTapGesture {
                    if store.isArchive(item) { archiveTarget = item }
                    else { p.open(item, in: list, store: store) }
                }
                .contextMenu { menu(for: item) }
                .draggable(DragPayload(ids: [item.id]))
        }
    }

    @ViewBuilder
    private func menu(for item: VaultItem) -> some View {
        Button {
            renameText = item.name
            renameTarget = item
        } label: { Label("إعادة تسمية", systemImage: "pencil") }

        Button { store.toggleFav(item.id) } label: {
            Label(item.isFavorite ? "إزالة من المفضلة" : "إضافة للمفضلة",
                  systemImage: item.isFavorite ? "star.slash" : "star")
        }

        Button { p.sheet = .tags(item) } label: { Label("وسوم", systemImage: "tag") }

        Button {
            p.sheet = .move(MoveSpec(ids: [item.id], onDone: {}))
        } label: { Label("نقل", systemImage: "folder") }

        Button {
            p.sheet = .move(MoveSpec(ids: [item.id], copy: true, onDone: {}))
        } label: { Label("نسخ إلى…", systemImage: "doc.on.doc") }

        Button {
            let id = item.id
            Task { @MainActor in
                let n = await store.duplicate([id], to: item.parent)
                store.noticeText = "تم تكرار \(n) عنصر"
            }
        } label: { Label("تكرار", systemImage: "plus.square.on.square") }

        if store.isArchive(item) {
            Button { archiveTarget = item } label: { Label("فك الضغط", systemImage: "arrow.down.doc") }
        }

        if !item.isNote {
            Button {
                let id = item.id
                Task { @MainActor in store.noticeText = await store.makeZip([id]) }
            } label: { Label("ضغط ZIP", systemImage: "archivebox") }
        }

        if !item.isFolder && !item.isNote {
            Button { p.share([item], store: store) } label: {
                Label("مشاركة / حفظ خارجي", systemImage: "square.and.arrow.up")
            }
        }

        Button(role: .destructive) {
            store.trash([item.id])
        } label: { Label("حذف", systemImage: "trash") }
    }

    // MARK: actions

    private func selectedItems() -> [VaultItem] {
        selection.compactMap { store.item($0) }
    }

    private func exitSelect() {
        selection.removeAll()
        selecting = false
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
            for pick in picks {
                if let f = try? await pick.loadTransferable(type: PickedFile.self) {
                    urls.append(f.url)
                    if let id = pick.itemIdentifier { idFor[f.url] = id }
                }
            }
            let ok = await store.importURLs(urls, parent: target)
            for u in urls { try? FileManager.default.removeItem(at: u.deletingLastPathComponent()) }
            if wipe {
                await PhotoCleaner.delete(ok.compactMap { idFor[$0] })
            }
        }
    }
}

// MARK: - Tiles

struct ThumbView: View {
    let item: VaultItem
    @EnvironmentObject var store: VaultStore
    @State private var img: UIImage?

    var body: some View {
        ZStack {
            if let img {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.05)
                Image(systemName: Kind.icon(for: item))
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.gradient)
            }
            if item.isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.title)
                    .foregroundColor(.white.opacity(0.92))
                    .shadow(radius: 3)
            }
        }
        .task(id: item.id) {
            if img == nil && item.isMedia {
                img = await store.loadThumb(item.id)
            }
        }
    }
}

struct ItemTile: View {
    let item: VaultItem
    let selected: Bool
    let count: Int

    private var subtitle: String {
        if item.isFolder { return "\(count) عنصر" }
        return ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 8) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { preview }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(selected ? Theme.accent : Theme.stroke, lineWidth: selected ? 3 : 1)
                )
                .overlay(alignment: .topLeading) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, Theme.accent)
                            .padding(7)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundColor(.yellow)
                            .padding(7)
                            .shadow(radius: 2)
                    }
                }

            VStack(spacing: 2) {
                Text(item.name)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var preview: some View {
        if item.isFolder {
            ZStack {
                LinearGradient(colors: [Theme.folderTop.opacity(0.22), Theme.folderBottom.opacity(0.10)],
                               startPoint: .top, endPoint: .bottom)
                Image(systemName: "folder.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(Theme.folderGradient)
                    .shadow(color: Theme.folderBottom.opacity(0.4), radius: 8, y: 4)
            }
        } else {
            ThumbView(item: item)
                .clipped()
        }
    }
}

// MARK: - Media viewer (صور + فيديو)

struct MediaViewer: View {
    let spec: ViewerSpec
    @State private var index: Int
    @State private var shareBox: ShareBox?
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss

    init(spec: ViewerSpec) {
        self.spec = spec
        _index = State(initialValue: spec.start)
    }

    private var current: VaultItem {
        spec.items[min(max(index, 0), spec.items.count - 1)]
    }

    private var isFav: Bool {
        store.item(current.id)?.isFavorite ?? false
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(spec.items.enumerated()), id: \.offset) { pair in
                    Group {
                        if pair.element.isVideo {
                            VideoPage(item: pair.element, active: pair.offset == index)
                        } else {
                            ZoomableImage(item: pair.element)
                        }
                    }
                    .tag(pair.offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.white.opacity(0.25))
                    }
                    Spacer()
                    Text("\(index + 1) / \(spec.items.count)")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                HStack(spacing: 40) {
                    Button { store.toggleFav(current.id) } label: {
                        Image(systemName: isFav ? "star.fill" : "star")
                            .foregroundColor(isFav ? .yellow : .white)
                    }
                    Button {
                        Task {
                            if let u = try? await store.exportURL(for: current) {
                                shareBox = ShareBox(urls: [u])
                            }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up").foregroundColor(.white)
                    }
                    Button {
                        store.trash([current.id])
                        dismiss()
                    } label: {
                        Image(systemName: "trash").foregroundColor(.red)
                    }
                }
                .font(.system(size: 22, weight: .semibold))
                .padding(.horizontal, 30)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 18)
            }
        }
        .sheet(item: $shareBox) { b in
            ShareSheet(urls: b.urls)
        }
    }
}

struct VideoPage: View {
    let item: VaultItem
    let active: Bool
    @EnvironmentObject var store: VaultStore
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: active) {
            if active {
                if player == nil, let url = try? await store.exportURL(for: item) {
                    player = AVPlayer(url: url)
                }
            } else {
                player?.pause()
            }
        }
        .onDisappear { player?.pause() }
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
    let spec: MoveSpec
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button { go(nil) } label: { Label("الرئيسية", systemImage: "house.fill") }
                ForEach(store.folderChoices(excluding: spec.ids)) { c in
                    Button { go(c.item.id) } label: { Label(c.path, systemImage: "folder.fill") }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle(spec.copy ? "نسخ إلى" : "نقل إلى")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("إلغاء") { dismiss() }
                }
            }
        }
    }

    private func go(_ target: UUID?) {
        if spec.copy {
            let ids = spec.ids
            Task { @MainActor in
                let n = await store.duplicate(ids, to: target)
                store.noticeText = "تم نسخ \(n) عنصر"
            }
        } else {
            store.move(spec.ids, to: target)
        }
        spec.onDone()
        dismiss()
    }
}
