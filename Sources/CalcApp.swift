import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var vault: VaultStore?

    func unlock() {
        if vault == nil { vault = VaultStore() }
    }

    func lock() {
        vault?.cleanTemp()
        vault = nil
    }
}

@main
struct CalcApp: App {
    @StateObject private var app = AppState()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ZStack {
                if let vault = app.vault {
                    VaultRoot()
                        .environmentObject(vault)
                        .environmentObject(app)
                } else {
                    CalculatorView()
                        .environmentObject(app)
                }
                // غطاء أسود عند الانتقال بين التطبيقات (يخفي المحتوى في معاينة التطبيقات)
                if phase != .active {
                    Color.black.ignoresSafeArea()
                }
            }
            .preferredColorScheme(.dark)
            .onChange(of: phase) { newPhase in
                if newPhase == .background { app.lock() }
            }
        }
    }
}
