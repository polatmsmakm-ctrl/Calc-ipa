import SwiftUI

enum Op: String {
    case add = "+", sub = "−", mul = "×", div = "÷"
}

final class CalcModel: ObservableObject {
    @Published var display = "0"
    @Published var activeOp: Op? = nil

    private var acc: Decimal = 0
    private var pending: Op? = nil
    private var fresh = true
    private(set) var plainEntry = true

    private let en = Locale(identifier: "en_US")

    private var current: Decimal {
        Decimal(string: display, locale: en) ?? 0
    }

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

    private func compute(_ a: Decimal, _ o: Op, _ b: Decimal) -> Decimal? {
        switch o {
        case .add: return a + b
        case .sub: return a - b
        case .mul: return a * b
        case .div:
            if b == 0 { return nil }
            return a / b
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
    let size: CGFloat
    var wide: Bool = false
    var highlighted: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 34, weight: .regular))
            .foregroundColor(highlighted ? bg : fg)
            .frame(width: wide ? size * 2 + 12 : size, height: size)
            .background(Capsule().fill(highlighted ? Color.white : bg))
            .overlay(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.25 : 0)))
            .contentShape(Capsule())
    }
}

// MARK: - View

struct CalculatorView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var m = CalcModel()
    @State private var alertText: String?
    @State private var eqPressed = false

    private let spacing: CGFloat = 12
    private let dark = Color(white: 0.2)
    private let light = Color(white: 0.65)
    private let orange = Color(red: 1.0, green: 0.62, blue: 0.04)

    var body: some View {
        GeometryReader { geo in
            let size = (geo.size.width - spacing * 5) / 4
            VStack(spacing: spacing) {
                Spacer(minLength: 0)

                Text(m.display)
                    .font(.system(size: 88, weight: .light))
                    .minimumScaleFactor(0.35)
                    .lineLimit(1)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, spacing * 2)
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 0.8) { bioUnlock() }

                HStack(spacing: spacing) {
                    fn("AC", size) { m.clear() }
                    fn("±", size) { m.negate() }
                    fn("%", size) { m.percent() }
                    opKey(.div, size)
                }
                HStack(spacing: spacing) {
                    num("7", size); num("8", size); num("9", size)
                    opKey(.mul, size)
                }
                HStack(spacing: spacing) {
                    num("4", size); num("5", size); num("6", size)
                    opKey(.sub, size)
                }
                HStack(spacing: spacing) {
                    num("1", size); num("2", size); num("3", size)
                    opKey(.add, size)
                }
                HStack(spacing: spacing) {
                    Button { m.digit("0") } label: {
                        Text("0")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, size * 0.36)
                    }
                    .buttonStyle(KeyButtonStyle(bg: dark, fg: .white, size: size, wide: true))

                    Button { m.dot() } label: { Text(".") }
                        .buttonStyle(KeyButtonStyle(bg: dark, fg: .white, size: size))

                    equalsKey(size)
                }
            }
            .padding(.horizontal, spacing)
            .padding(.bottom, spacing)
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.layoutDirection, .leftToRight)
        .onAppear {
            if !Passcode.isSet {
                alertText = "اكتب رمزك السري (٤ أرقام أو أكثر) ثم اضغط مطوّلاً على زر = لحفظه.\n\nبعدها: اكتب الرمز واضغط = لفتح الخزنة."
            }
        }
        .alert("تنبيه", isPresented: Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })) {
            Button("حسناً", role: .cancel) {}
        } message: {
            Text(alertText ?? "")
        }
    }

    // MARK: keys

    private func num(_ t: String, _ size: CGFloat) -> some View {
        Button { m.digit(t) } label: { Text(t) }
            .buttonStyle(KeyButtonStyle(bg: dark, fg: .white, size: size))
    }

    private func fn(_ t: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(t) }
            .buttonStyle(KeyButtonStyle(bg: light, fg: .black, size: size))
    }

    private func opKey(_ o: Op, _ size: CGFloat) -> some View {
        Button { m.op(o) } label: { Text(o.rawValue) }
            .buttonStyle(KeyButtonStyle(bg: orange, fg: .white, size: size, highlighted: m.activeOp == o))
    }

    private func equalsKey(_ size: CGFloat) -> some View {
        Text("=")
            .font(.system(size: 34, weight: .regular))
            .foregroundColor(.white)
            .frame(width: size, height: size)
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

    private func equalsTapped() {
        if Passcode.isSet, m.plainEntry, Passcode.verify(m.display) {
            m.clear()
            app.unlock()
            return
        }
        m.equals()
    }

    private func longEquals() {
        guard !Passcode.isSet else { return }
        let code = m.display
        let digitsOnly = code.allSatisfy { "0123456789".contains($0) }
        guard digitsOnly, code.count >= 4 else {
            alertText = "الرمز لازم يكون ٤ أرقام على الأقل."
            return
        }
        Passcode.set(code)
        m.clear()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        alertText = "تم حفظ الرمز. اكتبه واضغط = لفتح الخزنة."
    }

    private func bioUnlock() {
        guard Bio.enabled, Passcode.isSet else { return }
        Bio.authenticate { ok in
            if ok {
                m.clear()
                app.unlock()
            }
        }
    }
}
