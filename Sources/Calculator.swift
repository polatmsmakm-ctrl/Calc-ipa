import SwiftUI

enum Op: String {
    case add = "+", sub = "−", mul = "×", div = "÷", pow = "xʸ"
}

final class CalcModel: ObservableObject {
    @Published var display = "0"
    @Published var activeOp: Op? = nil
    @Published var isDeg = true
    @Published var hasMemory = false

    private var acc: Decimal = 0
    private var pending: Op? = nil
    private var fresh = true
    private var memory: Decimal = 0
    private(set) var plainEntry = true

    private let en = Locale(identifier: "en_US")

    private var current: Decimal {
        Decimal(string: display, locale: en) ?? 0
    }

    private var currentDouble: Double {
        NSDecimalNumber(decimal: current).doubleValue
    }

    // MARK: basic

    func clear() {
        display = "0"
        acc = 0
        pending = nil
        fresh = true
        activeOp = nil
        plainEntry = true
    }

    func digit(_ d: String) {
        if fresh {
            display = d
            fresh = false
        } else if display == "0" {
            display = d
        } else if display.filter({ $0.isNumber }).count < 12 {
            display += d
        }
        plainEntry = (pending == nil)
        activeOp = nil
    }

    func dot() {
        if fresh {
            display = "0."
            fresh = false
        } else if !display.contains(".") {
            display += "."
        }
        plainEntry = false
        activeOp = nil
    }

    func negate() {
        guard display != "0" else { return }
        if display.hasPrefix("-") {
            display.removeFirst()
        } else {
            display = "-" + display
        }
        plainEntry = false
    }

    func percent() {
        display = format(current / 100)
        fresh = true
        plainEntry = false
    }

    func op(_ o: Op) {
        if let p = pending, !fresh {
            guard let r = compute(acc, p, current) else { showError(); return }
            acc = r
            display = format(r)
        } else if pending == nil {
            acc = current
        }
        pending = o
        fresh = true
        activeOp = o
        plainEntry = false
    }

    func equals() {
        guard let p = pending else { return }
        plainEntry = false
        guard let r = compute(acc, p, current) else { showError(); return }
        display = format(r)
        acc = r
        pending = nil
        fresh = true
        activeOp = nil
    }

    // MARK: scientific

    private func apply(_ f: (Double) -> Double) {
        let r = f(currentDouble)
        guard r.isFinite else { showError(); return }
        display = format(Decimal(r))
        fresh = true
        plainEntry = false
    }

    func unary(_ f: (Double) -> Double) { apply(f) }

    func trig(_ f: (Double) -> Double) {
        let k = isDeg ? Double.pi / 180 : 1
        apply { f($0 * k) }
    }

    func factorial() {
        apply { x in
            guard x >= 0, x <= 170, x == x.rounded() else { return Double.nan }
            var r = 1.0
            if x >= 2 {
                for i in 2...Int(x) { r *= Double(i) }
            }
            return r
        }
    }

    func constant(_ v: Double) {
        display = format(Decimal(v))
        fresh = true
        plainEntry = false
    }

    func toggleAngle() { isDeg.toggle() }

    // MARK: memory

    func memoryClear() { memory = 0; hasMemory = false }

    func memoryAdd() {
        memory += current
        hasMemory = true
        fresh = true
    }

    func memorySub() {
        memory -= current
        hasMemory = true
        fresh = true
    }

    func memoryRecall() {
        display = format(memory)
        fresh = true
        plainEntry = false
    }

    // MARK: internals

    private func compute(_ a: Decimal, _ o: Op, _ b: Decimal) -> Decimal? {
        switch o {
        case .add: return a + b
        case .sub: return a - b
        case .mul: return a * b
        case .div:
            if b == 0 { return nil }
            return a / b
        case .pow:
            let r = Foundation.pow(NSDecimalNumber(decimal: a).doubleValue, NSDecimalNumber(decimal: b).doubleValue)
            guard r.isFinite else { return nil }
            return Decimal(r)
        }
    }

    private func showError() {
        display = "خطأ"
        acc = 0
        pending = nil
        fresh = true
        activeOp = nil
        plainEntry = false
    }

    private func format(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.locale = en
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.maximumFractionDigits = 8
        let s = f.string(from: d as NSDecimalNumber) ?? "0"
        if s.count > 12 {
            let sf = NumberFormatter()
            sf.locale = en
            sf.numberStyle = .scientific
            sf.maximumSignificantDigits = 6
            return sf.string(from: d as NSDecimalNumber) ?? s
        }
        return s
    }
}

// MARK: - Button style

struct KeyButtonStyle: ButtonStyle {
    let bg: Color
    let fg: Color
    let w: CGFloat
    let h: CGFloat
    let font: CGFloat
    var highlighted: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: font, weight: .regular))
            .foregroundColor(highlighted ? bg : fg)
            .frame(width: w, height: h)
            .background(Capsule().fill(highlighted ? Color.white : bg))
            .overlay(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.25 : 0)))
            .contentShape(Capsule())
    }
}

struct KeyDim {
    let w: CGFloat
    let h: CGFloat
    let font: CGFloat
}

// MARK: - View

struct CalculatorView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var m = CalcModel()
    @State private var alertText: String?
    @State private var eqPressed = false

    private let dark = Color(white: 0.2)
    private let sciBg = Color(white: 0.13)
    private let light = Color(white: 0.65)
    private let orange = Color(red: 1.0, green: 0.62, blue: 0.04)

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            VStack(spacing: landscape ? 8 : 12) {
                Spacer(minLength: 0)
                displayView(landscape: landscape)
                if landscape {
                    landscapeKeys(geo.size)
                } else {
                    portraitKeys(geo.size.width)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.layoutDirection, .leftToRight)
        .onAppear {
            if !Passcode.isSet(.real) {
                alertText = "اكتب رمزك السري (٤ أرقام أو أكثر) ثم اضغط مطوّلاً على زر = لحفظه.\n\nبعدها: اكتب الرمز واضغط = لفتح الخزنة."
            }
        }
        .alert("تنبيه", isPresented: Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })) {
            Button("حسناً", role: .cancel) {}
        } message: {
            Text(alertText ?? "")
        }
    }

    // MARK: layouts

    private func displayView(landscape: Bool) -> some View {
        HStack(alignment: .bottom) {
            if m.hasMemory {
                Text("M")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.gray)
                    .padding(.bottom, landscape ? 6 : 14)
            }
            Spacer(minLength: 0)
            Text(m.display)
                .font(.system(size: landscape ? 54 : 88, weight: .light))
                .minimumScaleFactor(0.35)
                .lineLimit(1)
                .foregroundColor(.white)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.8) { bioUnlock() }
        }
        .padding(.horizontal, landscape ? 8 : 20)
    }

    private func portraitKeys(_ width: CGFloat) -> some View {
        let gap: CGFloat = 12
        let w = (width - 24 - gap * 3) / 4
        return stdPanel(KeyDim(w: w, h: w, font: 34), gap: gap)
    }

    private func landscapeKeys(_ size: CGSize) -> some View {
        let gap: CGFloat = 8
        let panelGap: CGFloat = 16
        let w = (size.width - 24 - gap * 6 - panelGap) / 8
        let h = max(34, (size.height - 70 - gap * 4 - 30) / 5)
        let font = min(24, h * 0.5)
        return HStack(spacing: panelGap) {
            sciPanel(KeyDim(w: w, h: h, font: font * 0.82), gap: gap)
            stdPanel(KeyDim(w: w, h: h, font: font), gap: gap)
        }
    }

    // MARK: panels

    private func stdPanel(_ d: KeyDim, gap: CGFloat) -> some View {
        VStack(spacing: gap) {
            HStack(spacing: gap) {
                fn("AC", d) { m.clear() }
                fn("±", d) { m.negate() }
                fn("%", d) { m.percent() }
                opKey(.div, d)
            }
            HStack(spacing: gap) {
                num("7", d); num("8", d); num("9", d)
                opKey(.mul, d)
            }
            HStack(spacing: gap) {
                num("4", d); num("5", d); num("6", d)
                opKey(.sub, d)
            }
            HStack(spacing: gap) {
                num("1", d); num("2", d); num("3", d)
                opKey(.add, d)
            }
            HStack(spacing: gap) {
                Button { m.digit("0") } label: {
                    Text("0")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, d.h * 0.36)
                }
                .buttonStyle(KeyButtonStyle(bg: dark, fg: .white, w: d.w * 2 + gap, h: d.h, font: d.font))

                Button { m.dot() } label: { Text(".") }
                    .buttonStyle(KeyButtonStyle(bg: dark, fg: .white, w: d.w, h: d.h, font: d.font))

                equalsKey(d)
            }
        }
    }

    private func sciPanel(_ d: KeyDim, gap: CGFloat) -> some View {
        VStack(spacing: gap) {
            HStack(spacing: gap) {
                sci("mc", d) { m.memoryClear() }
                sci("m+", d) { m.memoryAdd() }
                sci("m−", d) { m.memorySub() }
                sci("mr", d) { m.memoryRecall() }
            }
            HStack(spacing: gap) {
                sci("x²", d) { m.unary { $0 * $0 } }
                sci("x³", d) { m.unary { $0 * $0 * $0 } }
                sci("xʸ", d) { m.op(.pow) }
                sci("eˣ", d) { m.unary { Foundation.exp($0) } }
            }
            HStack(spacing: gap) {
                sci("1/x", d) { m.unary { $0 == 0 ? Double.nan : 1 / $0 } }
                sci("√x", d) { m.unary { $0 < 0 ? Double.nan : $0.squareRoot() } }
                sci("∛x", d) { m.unary { Foundation.cbrt($0) } }
                sci("10ˣ", d) { m.unary { Foundation.pow(10, $0) } }
            }
            HStack(spacing: gap) {
                sci("x!", d) { m.factorial() }
                sci("sin", d) { m.trig { Foundation.sin($0) } }
                sci("cos", d) { m.trig { Foundation.cos($0) } }
                sci("tan", d) { m.trig { Foundation.tan($0) } }
            }
            HStack(spacing: gap) {
                sci("ln", d) { m.unary { $0 <= 0 ? Double.nan : Foundation.log($0) } }
                sci("log", d) { m.unary { $0 <= 0 ? Double.nan : Foundation.log10($0) } }
                sci("π", d) { m.constant(Double.pi) }
                sci(m.isDeg ? "Deg" : "Rad", d) { m.toggleAngle() }
            }
        }
    }

    // MARK: keys

    private func num(_ t: String, _ d: KeyDim) -> some View {
        Button { m.digit(t) } label: { Text(t) }
            .buttonStyle(KeyButtonStyle(bg: dark, fg: .white, w: d.w, h: d.h, font: d.font))
    }

    private func fn(_ t: String, _ d: KeyDim, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(t) }
            .buttonStyle(KeyButtonStyle(bg: light, fg: .black, w: d.w, h: d.h, font: d.font))
    }

    private func sci(_ t: String, _ d: KeyDim, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(t) }
            .buttonStyle(KeyButtonStyle(bg: sciBg, fg: .white, w: d.w, h: d.h, font: d.font))
    }

    private func opKey(_ o: Op, _ d: KeyDim) -> some View {
        Button { m.op(o) } label: { Text(o.rawValue) }
            .buttonStyle(KeyButtonStyle(bg: orange, fg: .white, w: d.w, h: d.h, font: d.font, highlighted: m.activeOp == o))
    }

    private func equalsKey(_ d: KeyDim) -> some View {
        Text("=")
            .font(.system(size: d.font, weight: .regular))
            .foregroundColor(.white)
            .frame(width: d.w, height: d.h)
            .background(Capsule().fill(orange))
            .opacity(eqPressed ? 0.7 : 1)
            .contentShape(Capsule())
            .onTapGesture { equalsTapped() }
            .onLongPressGesture(minimumDuration: 0.8, maximumDistance: 40, pressing: { p in
                eqPressed = p
            }, perform: {
                longEquals()
            })
    }

    // MARK: logic

    private func isCodeLike(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 12 && s.allSatisfy { "0123456789".contains($0) }
    }

    private func equalsTapped() {
        let code = m.display
        if m.plainEntry, isCodeLike(code) {
            if Attempts.isLocked {
                m.equals()
                return
            }
            if let kind = Passcode.match(code) {
                Attempts.reset()
                m.clear()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                switch kind {
                case .real:
                    app.unlock(.real)
                case .decoy:
                    app.unlock(.decoy)
                case .panic:
                    VaultStore.wipeReal()
                    app.unlock(.decoy)
                }
                return
            } else if code.count >= 4 {
                Attempts.recordFail()
            }
        }
        m.equals()
    }

    private func longEquals() {
        guard !Passcode.isSet(.real) else { return }
        let code = m.display
        guard isCodeLike(code), code.count >= 4 else {
            alertText = "الرمز لازم يكون ٤ أرقام على الأقل."
            return
        }
        Passcode.set(code, kind: .real)
        m.clear()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        alertText = "تم حفظ الرمز. اكتبه واضغط = لفتح الخزنة."
    }

    private func bioUnlock() {
        guard Bio.enabled, Passcode.isSet(.real) else { return }
        Bio.authenticate { ok in
            if ok {
                m.clear()
                app.unlock(.real)
            }
        }
    }
}
