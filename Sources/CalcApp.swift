import SwiftUI
import CoreMotion

// MARK: - Motion lock (قلب الجوال / الهز)

final class MotionLocker {
    private let mm = CMMotionManager()
    private var onLock: (() -> Void)?
    private var obs: NSObjectProtocol?

    func start(_ onLock: @escaping () -> Void) {
        stop()
        self.onLock = onLock
        let d = UserDefaults.standard

        if d.bool(forKey: "calc.lockFlip") {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            obs = NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                if UIDevice.current.orientation == .faceDown { self?.onLock?() }
            }
        }

        if d.bool(forKey: "calc.lockShake"), mm.isAccelerometerAvailable {
            mm.accelerometerUpdateInterval = 0.1
            mm.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
                guard let a = data?.acceleration else { return }
                let g = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
                if g > 2.8 { self?.onLock?() }
            }
        }
    }

    func stop() {
        if let o = obs {
            NotificationCenter.default.removeObserver(o)
            obs = nil
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        if mm.isAccelerometerActive { mm.stopAccelerometerUpdates() }
        onLock = nil
    }
}

// MARK: - App state

@MainActor
final class AppState: ObservableObject {
    @Published var vault: VaultStore?
    @Published var captured = false
    @Published var toast: String?

    private let motion = MotionLocker()

    func unlock(_ mode: VaultMode) {
        guard vault == nil else { return }
        let v = VaultStore(mode: mode)
        vault = v
        v.purgeOldTrash()
        motion.start { [weak self] in
            DispatchQueue.main.async { self?.lock() }
        }
    }

    func lock() {
        motion.stop()
        vault?.cleanTemp()
        vault = nil
    }

    /// ملف جاء من تطبيق آخر («نسخ إلى حاسبة»): يُشفَّر فوراً ويُحذف الأصل، ويدخل الخزنة عند الفتح.
    func incoming(_ url: URL) {
        guard url.isFileURL else { return }
        Task.detached(priority: .userInitiated) {
            VaultStore.stageIncoming(url)
            await MainActor.run { self.afterStage() }
        }
    }

    private func afterStage() {
        guard let v = vault, v.mode == .real else { return }
        let n = v.ingestStaged()
        if n > 0 { toast = "تم استيراد \(n) ملف" }
    }
}

// MARK: - App

@main
struct CalcApp: App {
    @StateObject private var app = AppState()
    @Environment(\.scenePhase) private var phase

    init() {
        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        UINavigationBar.appearance().scrollEdgeAppearance = nav
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if let vault = app.vault {
                    VaultRoot()
                        .environmentObject(vault)
                        .environmentObject(app)
                } else {
                    GameView()
                        .environmentObject(app)
                }

                if let t = app.toast {
                    VStack {
                        Text(t)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.top, 8)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
                }

                // غطاء أسود عند الانتقال بين التطبيقات أو أثناء تسجيل الشاشة
                if phase != .active || (app.captured && app.vault != nil) {
                    Color.black.ignoresSafeArea()
                }
            }
            .animation(.easeInOut(duration: 0.25), value: app.toast)
            .preferredColorScheme(.dark)
            .onChange(of: phase) { newPhase in
                if newPhase == .background { app.lock() }
            }
            .onChange(of: app.toast) { t in
                if t != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { app.toast = nil }
                }
            }
            .onOpenURL { url in app.incoming(url) }
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
                app.captured = UIScreen.main.isCaptured
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
                if app.vault != nil { Attempts.recordShot() }
            }
            .onAppear { app.captured = UIScreen.main.isCaptured }
        }
    }
}
