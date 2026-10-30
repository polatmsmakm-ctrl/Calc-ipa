import SwiftUI

// MARK: - Model (Snake II style: constant walls, bonus food, level speed)

private final class SnakeModel {
    struct P: Equatable { var x: Int; var y: Int }

    var cols = 21
    var rows = 12
    var body: [P] = []
    var dir = P(x: 1, y: 0)
    var queue: [P] = []
    var food = P(x: 8, y: 8)
    var bonus: P? = nil
    var bonusLeft: Double = 0
    var eaten = 0
    var score = 0
    var over = false
    var started = false
    var acc: TimeInterval = 0
    var last: TimeInterval = 0
    var clock: TimeInterval = 0
    var best = UserDefaults.standard.integer(forKey: "snake.best")
    var newBest = false

    var interval: TimeInterval { max(0.075, 0.15 - Double(eaten / 5) * 0.008) }

    func reset(cols c: Int, rows r: Int) {
        cols = c; rows = r
        let y = rows / 2
        body = [P(x: 6, y: y), P(x: 5, y: y), P(x: 4, y: y), P(x: 3, y: y)]
        dir = P(x: 1, y: 0); queue = []
        score = 0; eaten = 0; bonus = nil
        over = false; started = false; newBest = false
        acc = 0; last = 0
        placeFood()
    }

    func free() -> P {
        var f: [P] = []
        for x in 0..<cols { for y in 0..<rows {
            let p = P(x: x, y: y)
            if !body.contains(p) && p != food { f.append(p) }
        } }
        return f.randomElement() ?? P(x: 0, y: 0)
    }

    func placeFood() { food = free() }

    func turn(_ d: P) {
        if over { return }
        let ref = queue.last ?? dir
        started = true
        if (d.x == -ref.x && d.y == -ref.y) || d == ref { return }
        if queue.count < 3 { queue.append(d) }
    }

    func step(now: TimeInterval) {
        if last == 0 { last = now }
        let dt = min(now - last, 0.1)
        last = now
        clock = now
        guard started, !over else { return }
        if bonus != nil {
            bonusLeft -= dt
            if bonusLeft <= 0 { bonus = nil }
        }
        acc += dt
        while acc >= interval && !over {
            acc -= interval
            advance()
        }
    }

    private func advance() {
        if !queue.isEmpty { dir = queue.removeFirst() }
        let head = P(x: body[0].x + dir.x, y: body[0].y + dir.y)
        let eating = head == food
        let eatBonus = bonus.map { head == $0 || head == P(x: $0.x + 1, y: $0.y) || head == P(x: $0.x, y: $0.y + 1) || head == P(x: $0.x + 1, y: $0.y + 1) } ?? false
        let check = (eating || eatBonus) ? body : Array(body.dropLast())
        if head.x < 0 || head.y < 0 || head.x >= cols || head.y >= rows || check.contains(head) {
            over = true
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            if score > best {
                best = score; newBest = true
                UserDefaults.standard.set(score, forKey: "snake.best")
            }
            return
        }
        body.insert(head, at: 0)
        if eating {
            score += 7
            eaten += 1
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            placeFood()
            if eaten % 5 == 0 && bonus == nil {
                var b = free()
                b.x = min(b.x, cols - 2); b.y = min(b.y, rows - 2)
                if !body.contains(b) && b != food {
                    bonus = b; bonusLeft = 6
                }
            }
        } else if eatBonus {
            score += max(10, Int(bonusLeft * 10))
            bonus = nil
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } else {
            body.removeLast()
        }
    }
}

// MARK: - View

struct SnakeGameView: View {
    let onExit: () -> Void
    @State private var model = SnakeModel()
    @State private var ready = false

    // لون شاشة LCD الكلاسيكية
    private let lcd = Color(red: 0.62, green: 0.71, blue: 0.27)
    private let ink = Color(red: 0.07, green: 0.12, blue: 0.06)
    private let bodyTop = Color(red: 0.22, green: 0.31, blue: 0.45)
    private let bodyBot = Color(red: 0.11, green: 0.17, blue: 0.28)

    var body: some View {
        GeometryReader { geo in
            let lcdW = geo.size.width - 56
            let cell = max(4, floor(lcdW / 21 / 2) * 2)           // خلية زوجية ليبقى الشكل حاد
            let cols = Int(lcdW / cell)
            let lcdH = min(geo.size.height * 0.46, cell * 24)
            let rows = max(10, Int((lcdH - 36) / cell))
            let fieldW = cell * CGFloat(cols)
            let fieldH = cell * CGFloat(rows)

            ZStack {
                LinearGradient(colors: [bodyTop, bodyBot], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                VStack(spacing: 18) {
                    HStack {
                        Button { onExit() } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(.white.opacity(0.85))
                                .frame(width: 44, height: 34)
                                .background(Capsule().fill(Color.white.opacity(0.12)))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 22)

                    // الشاشة
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.55))
                        TimelineView(.animation) { tl in
                            Canvas { ctx, size in
                                model.step(now: tl.date.timeIntervalSinceReferenceDate)
                                draw(&ctx, size: size, cell: cell, fieldW: fieldW, fieldH: fieldH)
                            }
                        }
                        .frame(width: fieldW + 12, height: fieldH + 34)
                        .background(lcd)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .frame(width: fieldW + 28, height: fieldH + 50)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 12).onEnded { v in swipe(v.translation) }
                    )
                    .onTapGesture {
                        if model.over { model.reset(cols: cols, rows: rows) }
                        else if !model.started { model.started = true }
                    }

                    Spacer(minLength: 0)

                    // أزرار الاتجاهات (مثل لوحة نوكيا)
                    VStack(spacing: 12) {
                        key("▲") { model.turn(.init(x: 0, y: -1)) }
                        HStack(spacing: 56) {
                            key("◀") { model.turn(.init(x: -1, y: 0)) }
                            key("▶") { model.turn(.init(x: 1, y: 0)) }
                        }
                        key("▼") { model.turn(.init(x: 0, y: 1)) }
                    }
                    .padding(.bottom, 26)
                }
                .padding(.top, 8)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 24).onEnded { v in swipe(v.translation) }
            )
            .onAppear {
                if !ready { model.reset(cols: cols, rows: rows); ready = true }
            }
        }
    }

    private func swipe(_ t: CGSize) {
        if abs(t.width) > abs(t.height) {
            model.turn(.init(x: t.width > 0 ? 1 : -1, y: 0))
        } else {
            model.turn(.init(x: 0, y: t.height > 0 ? 1 : -1))
        }
    }

    private func key(_ s: String, _ action: @escaping () -> Void) -> some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            if model.over { return }
            action()
        }) {
            Text(s)
                .font(.system(size: 22, weight: .heavy))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 88, height: 52)
                .background(
                    Capsule()
                        .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.48, blue: 0.58),
                                                      Color(red: 0.24, green: 0.29, blue: 0.38)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(Capsule().stroke(Color.black.opacity(0.4), lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.5), radius: 0, y: 3)
                )
        }
    }

    // MARK: drawing

    private func block(_ ctx: inout GraphicsContext, _ r: CGRect, _ color: Color) {
        ctx.fill(Path(r), with: .color(color))
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, cell: CGFloat, fieldW: CGFloat, fieldH: CGFloat) {
        let m = model
        let px = cell / 2                       // "بكسل" الشاشة
        let ox: CGFloat = 6, oy: CGFloat = 28   // إزاحة منطقة اللعب

        // شبكة بكسلات LCD الخفيفة
        var grid = Path()
        var gx: CGFloat = 0
        while gx <= size.width { grid.move(to: CGPoint(x: gx, y: 0)); grid.addLine(to: CGPoint(x: gx, y: size.height)); gx += px }
        var gy: CGFloat = 0
        while gy <= size.height { grid.move(to: CGPoint(x: 0, y: gy)); grid.addLine(to: CGPoint(x: size.width, y: gy)); gy += px }
        ctx.stroke(grid, with: .color(Color.black.opacity(0.07)), lineWidth: 0.5)

        // أرقام النتيجة أعلى الشاشة
        let sc = String(format: "%04d", m.score)
        ctx.draw(Text(sc).font(.system(size: 17, weight: .black, design: .monospaced)).foregroundColor(ink),
                 at: CGPoint(x: ox + 30, y: 13))
        ctx.draw(Text("HI \(String(format: "%04d", m.best))").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(ink.opacity(0.75)),
                 at: CGPoint(x: size.width - 46, y: 13))

        // شريط البونص
        if m.bonus != nil {
            let w = (size.width - 120) * CGFloat(max(0, m.bonusLeft / 6))
            block(&ctx, CGRect(x: 76, y: 8, width: w, height: 5), ink)
        }

        // إطار منطقة اللعب
        let frame = CGRect(x: ox - 3, y: oy - 3, width: fieldW + 6, height: fieldH + 6)
        ctx.stroke(Path(frame), with: .color(ink), lineWidth: 2)

        // الأفعى: مربعات داكنة بينها فراغ بكسل واحد
        let seg = cell - px * 0.5
        for (i, p) in m.body.enumerated() {
            let r = CGRect(x: ox + CGFloat(p.x) * cell + (cell - seg) / 2,
                           y: oy + CGFloat(p.y) * cell + (cell - seg) / 2,
                           width: seg, height: seg)
            block(&ctx, r, ink)
            if i == 0 {
                // عيون الرأس: نقطتان فاتحتان
                let e = max(1.5, px * 0.55)
                let cx = r.midX, cy = r.midY
                let ex = CGFloat(m.dir.x), ey = CGFloat(m.dir.y)
                let s = seg * 0.22
                let a = CGPoint(x: cx + ex * s - ey * s * 1.4, y: cy + ey * s + ex * s * 1.4)
                let b = CGPoint(x: cx + ex * s + ey * s * 1.4, y: cy + ey * s - ex * s * 1.4)
                block(&ctx, CGRect(x: a.x - e / 2, y: a.y - e / 2, width: e, height: e), lcd)
                block(&ctx, CGRect(x: b.x - e / 2, y: b.y - e / 2, width: e, height: e), lcd)
            }
        }

        // الأكل: شكل زائد (+) من خمس بكسلات مثل نوكيا (يومض)
        let blink = Int(m.clock * 4) % 2 == 0
        if blink || !m.started {
            let fx = ox + CGFloat(m.food.x) * cell + cell / 2
            let fy = oy + CGFloat(m.food.y) * cell + cell / 2
            let u = cell / 3
            for (dx, dy) in [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)] {
                block(&ctx, CGRect(x: fx - u / 2 + CGFloat(dx) * u, y: fy - u / 2 + CGFloat(dy) * u, width: u, height: u), ink)
            }
        }

        // الأكل البونص (أكبر، 2×2)
        if let b = m.bonus, Int(m.clock * 6) % 2 == 0 || m.bonusLeft > 2 {
            let r = CGRect(x: ox + CGFloat(b.x) * cell + px * 0.3, y: oy + CGFloat(b.y) * cell + px * 0.3,
                           width: cell * 2 - px * 0.6, height: cell * 2 - px * 0.6)
            ctx.stroke(Path(r), with: .color(ink), lineWidth: 2)
            block(&ctx, r.insetBy(dx: cell * 0.5, dy: cell * 0.5), ink)
        }

        if !m.started && !m.over {
            ctx.draw(Text("PRESS ANY KEY").font(.system(size: 14, weight: .black, design: .monospaced)).foregroundColor(ink),
                     at: CGPoint(x: size.width / 2, y: oy + fieldH * 0.28))
        }
        if m.over {
            let box = CGRect(x: size.width / 2 - 82, y: oy + fieldH * 0.22, width: 164, height: 76)
            block(&ctx, box, lcd)
            ctx.stroke(Path(box), with: .color(ink), lineWidth: 2)
            ctx.draw(Text("GAME OVER").font(.system(size: 18, weight: .black, design: .monospaced)).foregroundColor(ink),
                     at: CGPoint(x: box.midX, y: box.minY + 20))
            ctx.draw(Text(m.newBest ? "NEW BEST \(m.score)" : "SCORE \(m.score)").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(ink),
                     at: CGPoint(x: box.midX, y: box.minY + 42))
            ctx.draw(Text("TAP TO RETRY").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(ink),
                     at: CGPoint(x: box.midX, y: box.minY + 62))
        }
    }
}
