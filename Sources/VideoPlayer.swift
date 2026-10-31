import SwiftUI
import AVFoundation
import AVKit
import CryptoKit

// MARK: - بث الفيديو المشفّر مباشرة (بدون فك تشفير الملف كاملاً)

final class VaultAssetLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let url: URL
    private let key: SymmetricKey
    private let total: Int64
    private let contentType: String
    private let frame = Int64(Crypto.chunkSize + 32)
    private var cache: [Int: Data] = [:]
    private var order: [Int] = []
    let queue = DispatchQueue(label: "vault.loader")

    init(file: URL, key: SymmetricKey, size: Int64, ext: String) {
        url = file
        self.key = key
        total = size
        switch ext.lowercased() {
        case "mov": contentType = "com.apple.quicktime-movie"
        case "m4v": contentType = "com.apple.m4v-video"
        default: contentType = "public.mpeg-4"
        }
    }

    private func chunk(_ i: Int, _ fh: FileHandle) throws -> Data {
        if let c = cache[i] { return c }
        try fh.seek(toOffset: UInt64(Int64(i) * frame))
        guard let plain = try Crypto.readFrame(from: fh, key: key, maxLen: Crypto.chunkSize + 64) else { throw CryptoError.corrupt }
        cache[i] = plain
        order.append(i)
        if order.count > 12 { cache[order.removeFirst()] = nil }
        return plain
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource req: AVAssetResourceLoadingRequest) -> Bool {
        queue.async { [self] in
            if let info = req.contentInformationRequest {
                info.contentType = contentType
                info.contentLength = total
                info.isByteRangeAccessSupported = true
            }
            guard let dr = req.dataRequest else { req.finishLoading(); return }
            do {
                let fh = try FileHandle(forReadingFrom: url)
                defer { try? fh.close() }
                var pos = dr.requestedOffset
                let end = dr.requestsAllDataToEndOfResource ? total : min(total, dr.requestedOffset + Int64(dr.requestedLength))
                while pos < end {
                    if req.isCancelled { return }
                    let idx = Int(pos / Int64(Crypto.chunkSize))
                    let data = try chunk(idx, fh)
                    let within = Int(pos - Int64(idx) * Int64(Crypto.chunkSize))
                    guard within < data.count else { break }
                    let take = min(data.count - within, Int(end - pos))
                    dr.respond(with: data.subdata(in: within..<(within + take)))
                    pos += Int64(take)
                }
                req.finishLoading()
            } catch {
                req.finishLoading(with: error)
            }
        }
        return true
    }
}

// MARK: - Player model

@MainActor
final class PlayerModel: ObservableObject {
    let player = AVPlayer()
    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var playing = false
    @Published var buffering = true
    @Published var failed = false
    @Published var ended = false
    @Published var speed: Float = 1

    var scrubbing = false
    private var loader: VaultAssetLoader?
    private var timeObs: Any?
    private var obs: [NSKeyValueObservation] = []
    private var endObs: NSObjectProtocol?
    private var item: VaultItem?
    private var triedFallback = false
    private var resumeAt: Double = 0
    private var lastSave: Double = 0

    func load(_ it: VaultItem, store: VaultStore) {
        item = it
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        resumeAt = UserDefaults.standard.double(forKey: "vpos." + it.id.uuidString)

        let ld = VaultAssetLoader(file: store.fileURL(it.id), key: store.key, size: it.size, ext: it.ext)
        loader = ld
        let asset = AVURLAsset(url: URL(string: "vault://\(it.id.uuidString).\(it.ext)")!)
        asset.resourceLoader.setDelegate(ld, queue: ld.queue)
        start(AVPlayerItem(asset: asset))
        observe()
    }

    private func start(_ pi: AVPlayerItem) {
        player.replaceCurrentItem(with: pi)
        obs.removeAll()
        obs.append(pi.observe(\.status, options: [.new]) { [weak self] i, _ in
            Task { @MainActor in self?.statusChanged(i) }
        })
        obs.append(pi.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] i, _ in
            Task { @MainActor in self?.buffering = !i.isPlaybackLikelyToKeepUp && self?.playing == true }
        })
        obs.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            Task { @MainActor in
                guard let self else { return }
                self.playing = p.timeControlStatus != .paused
                self.buffering = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        })
        if let e = endObs { NotificationCenter.default.removeObserver(e) }
        endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: pi, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.ended = true
                self?.playing = false
                if let id = self?.item?.id { UserDefaults.standard.removeObject(forKey: "vpos." + id.uuidString) }
            }
        }
    }

    private func statusChanged(_ i: AVPlayerItem) {
        switch i.status {
        case .readyToPlay:
            duration = max(0, i.duration.seconds.isFinite ? i.duration.seconds : 0)
            buffering = false
            if resumeAt > 5, duration > 0, resumeAt < duration - 8 {
                player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600))
                resumeAt = 0
            }
            player.playImmediately(atRate: speed)
        case .failed:
            fallback()
        default: break
        }
    }

    /// لو فشل البث المباشر نفك التشفير كاملاً (الطريقة القديمة).
    private func fallback() {
        guard !triedFallback, let it = item, let store = storeRef else { failed = true; return }
        triedFallback = true
        buffering = true
        Task {
            if let u = try? await store.exportURL(for: it) {
                start(AVPlayerItem(url: u))
            } else {
                failed = true
            }
        }
    }

    weak var storeRef: VaultStore?

    private func observe() {
        timeObs = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] t in
            Task { @MainActor in
                guard let self, !self.scrubbing else { return }
                self.time = t.seconds.isFinite ? t.seconds : 0
                if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
                if self.time - self.lastSave > 5 { self.lastSave = self.time; self.savePosition() }
            }
        }
    }

    func savePosition() {
        guard let it = item, duration > 0 else { return }
        let key = "vpos." + it.id.uuidString
        if time > 5 && time < duration - 8 { UserDefaults.standard.set(time, forKey: key) }
    }

    func toggle() {
        if ended {
            ended = false
            player.seek(to: .zero)
            player.playImmediately(atRate: speed)
        } else if playing {
            player.pause()
        } else {
            player.playImmediately(atRate: speed)
        }
    }

    func seek(to t: Double, exact: Bool = false) {
        let target = max(0, min(t, duration))
        time = target
        ended = false
        let tol: CMTime = exact ? .zero : CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol)
    }

    func skip(_ d: Double) { seek(to: time + d, exact: true) }

    func setSpeed(_ s: Float) {
        speed = s
        if playing { player.rate = s }
    }

    func shutdown() {
        savePosition()
        player.pause()
        if let t = timeObs { player.removeTimeObserver(t); timeObs = nil }
        if let e = endObs { NotificationCenter.default.removeObserver(e); endObs = nil }
        obs.removeAll()
        player.replaceCurrentItem(with: nil)
        UIApplication.shared.isIdleTimerDisabled = false
    }
}

// MARK: - Layer

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let fill: Bool

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ v: PlayerUIView, context: Context) {
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}

// MARK: - Screen

struct VideoPlayerScreen: View {
    let item: VaultItem
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var m = PlayerModel()

    @State private var controls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var fill = false
    @State private var dragY: CGFloat = 0
    @State private var axis: Int = 0          // 0 غير محدد، 1 أفقي، 2 عمودي
    @State private var seekStart: Double = 0
    @State private var seekPreview: Double?
    @State private var flash: String?
    @State private var flashSide: Int = 0
    @State private var boosting = false
    @State private var shareBox: ShareBox?
    @State private var landscape = false
    @State private var scrubWidth: CGFloat = 1
    @State private var scrubbing = false

    private var progress: CGFloat { min(1, max(0, dragY / 420)) }
    private var isFav: Bool { store.item(item.id)?.isFavorite ?? false }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(1 - Double(progress) * 0.6).ignoresSafeArea()

                ZStack {
                    PlayerLayerView(player: m.player, fill: fill)
                        .ignoresSafeArea()

                    // مناطق اللمس: ضغطتين يمين/يسار للتقديم والتأخير
                    HStack(spacing: 0) {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture(count: 2) { skip(-10, side: -1) }
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture(count: 2) { skip(10, side: 1) }
                    }
                    .ignoresSafeArea()

                    Color.clear.contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { toggleControls() }
                        .onLongPressGesture(minimumDuration: 0.4, pressing: { down in
                            if down { return }
                            if boosting { boosting = false; m.player.rate = m.playing ? m.speed : 0 }
                        }, perform: {
                            guard m.playing else { return }
                            boosting = true
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            m.player.rate = 2
                        })

                    if m.buffering && !m.failed {
                        ProgressView().tint(.white).scaleEffect(1.4)
                    }
                    if m.failed {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                            Text("تعذر تشغيل هذا الفيديو").font(.callout)
                        }
                        .foregroundColor(.white)
                    }

                    if let f = flash {
                        HStack {
                            if flashSide > 0 { Spacer() }
                            Text(f)
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.horizontal, 18).padding(.vertical, 12)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(.horizontal, 40)
                            if flashSide < 0 { Spacer() }
                        }
                        .transition(.opacity)
                        .allowsHitTesting(false)
                    }
                    if boosting {
                        VStack {
                            Label("2×", systemImage: "forward.fill")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(.top, 70)
                            Spacer()
                        }
                        .allowsHitTesting(false)
                    }
                    if let p = seekPreview {
                        Text(fmt(p) + " / " + fmt(m.duration))
                            .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundColor(.white)
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                            .allowsHitTesting(false)
                    }

                    if controls { overlay(geo: geo).transition(.opacity) }
                }
                .scaleEffect(1 - progress * 0.25)
                .offset(y: dragY)
                .clipShape(RoundedRectangle(cornerRadius: progress > 0.02 ? 28 : 0, style: .continuous))
                .simultaneousGesture(panGesture(width: geo.size.width))
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .statusBarHidden(!controls)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: controls)
        .animation(.easeOut(duration: 0.2), value: flash)
        .onAppear {
            m.storeRef = store
            m.load(item, store: store)
            scheduleHide()
        }
        .onChange(of: m.playing) { p in
            UIApplication.shared.isIdleTimerDisabled = p
            if p { scheduleHide() } else { hideTask?.cancel(); controls = true }
        }
        .onDisappear {
            m.shutdown()
            rotate(landscape: false)
        }
        .sheet(item: $shareBox) { b in ShareSheet(urls: b.urls) }
    }

    // MARK: overlay

    @ViewBuilder
    private func overlay(geo: GeometryProxy) -> some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.65), .clear, .clear, .black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack {
                topBar
                Spacer()
                bottomBar
            }

            HStack(spacing: 46) {
                roundButton("gobackward.10", size: 34) { skip(-10, side: -1) }
                Button { m.toggle(); scheduleHide() } label: {
                    Image(systemName: m.ended ? "arrow.counterclockwise" : (m.playing ? "pause.fill" : "play.fill"))
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 92, height: 92)
                        .background(.ultraThinMaterial, in: Circle())
                }
                roundButton("goforward.10", size: 34) { skip(10, side: 1) }
            }
            .opacity(m.buffering && m.playing ? 0 : 1)
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            Text(item.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer()
            Menu {
                Menu("السرعة") {
                    ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { s in
                        Button {
                            m.setSpeed(s)
                        } label: {
                            Label(s == 1 ? "عادي" : "\(s.formatted())×", systemImage: m.speed == s ? "checkmark" : "")
                        }
                    }
                }
                Button { fill.toggle() } label: {
                    Label(fill ? "ملاءمة الشاشة" : "ملء الشاشة", systemImage: fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                Button { store.toggleFav(item.id) } label: {
                    Label(isFav ? "إزالة من المفضلة" : "إضافة للمفضلة", systemImage: isFav ? "star.slash" : "star")
                }
                Button {
                    Task {
                        if let u = try? await store.exportURL(for: item) { shareBox = ShareBox(urls: [u]) }
                    }
                } label: { Label("مشاركة / حفظ خارجي", systemImage: "square.and.arrow.up") }
                Button(role: .destructive) {
                    store.trash([item.id])
                    dismiss()
                } label: { Label("حذف", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            scrubber
            HStack {
                Text(fmt(seekPreview ?? m.time))
                Spacer()
                Text("-" + fmt(max(0, m.duration - (seekPreview ?? m.time))))
                Button {
                    landscape.toggle()
                    rotate(landscape: landscape)
                } label: {
                    Image(systemName: landscape ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .bold))
                }
                .padding(.leading, 10)
                if m.speed != 1 {
                    Text("\(m.speed.formatted())×")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.22)))
                }
            }
            .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundColor(.white.opacity(0.9))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private var scrubber: some View {
        GeometryReader { g in
            let w = g.size.width
            let frac = m.duration > 0 ? CGFloat((seekPreview ?? m.time) / m.duration) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.28))
                    .frame(height: scrubbing ? 10 : 5)
                Capsule().fill(Color.white)
                    .frame(width: max(0, min(1, frac)) * w, height: scrubbing ? 10 : 5)
                Circle().fill(Color.white)
                    .frame(width: scrubbing ? 22 : 14, height: scrubbing ? 22 : 14)
                    .offset(x: max(0, min(1, frac)) * w - (scrubbing ? 11 : 7))
                    .shadow(radius: 3)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !scrubbing {
                            scrubbing = true
                            m.scrubbing = true
                            hideTask?.cancel()
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                        let f = max(0, min(1, v.location.x / w))
                        seekPreview = Double(f) * m.duration
                        m.seek(to: seekPreview!)
                    }
                    .onEnded { _ in
                        if let p = seekPreview { m.seek(to: p, exact: true) }
                        m.scrubbing = false
                        scrubbing = false
                        seekPreview = nil
                        scheduleHide()
                    }
            )
            .animation(.easeOut(duration: 0.15), value: scrubbing)
        }
        .frame(height: 30)
    }

    private func roundButton(_ icon: String, size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .regular))
                .foregroundColor(.white)
                .frame(width: 64, height: 64)
        }
    }

    // MARK: gestures & helpers

    private func panGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { v in
                if axis == 0 {
                    axis = abs(v.translation.width) > abs(v.translation.height) ? 1 : 2
                    seekStart = m.time
                    if axis == 1 { m.scrubbing = true; hideTask?.cancel() }
                }
                if axis == 1 {
                    // سحب أفقي = تقديم/تأخير: عرض الشاشة كاملاً ≈ دقيقتين
                    let delta = Double(v.translation.width / max(width, 1)) * 120
                    seekPreview = max(0, min(m.duration, seekStart + delta))
                } else if axis == 2, v.translation.height > 0 {
                    dragY = v.translation.height
                }
            }
            .onEnded { v in
                if axis == 1, let p = seekPreview {
                    m.seek(to: p, exact: true)
                    m.scrubbing = false
                    seekPreview = nil
                } else if axis == 2 {
                    if v.translation.height > 140 || v.predictedEndTranslation.height > 380 {
                        withAnimation(.easeIn(duration: 0.18)) { dragY = 700 }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { dismiss() }
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragY = 0 }
                    }
                }
                axis = 0
            }
    }

    private func skip(_ d: Double, side: Int) {
        m.skip(d)
        flashSide = side
        flash = d > 0 ? "+\(Int(d))ث" : "\(Int(d))ث"
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { flash = nil }
        if controls { scheduleHide() }
    }

    private func toggleControls() {
        controls.toggle()
        if controls { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard m.playing else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if !Task.isCancelled && m.playing && !scrubbing { controls = false }
        }
    }

    private func rotate(landscape: Bool) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscape : .portrait)) { _ in }
    }

    private func fmt(_ t: Double) -> String {
        let s = Int(max(0, t))
        let h = s / 3600, mi = (s % 3600) / 60, se = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, mi, se) : String(format: "%d:%02d", mi, se)
    }
}
