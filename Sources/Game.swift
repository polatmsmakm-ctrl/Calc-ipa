import SwiftUI

// MARK: - Palette

private enum G {
    static let skyTop = Color(red: 0.27, green: 0.58, blue: 1.0)
    static let skyBottom = Color(red: 0.74, green: 0.90, blue: 1.0)
    static let hill1 = Color(red: 0.36, green: 0.80, blue: 0.42)
    static let hill2 = Color(red: 0.24, green: 0.66, blue: 0.36)
    static let purple = Color(red: 0.56, green: 0.36, blue: 0.96)
    static let purpleLight = Color(red: 0.80, green: 0.64, blue: 1.0)
    static let outline = Color(red: 0.24, green: 0.12, blue: 0.46)
    static let gold = Color(red: 1.0, green: 0.82, blue: 0.20)
    static let orange = Color(red: 1.0, green: 0.52, blue: 0.14)
}

// MARK: - Scenery

private struct Cloud: View {
    var w: CGFloat
    var body: some View {
        ZStack {
            Capsule().fill(Color.white).frame(width: w, height: w * 0.32)
            Circle().fill(Color.white).frame(width: w * 0.42).offset(x: -w * 0.14, y: -w * 0.14)
            Circle().fill(Color.white).frame(width: w * 0.52).offset(x: w * 0.1, y: -w * 0.2)
        }
        .opacity(0.92)
    }
}

private struct HillShape: Shape {
    var peak: CGFloat
    var phase: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.maxY))
        p.addLine(to: CGPoint(x: 0, y: rect.height * peak))
        p.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.height * (peak + phase)),
            control1: CGPoint(x: rect.width * 0.30, y: rect.height * (peak - 0.22)),
            control2: CGPoint(x: rect.width * 0.70, y: rect.height * (peak + 0.22))
        )
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

private struct SkyBackground: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [G.skyTop, G.skyBottom], startPoint: .top, endPoint: .bottom)
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 1, green: 0.97, blue: 0.7), Color(red: 1, green: 0.9, blue: 0.4).opacity(0)],
                                         center: .center, startRadius: 10, endRadius: 120))
                    .frame(width: 240, height: 240)
                    .position(x: geo.size.width * 0.82, y: geo.size.height * 0.14)
                Cloud(w: 150).position(x: geo.size.width * 0.2, y: geo.size.height * 0.16)
                Cloud(w: 110).position(x: geo.size.width * 0.72, y: geo.size.height * 0.3)
                Cloud(w: 90).position(x: geo.size.width * 0.12, y: geo.size.height * 0.42)
                HillShape(peak: 0.80, phase: -0.05)
                    .fill(G.hill2)
                    .frame(height: geo.size.height * 0.4)
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.82)
                HillShape(peak: 0.88, phase: 0.04)
                    .fill(G.hill1)
                    .frame(height: geo.size.height * 0.3)
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.88)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Character (original)

struct PuffView: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            // feet
            HStack(spacing: size * 0.30) {
                Capsule().fill(G.orange).frame(width: size * 0.26, height: size * 0.14)
                Capsule().fill(G.orange).frame(width: size * 0.26, height: size * 0.14)
            }
            .offset(y: size * 0.47)

            // ears
            Circle().fill(G.purple).frame(width: size * 0.26)
                .overlay(Circle().stroke(G.outline, lineWidth: size * 0.03))
                .offset(x: -size * 0.30, y: -size * 0.42)
            Circle().fill(G.purple).frame(width: size * 0.26)
                .overlay(Circle().stroke(G.outline, lineWidth: size * 0.03))
                .offset(x: size * 0.30, y: -size * 0.42)

            // body
            Circle()
                .fill(RadialGradient(colors: [G.purpleLight, G.purple],
                                     center: UnitPoint(x: 0.35, y: 0.28), startRadius: 0, endRadius: size * 0.75))
                .overlay(Circle().stroke(G.outline, lineWidth: size * 0.04))

            // eyes
            HStack(spacing: size * 0.10) {
                eye
                eye
            }
            .offset(y: -size * 0.06)

            // cheeks
            HStack(spacing: size * 0.40) {
                Ellipse().fill(Color.pink.opacity(0.55)).frame(width: size * 0.14, height: size * 0.09)
                Ellipse().fill(Color.pink.opacity(0.55)).frame(width: size * 0.14, height: size * 0.09)
            }
            .offset(y: size * 0.12)

            // smile
            SmileShape()
                .stroke(G.outline, style: StrokeStyle(lineWidth: size * 0.035, lineCap: .round))
                .frame(width: size * 0.22, height: size * 0.10)
                .offset(y: size * 0.17)
        }
        .frame(width: size, height: size)
    }

    private var eye: some View {
        ZStack {
            Circle().fill(Color.white)
                .overlay(Circle().stroke(G.outline, lineWidth: size * 0.02))
            Circle().fill(G.outline).frame(width: size * 0.10)
                .offset(x: size * 0.015, y: size * 0.01)
            Circle().fill(Color.white).frame(width: size * 0.035)
                .offset(x: size * 0.03, y: -size * 0.02)
        }
        .frame(width: size * 0.25, height: size * 0.28)
    }
}

private struct SmileShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.midX, y: rect.maxY * 1.8))
        return p
    }
}

// MARK: - Buttons

private struct CandyButtonStyle: ButtonStyle {
    let top: Color
    let bottom: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(G.outline.opacity(0.85), lineWidth: 3)
                    )
                    .shadow(color: G.outline.opacity(0.45), radius: 0, x: 0, y: configuration.isPressed ? 2 : 6)
            )
            .offset(y: configuration.isPressed ? 4 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - Main screen

struct GameView: View {
    @EnvironmentObject var app: AppState

    private enum Screen { case menu, play, snake }

    @State private var screen: Screen = .menu
    @State private var showCode = false
    @State private var bounce = false
    @State private var best = UserDefaults.standard.integer(forKey: "run.best")

    var body: some View {
        ZStack {
            SkyBackground()

            switch screen {
            case .menu:
                menu
            case .snake:
                SnakeGameView {
                    screen = .menu
                }
            case .play:
                DashGameView {
                    best = UserDefaults.standard.integer(forKey: "run.best")
                    screen = .menu
                }
            }

            if showCode {
                CodePad(isOpen: $showCode)
                    .transition(.opacity)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .animation(.easeInOut(duration: 0.2), value: showCode)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { bounce = true }
            // أول تشغيل: لازم ينشئ كود
            if !Passcode.isSet(.real) { showCode = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .deviceShaken)) { _ in
            // الكود مخفي: يظهر بهز الجهاز وأنت في القائمة الرئيسية
            if screen == .menu && !showCode {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                showCode = true
            }
        }
    }

    private var menu: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 30)

            titleView
                .onLongPressGesture(minimumDuration: 0.9) { bioUnlock() }

            Spacer(minLength: 10)

            PuffView(size: 170)
                .offset(y: bounce ? -14 : 8)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 10)

            Spacer(minLength: 24)

            Button { screen = .play } label: {
                HStack(spacing: 10) {
                    Image(systemName: "figure.run")
                    Text("ZOMBIE RUN")
                }
                .font(.system(size: 26, weight: .black, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 260, height: 62)
            }
            .buttonStyle(CandyButtonStyle(top: Color(red: 0.45, green: 0.90, blue: 0.40),
                                          bottom: Color(red: 0.16, green: 0.68, blue: 0.28)))

            Button { screen = .snake } label: {
                HStack(spacing: 10) {
                    Image(systemName: "scribble.variable")
                    Text("SNAKE")
                }
                .font(.system(size: 26, weight: .black, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 260, height: 62)
            }
            .buttonStyle(CandyButtonStyle(top: Color(red: 0.55, green: 0.65, blue: 1.0),
                                          bottom: Color(red: 0.34, green: 0.40, blue: 0.92)))
            .padding(.top, 10)
            .padding(.bottom, 4)

            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "trophy.fill").foregroundColor(G.gold)
                    Text("\(best)")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                }
                .frame(width: 100, height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.black.opacity(0.25))
                )
            }
            .padding(.top, 22)

            Spacer(minLength: 70)
        }
    }

    private var titleView: some View {
        VStack(spacing: -8) {
            outlinedText("PUFF", size: 66)
            outlinedText("DASH", size: 66)
            Text("ZOMBIE RUN")
                .font(.system(size: 17, weight: .black, design: .rounded))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color(red: 0.75, green: 0.18, blue: 0.22)))
                .overlay(Capsule().stroke(G.outline, lineWidth: 2.5))
                .padding(.top, 14)
        }
    }

    private func outlinedText(_ s: String, size: CGFloat) -> some View {
        ZStack {
            ForEach(Array([(-3, 0), (3, 0), (0, -3), (0, 3), (-2, -2), (2, 2), (-2, 2), (2, -2)].enumerated()), id: \.offset) { pair in
                Text(s).foregroundColor(G.outline)
                    .offset(x: CGFloat(pair.element.0), y: CGFloat(pair.element.1))
            }
            Text(s).foregroundStyle(
                LinearGradient(colors: [Color(red: 1, green: 0.95, blue: 0.45), G.orange], startPoint: .top, endPoint: .bottom)
            )
        }
        .font(.system(size: size, weight: .black, design: .rounded))
        .shadow(color: G.outline.opacity(0.4), radius: 0, x: 0, y: 5)
    }

    private func bioUnlock() {
        guard Bio.enabled, Passcode.isSet(.real) else { return }
        Bio.authenticate { ok in
            if ok { app.unlock(.real) }
        }
    }
}

// MARK: - Code pad (كلمة السر)

struct CodePad: View {
    @EnvironmentObject var app: AppState
    @Binding var isOpen: Bool

    @State private var code = ""
    @State private var msg = ""
    @State private var shake: CGFloat = 0

    private var firstRun: Bool { !Passcode.isSet(.real) }

    private let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["⌫", "0", "OK"]]

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { isOpen = false }

            VStack(spacing: 16) {
                HStack {
                    Text(firstRun ? "CREATE CODE" : "ENTER CODE")
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                    Spacer()
                    Button { isOpen = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white.opacity(0.85))
                    }
                }

                // display
                HStack(spacing: 8) {
                    if code.isEmpty {
                        Text("• • • •").foregroundColor(.white.opacity(0.35))
                    } else {
                        Text(String(repeating: "★ ", count: code.count)).foregroundColor(G.gold)
                    }
                }
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.35)))
                .offset(x: shake)

                if firstRun {
                    Text("اختر رمزك السري (٤ إلى ١٢ رقم) ثم اضغط OK")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.85))
                } else if !msg.isEmpty {
                    Text(msg)
                        .font(.footnote.weight(.bold))
                        .foregroundColor(Color(red: 1, green: 0.6, blue: 0.5))
                }

                VStack(spacing: 10) {
                    ForEach(rows, id: \.self) { row in
                        HStack(spacing: 10) {
                            ForEach(row, id: \.self) { key in
                                keyButton(key)
                            }
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: 330)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.30, blue: 0.80), Color(red: 0.26, green: 0.16, blue: 0.56)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(G.outline, lineWidth: 4))
            )
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private func keyButton(_ key: String) -> some View {
        let isOK = key == "OK"
        let isDel = key == "⌫"
        Button {
            press(key)
        } label: {
            Group {
                if isDel {
                    Image(systemName: "delete.left.fill")
                } else {
                    Text(key)
                }
            }
            .font(.system(size: isOK ? 22 : 28, weight: .black, design: .rounded))
            .foregroundColor(.white)
            .frame(width: 88, height: 56)
        }
        .buttonStyle(
            isOK ? CandyButtonStyle(top: Color(red: 0.45, green: 0.90, blue: 0.40), bottom: Color(red: 0.16, green: 0.68, blue: 0.28))
            : isDel ? CandyButtonStyle(top: Color(red: 1.0, green: 0.55, blue: 0.45), bottom: Color(red: 0.85, green: 0.28, blue: 0.28))
            : CandyButtonStyle(top: Color(red: 0.62, green: 0.74, blue: 1.0), bottom: Color(red: 0.34, green: 0.46, blue: 0.92))
        )
        // long press على OK لا حاجة له: الإعداد الأولي صار بشاشة CREATE CODE
    }

    private func press(_ key: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch key {
        case "⌫":
            if !code.isEmpty { code.removeLast() }
            msg = ""
        case "OK":
            submit()
        default:
            if code.count < 12 { code += key }
            msg = ""
        }
    }

    private func wrong(_ text: String) {
        msg = text
        code = ""
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        withAnimation(.linear(duration: 0.06).repeatCount(5, autoreverses: true)) { shake = 10 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { shake = 0 }
    }

    private func submit() {
        if firstRun {
            guard code.count >= 4 else { wrong("٤ أرقام على الأقل"); return }
            Passcode.set(code, kind: .real)
            code = ""
            isOpen = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            app.unlock(.real)
            return
        }

        if Attempts.isLocked {
            wrong("Try again later")
            return
        }
        if let kind = Passcode.match(code) {
            Attempts.reset()
            code = ""
            isOpen = false
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            switch kind {
            case .real:
                app.unlock(.real)
            case .decoy:
                app.unlock(.decoy)
            case .panic:
                VaultStore.wipeReal()
                app.unlock(.decoy)
            }
        } else {
            if code.count >= 4 { Attempts.recordFail() }
            wrong("Wrong code!")
        }
    }
}


// MARK: - Shake detection

extension Notification.Name {
    static let deviceShaken = Notification.Name("deviceShaken")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceShaken, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}
