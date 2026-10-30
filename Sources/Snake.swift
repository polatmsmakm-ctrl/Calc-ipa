import SwiftUI

private final class SnakeModel {
    struct P: Equatable { var x: Int; var y: Int }

    let cols = 16
    var rows = 22
    var body: [P] = []
    var dir = P(x: 1, y: 0)
    var queue: [P] = []
    var food = P(x: 8, y: 8)
    var score = 0
    var over = false
    var started = false
    var acc: TimeInterval = 0
    var last: TimeInterval = 0
    var best = UserDefaults.standard.integer(forKey: "snake.best")
    var newBest = false

    var interval: TimeInterval { max(0.07, 0.17 - Double(score) * 0.004) }

    func reset(rows r: Int) {
        rows = max(12, r)
        body = [P(x: 4, y: rows / 2), P(x: 3, y: rows / 2), P(x: 2, y: rows / 2)]
        dir = P(x: 1, y: 0); queue = []
        score = 0; over = false; started = false; newBest = false
        acc = 0; last = 0
        placeFood()
    }

    func placeFood() {
        var free: [P] = []
        for x in 0..<cols { for y in 0..<rows where !body.contains(P(x: x, y: y)) { free.append(P(x: x, y: y)) } }
        food = free.randomElement() ?? P(x: 0, y: 0)
    }

    func turn(_ d: P) {
        let ref = queue.last ?? dir
        if d.x == -ref.x && d.y == -ref.y { return }
        if d == ref { return }
        if queue.count < 2 { queue.append(d) }
        started = true
    }

    func step(now: TimeInterval) {
        if last == 0 { last = now }
        let dt = min(now - last, 0.1)
        last = now
        guard started, !over else { return }
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
        let check = eating ? body : Array(body.dropLast())
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
            score += 1
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            placeFood()
        } else {
            body.removeLast()
        }
    }
}

struct SnakeGameView: View {
    let onExit: () -> Void
    @State private var model = SnakeModel()
    @State private var ready = false

    private let lcdBG = Color(red: 0.62, green: 0.74, blue: 0.20)
    private let lcdDark = Color(red: 0.12, green: 0.18, blue: 0.08)

    var body: some View {
        GeometryReader { geo in
            let topPad: CGFloat = 70
            let avail = CGSize(width: geo.size.width - 24, height: geo.size.height - topPad - 24)
            let cell = floor(min(avail.width / 16, avail.height / 12))
            let rows = max(12, Int(avail.height / max(cell, 1)))
            ZStack(alignment: .topLeading) {
                Color(red: 0.16, green: 0.20, blue: 0.10).ignoresSafeArea()

                VStack(spacing: 8) {
                    HStack {
                        Button { onExit() } label: {
                            Image(systemName: "chevron.left.circle.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(.white, Color.white.opacity(0.2))
                        }
                        Spacer()
                        Text("SNAKE")
                            .font(.system(size: 22, weight: .black, design: .monospaced))
                            .foregroundColor(lcdBG)
                        Spacer()
                        Color.clear.frame(width: 34, height: 34)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    TimelineView(.animation) { tl in
                        Canvas { ctx, size in
                            model.step(now: tl.date.timeIntervalSinceReferenceDate)
                            draw(&ctx, size: size, cell: cell)
                        }
                    }
                    .frame(width: cell * 16, height: cell * CGFloat(rows))
                    .background(lcdBG)
                    .overlay(Rectangle().stroke(lcdDark, lineWidth: 4))
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 14)
                            .onEnded { v in
                                let dx = v.translation.width, dy = v.translation.height
                                if abs(dx) > abs(dy) {
                                    model.turn(.init(x: dx > 0 ? 1 : -1, y: 0))
                                } else {
                                    model.turn(.init(x: 0, y: dy > 0 ? 1 : -1))
                                }
                            }
                    )
                    .onTapGesture { if model.over { model.reset(rows: rows) } }
                    Spacer(minLength: 0)
                }
            }
            .onAppear {
                if !ready { model.reset(rows: rows); ready = true }
            }
        }
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, cell: CGFloat) {
        let m = model
        let r = Rect(cell: cell)
        // snake
        for (i, p) in m.body.enumerated() {
            let rect = r.at(p.x, p.y).insetBy(dx: 1, dy: 1)
            ctx.fill(Path(rect), with: .color(lcdDark))
            if i == 0 {
                let e = cell * 0.14
                ctx.fill(Path(CGRect(x: rect.midX - e / 2 + CGFloat(m.dir.y) * cell * 0.2,
                                     y: rect.midY - e / 2 + CGFloat(m.dir.x) * cell * 0.2,
                                     width: e, height: e)), with: .color(lcdBG))
            }
        }
        // food (diamond)
        let fc = r.at(m.food.x, m.food.y)
        var d = Path()
        d.move(to: CGPoint(x: fc.midX, y: fc.minY + 1))
        d.addLine(to: CGPoint(x: fc.maxX - 1, y: fc.midY))
        d.addLine(to: CGPoint(x: fc.midX, y: fc.maxY - 1))
        d.addLine(to: CGPoint(x: fc.minX + 1, y: fc.midY))
        d.closeSubpath()
        ctx.fill(d, with: .color(lcdDark))

        // HUD
        ctx.draw(Text("\(m.score)").font(.system(size: 18, weight: .black, design: .monospaced)).foregroundColor(lcdDark),
                 at: CGPoint(x: 26, y: 16))
        ctx.draw(Text("HI \(m.best)").font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundColor(lcdDark),
                 at: CGPoint(x: size.width - 40, y: 16))

        if !m.started && !m.over {
            ctx.draw(Text("SWIPE TO START").font(.system(size: 18, weight: .black, design: .monospaced)).foregroundColor(lcdDark),
                     at: CGPoint(x: size.width / 2, y: size.height * 0.3))
        }
        if m.over {
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(lcdBG.opacity(0.7)))
            ctx.draw(Text("GAME OVER").font(.system(size: 28, weight: .black, design: .monospaced)).foregroundColor(lcdDark),
                     at: CGPoint(x: size.width / 2, y: size.height * 0.35))
            ctx.draw(Text(m.newBest ? "NEW BEST \(m.score)" : "SCORE \(m.score)").font(.system(size: 18, weight: .bold, design: .monospaced)).foregroundColor(lcdDark),
                     at: CGPoint(x: size.width / 2, y: size.height * 0.35 + 36))
            ctx.draw(Text("TAP TO RETRY").font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundColor(lcdDark),
                     at: CGPoint(x: size.width / 2, y: size.height * 0.35 + 68))
        }
    }

    private struct Rect {
        let cell: CGFloat
        func at(_ x: Int, _ y: Int) -> CGRect {
            CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell)
        }
    }
}
