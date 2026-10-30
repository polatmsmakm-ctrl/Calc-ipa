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

    private enum Screen { case menu, play }

    @State private var screen: Screen = .menu
    @State private var showCode = false
    @State private var bounce = false
    @State private var best = UserDefaults.standard.integer(forKey: "dash.best")

    var body: some View {
        ZStack {
            SkyBackground()

            switch screen {
            case .menu:
                menu
            case .play:
                DashGameView {
                    best = UserDefaults.standard.integer(forKey: "dash.best")
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
                    Image(systemName: "play.fill")
                    Text("PLAY")
                }
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 230, height: 70)
            }
            .buttonStyle(CandyButtonStyle(top: Color(red: 0.45, green: 0.90, blue: 0.40),
                                          bottom: Color(red: 0.16, green: 0.68, blue: 0.28)))

            HStack(spacing: 14) {
                Button { showCode = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "key.fill")
                        Text("CODE")
                    }
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .frame(width: 130, height: 54)
                }
                .buttonStyle(CandyButtonStyle(top: Color(red: 1.0, green: 0.74, blue: 0.25), bottom: G.orange))

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

// MARK: - Mini game (Puff Dash)

private final class DashModel {
    var y: CGFloat = 0
    var vy: CGFloat = 0
    var obstacles: [CGFloat] = []
    var spawnIn: CGFloat = 300
    var score: Double = 0
    var over = false
    var started = false
    var last: TimeInterval = 0
    var best = UserDefaults.standard.integer(forKey: "dash.best")

    let charX: CGFloat = 90

    func reset() {
        y = 0; vy = 0; obstacles = []; spawnIn = 300
        score = 0; over = false; started = false; last = 0
    }

    func tap() {
        if over { reset(); return }
        started = true
        if y <= 0.5 { vy = 700 }
    }

    func step(t: TimeInterval, width: CGFloat) {
        if last == 0 { last = t }
        let dt = CGFloat(min(t - last, 0.033))
        last = t
        guard started, !over else { return }

        let speed: CGFloat = 250 + CGFloat(score) * 2.4
        vy -= 2100 * dt
        y += vy * dt
        if y <= 0 { y = 0; vy = 0 }

        for i in obstacles.indices { obstacles[i] -= speed * dt }
        obstacles.removeAll { $0 < -60 }
        spawnIn -= speed * dt
        if spawnIn <= 0 {
            obstacles.append(width + 50)
            spawnIn = CGFloat.random(in: 300...520)
        }
        score += Double(dt) * 10

        for x in obstacles where abs(x - charX) < 26 && y < 30 {
            over = true
            let s = Int(score)
            if s > best {
                best = s
                UserDefaults.standard.set(s, forKey: "dash.best")
            }
        }
    }
}

struct DashGameView: View {
    let onExit: () -> Void
    @State private var model = DashModel()

    var body: some View {
        ZStack(alignment: .topLeading) {
            TimelineView(.animation) { timeline in
                Canvas { ctx, size in
                    model.step(t: timeline.date.timeIntervalSinceReferenceDate, width: size.width)
                    draw(&ctx, size: size)
                }
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { model.tap() }

            Button { onExit() } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.white, Color.black.opacity(0.25))
                    .padding(16)
            }
        }
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let groundY = size.height * 0.78
        let r: CGFloat = 26

        // ground
        ctx.fill(Path(CGRect(x: 0, y: groundY, width: size.width, height: size.height - groundY)),
                 with: .color(G.hill1))
        ctx.fill(Path(CGRect(x: 0, y: groundY, width: size.width, height: 8)), with: .color(G.hill2))

        // obstacles (spikes)
        for x in model.obstacles {
            var p = Path()
            p.move(to: CGPoint(x: x - 20, y: groundY))
            p.addLine(to: CGPoint(x: x, y: groundY - 40))
            p.addLine(to: CGPoint(x: x + 20, y: groundY))
            p.closeSubpath()
            ctx.fill(p, with: .color(Color(red: 0.95, green: 0.35, blue: 0.40)))
            ctx.stroke(p, with: .color(G.outline), lineWidth: 3)
        }

        // character
        let cy = groundY - r - model.y
        let body = CGRect(x: model.charX - r, y: cy - r, width: r * 2, height: r * 2)
        ctx.fill(Path(ellipseIn: body), with: .color(G.purple))
        ctx.stroke(Path(ellipseIn: body), with: .color(G.outline), lineWidth: 3)
        for dx in [-8.0, 8.0] {
            let eye = CGRect(x: model.charX + CGFloat(dx) - 6, y: cy - 10, width: 12, height: 14)
            ctx.fill(Path(ellipseIn: eye), with: .color(.white))
            let pupil = CGRect(x: model.charX + CGFloat(dx) - 2, y: cy - 6, width: 5, height: 6)
            ctx.fill(Path(ellipseIn: pupil), with: .color(G.outline))
        }

        // texts
        ctx.draw(
            Text("SCORE \(Int(model.score))")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundColor(.white),
            at: CGPoint(x: size.width - 80, y: 56)
        )
        ctx.draw(
            Text("BEST \(model.best)")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.85)),
            at: CGPoint(x: size.width - 80, y: 82)
        )

        if !model.started {
            ctx.draw(
                Text("TAP TO JUMP")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundColor(.white),
                at: CGPoint(x: size.width / 2, y: size.height * 0.34)
            )
        }
        if model.over {
            ctx.draw(
                Text("GAME OVER")
                    .font(.system(size: 40, weight: .black, design: .rounded))
                    .foregroundColor(.white),
                at: CGPoint(x: size.width / 2, y: size.height * 0.32)
            )
            ctx.draw(
                Text("tap to retry")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.9)),
                at: CGPoint(x: size.width / 2, y: size.height * 0.32 + 38)
            )
        }
    }
}
