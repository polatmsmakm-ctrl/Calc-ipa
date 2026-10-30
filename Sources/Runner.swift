import SwiftUI

// MARK: - Palette

private enum R {
    static let outline = Color(red: 0.16, green: 0.08, blue: 0.30)
    static let purple = Color(red: 0.56, green: 0.36, blue: 0.96)
    static let orange = Color(red: 1.0, green: 0.52, blue: 0.14)
    static let skin = Color(red: 0.98, green: 0.80, blue: 0.66)
    static let zSkin = Color(red: 0.52, green: 0.74, blue: 0.40)
    static let zShirt = Color(red: 0.26, green: 0.34, blue: 0.40)
    static let zPants = Color(red: 0.20, green: 0.22, blue: 0.30)
    static let flame = Color(red: 1.0, green: 0.62, blue: 0.12)
    static let coin = Color(red: 1.0, green: 0.82, blue: 0.20)
}

private func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
    (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
}

private func rgb(_ c: (Double, Double, Double), _ dim: Double = 1) -> Color {
    Color(red: c.0 * dim, green: c.1 * dim, blue: c.2 * dim)
}

// MARK: - Model

private final class RunModel {
    struct Zombie {
        var x: CGFloat
        var tall: Bool
        var phase: CGFloat
        var hit = false
    }

    struct Coin {
        var x: CGFloat
        var h: CGFloat
        var got = false
    }

    let charX: CGFloat = 150
    let maxGap: CGFloat = 230

    var y: CGFloat = 0
    var vy: CGFloat = 0
    var jumps = 0
    var zombies: [Zombie] = []
    var coins: [Coin] = []
    var dist: Double = 0
    var coinCount = 0
    var gap: CGFloat = 200
    var over = false
    var started = false
    var last: TimeInterval = 0
    var anim: CGFloat = 0
    var scroll: CGFloat = 0
    var flash: CGFloat = 0
    var nextZombie: CGFloat = 380
    var nextCoin: CGFloat = 240
    var best = UserDefaults.standard.integer(forKey: "run.best")
    var newBest = false

    func reset() {
        y = 0; vy = 0; jumps = 0
        zombies = []; coins = []
        dist = 0; coinCount = 0
        gap = 200
        over = false; started = false
        last = 0; anim = 0; scroll = 0; flash = 0
        nextZombie = 380; nextCoin = 240
        newBest = false
    }

    func tap() {
        if over { reset(); return }
        started = true
        if jumps < 2 {
            vy = jumps == 0 ? 840 : 740
            jumps += 1
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    var speed: CGFloat { min(520, 270 + CGFloat(dist) * 0.9) }

    func step(now: TimeInterval, width: CGFloat) {
        if last == 0 { last = now }
        let dt = CGFloat(min(now - last, 0.033))
        last = now
        anim += dt * (started ? 1 : 0.35)
        guard started, !over else { return }

        let sp = speed

        vy -= 2300 * dt
        y += vy * dt
        if y <= 0 { y = 0; vy = 0; jumps = 0 }

        scroll += sp * dt
        dist += Double(sp * dt / 40)

        for i in zombies.indices {
            zombies[i].x -= (sp + 70) * dt
            zombies[i].phase += dt * 7
        }
        for i in coins.indices { coins[i].x -= sp * dt }
        zombies.removeAll { $0.x < -80 }
        coins.removeAll { $0.x < -40 }

        nextZombie -= sp * dt
        if nextZombie <= 0 {
            zombies.append(Zombie(x: width + 60, tall: Int.random(in: 0..<10) < 3, phase: CGFloat.random(in: 0...6)))
            nextZombie = CGFloat.random(in: 340...580)
        }
        nextCoin -= sp * dt
        if nextCoin <= 0 {
            let hs: [CGFloat] = [30, 95, 150]
            let h: CGFloat = hs.randomElement() ?? 30
            for k in 0..<3 {
                let cx: CGFloat = width + 40 + CGFloat(k) * 38
                coins.append(Coin(x: cx, h: h))
            }
            nextCoin = CGFloat.random(in: 320...620)
        }

        // collisions
        for i in zombies.indices where !zombies[i].hit {
            let z = zombies[i]
            let zh: CGFloat = z.tall ? 82 : 56
            if abs(z.x - charX) < 28 && y < zh - 10 {
                zombies[i].hit = true
                gap -= 75
                flash = 1
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            }
        }
        for i in coins.indices where !coins[i].got {
            let c = coins[i]
            if abs(c.x - charX) < 30 && abs((c.h + 10) - (y + 26)) < 40 {
                coins[i].got = true
                coinCount += 1
                gap = min(maxGap, gap + 14)
            }
        }

        // الناس الغاضبون يقتربون أكثر كل ما تسرّعت اللعبة، والمسافة ترجع شوي مع الوقت
        gap = min(maxGap, gap + (7 - CGFloat(min(dist, 300)) * 0.012) * dt)
        flash = max(0, flash - dt * 2.2)

        if gap <= 28 {
            over = true
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            let s = Int(dist)
            if s > best {
                best = s
                newBest = true
                UserDefaults.standard.set(s, forKey: "run.best")
            }
        }
    }
}

// MARK: - View

struct DashGameView: View {
    let onExit: () -> Void
    @State private var model = RunModel()

    var body: some View {
        ZStack(alignment: .topLeading) {
            TimelineView(.animation) { timeline in
                Canvas { ctx, size in
                    model.step(now: timeline.date.timeIntervalSinceReferenceDate, width: size.width)
                    render(&ctx, size: size)
                }
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { model.tap() }

            Button { onExit() } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.white, Color.black.opacity(0.3))
                    .padding(16)
            }
        }
    }

    // MARK: render

    private func render(_ ctx: inout GraphicsContext, size: CGSize) {
        let m = model
        let gy = size.height * 0.80
        let f = min(m.dist / 300, 1)

        // sky: نهار -> غروب -> ليل
        let dayTop = (0.27, 0.58, 1.0), dayBot = (0.74, 0.90, 1.0)
        let duskTop = (0.36, 0.22, 0.58), duskBot = (1.0, 0.62, 0.46)
        let nightTop = (0.03, 0.04, 0.12), nightBot = (0.14, 0.16, 0.34)
        let top: (Double, Double, Double)
        let bot: (Double, Double, Double)
        if f < 0.5 {
            top = mix(dayTop, duskTop, f * 2)
            bot = mix(dayBot, duskBot, f * 2)
        } else {
            top = mix(duskTop, nightTop, (f - 0.5) * 2)
            bot = mix(duskBot, nightBot, (f - 0.5) * 2)
        }
        ctx.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(Gradient(colors: [rgb(top), rgb(bot)]),
                                  startPoint: .zero, endPoint: CGPoint(x: 0, y: gy))
        )

        // stars + moon
        let starAlpha = max(0, (f - 0.45) * 1.8)
        if starAlpha > 0 {
            for i in 0..<45 {
                let sx = (CGFloat(i) * 97).truncatingRemainder(dividingBy: size.width)
                let sy = (CGFloat(i) * 53).truncatingRemainder(dividingBy: max(1, gy * 0.55))
                ctx.fill(Path(ellipseIn: CGRect(x: sx, y: sy, width: 2.2, height: 2.2)),
                         with: .color(.white.opacity(starAlpha)))
            }
            let mx = size.width * 0.82, my = size.height * 0.14
            ctx.fill(Path(ellipseIn: CGRect(x: mx - 30, y: my - 30, width: 60, height: 60)),
                     with: .color(Color(red: 0.97, green: 0.97, blue: 0.85).opacity(starAlpha)))
        } else {
            // sun
            ctx.fill(Path(ellipseIn: CGRect(x: size.width * 0.8 - 36, y: size.height * 0.13 - 36, width: 72, height: 72)),
                     with: .color(Color(red: 1, green: 0.93, blue: 0.5).opacity(1 - f * 1.5)))
        }

        // hills (parallax)
        let dim = 1 - 0.65 * f
        hills(&ctx, size: size, base: gy - 120, amp: 38, period: 130, off: m.scroll * 0.15,
              color: rgb((0.30, 0.55, 0.42), dim * 0.9))
        hills(&ctx, size: size, base: gy - 62, amp: 26, period: 90, off: m.scroll * 0.35,
              color: rgb((0.25, 0.62, 0.36), dim))

        // ground
        ctx.fill(Path(CGRect(x: 0, y: gy, width: size.width, height: size.height - gy)),
                 with: .color(rgb((0.30, 0.68, 0.36), dim)))
        ctx.fill(Path(CGRect(x: 0, y: gy, width: size.width, height: 7)),
                 with: .color(rgb((0.22, 0.52, 0.28), dim)))
        // ground ticks + tombstones (scroll)
        let tickStep: CGFloat = 60
        let tickOff = m.scroll.truncatingRemainder(dividingBy: tickStep)
        var tx = -tickOff
        while tx < size.width {
            ctx.fill(Path(CGRect(x: tx, y: gy + 26, width: 22, height: 4)),
                     with: .color(rgb((0.22, 0.52, 0.28), dim)))
            tx += tickStep
        }
        let stoneStep: CGFloat = 420
        let stoneOff = (m.scroll * 0.9).truncatingRemainder(dividingBy: stoneStep)
        var sxp = -stoneOff + 120
        while sxp < size.width + 40 {
            tombstone(&ctx, x: sxp, gy: gy, dim: dim)
            sxp += stoneStep
        }

        // coins
        for c in m.coins where !c.got {
            let cy = gy - c.h - 10
            let bob = sin(m.anim * 4 + c.x * 0.05) * 3
            let rect = CGRect(x: c.x - 11, y: cy - 11 + bob, width: 22, height: 22)
            ctx.fill(Path(ellipseIn: rect), with: .color(R.coin))
            ctx.stroke(Path(ellipseIn: rect), with: .color(R.outline), lineWidth: 2.5)
            ctx.fill(Path(ellipseIn: rect.insetBy(dx: 6, dy: 6)), with: .color(Color(red: 1, green: 0.93, blue: 0.5)))
        }

        // zombies
        for z in m.zombies {
            drawZombie(&ctx, x: z.x, gy: gy, tall: z.tall, phase: z.phase, hit: z.hit, dim: dim)
        }

        // chasers (الناس اللي يلحقونك)
        let run = m.anim * 11
        let people: [(CGFloat, Color, Bool)] = [
            (0, Color(red: 0.85, green: 0.25, blue: 0.25), true),
            (-44, Color(red: 0.25, green: 0.45, blue: 0.85), false),
            (-84, Color(red: 0.95, green: 0.65, blue: 0.20), true),
            (-122, Color(red: 0.45, green: 0.75, blue: 0.40), false)
        ]
        for (i, p) in people.enumerated() {
            let x = m.charX - m.gap + p.0
            if x > -60 {
                drawPerson(&ctx, x: x, gy: gy, shirt: p.1, run: run + CGFloat(i) * 1.7, torch: p.2, dim: dim)
            }
        }

        // player
        drawPlayer(&ctx, x: m.charX, gy: gy, y: m.y, run: run, started: m.started)

        // hit flash
        if m.flash > 0 {
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.red.opacity(Double(m.flash) * 0.28)))
        }

        // HUD
        ctx.draw(
            Text("\(Int(m.dist)) m")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundColor(.white),
            at: CGPoint(x: size.width / 2, y: 60)
        )
        ctx.draw(
            Text("★ \(m.coinCount)    BEST \(m.best)")
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundColor(.white.opacity(0.9)),
            at: CGPoint(x: size.width / 2, y: 92)
        )

        // danger bar
        let barW: CGFloat = 110
        let frac = max(0, min(1, (m.gap - 28) / (m.maxGap - 28)))
        let barRect = CGRect(x: size.width - barW - 18, y: 52, width: barW, height: 10)
        ctx.fill(Path(roundedRect: barRect, cornerRadius: 5), with: .color(.black.opacity(0.35)))
        ctx.fill(Path(roundedRect: CGRect(x: barRect.minX, y: barRect.minY, width: barW * frac, height: 10), cornerRadius: 5),
                 with: .color(frac < 0.3 ? .red : (frac < 0.6 ? .orange : .green)))
        ctx.draw(
            Text("CROWD")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundColor(.white.opacity(0.85)),
            at: CGPoint(x: barRect.midX, y: barRect.minY - 9)
        )
        if m.started && !m.over && frac < 0.3 {
            ctx.draw(
                Text("THEY'RE CATCHING UP!")
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .foregroundColor(Color(red: 1, green: 0.4, blue: 0.4)),
                at: CGPoint(x: size.width / 2, y: 122)
            )
        }

        if !m.started {
            ctx.draw(
                Text("TAP TO RUN!")
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .foregroundColor(.white),
                at: CGPoint(x: size.width / 2, y: size.height * 0.30)
            )
            ctx.draw(
                Text("tap again in the air = double jump")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.9)),
                at: CGPoint(x: size.width / 2, y: size.height * 0.30 + 36)
            )
        }
        if m.over {
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.35)))
            ctx.draw(
                Text("CAUGHT!")
                    .font(.system(size: 46, weight: .black, design: .rounded))
                    .foregroundColor(.white),
                at: CGPoint(x: size.width / 2, y: size.height * 0.30)
            )
            ctx.draw(
                Text("\(Int(m.dist)) m   ★ \(m.coinCount)")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundColor(R.coin),
                at: CGPoint(x: size.width / 2, y: size.height * 0.30 + 46)
            )
            if m.newBest {
                ctx.draw(
                    Text("NEW BEST!")
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundColor(Color(red: 0.5, green: 1, blue: 0.5)),
                    at: CGPoint(x: size.width / 2, y: size.height * 0.30 + 78)
                )
            }
            ctx.draw(
                Text("tap to try again")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.9)),
                at: CGPoint(x: size.width / 2, y: size.height * 0.30 + (m.newBest ? 108 : 80))
            )
        }
    }

    // MARK: scenery helpers

    private func hills(_ ctx: inout GraphicsContext, size: CGSize, base: CGFloat, amp: CGFloat,
                       period: CGFloat, off: CGFloat, color: Color) {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: size.height))
        var x: CGFloat = 0
        while x <= size.width + 8 {
            let yy = base + sin((x + off) / period) * amp + sin((x + off) / (period * 0.43)) * amp * 0.35
            p.addLine(to: CGPoint(x: x, y: yy))
            x += 8
        }
        p.addLine(to: CGPoint(x: size.width + 8, y: size.height))
        p.closeSubpath()
        ctx.fill(p, with: .color(color))
    }

    private func tombstone(_ ctx: inout GraphicsContext, x: CGFloat, gy: CGFloat, dim: Double) {
        let rect = CGRect(x: x - 14, y: gy - 36, width: 28, height: 36)
        let p = Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(topLeading: 14, bottomLeading: 2, bottomTrailing: 2, topTrailing: 14))
        ctx.fill(p, with: .color(rgb((0.62, 0.64, 0.70), dim)))
        ctx.stroke(p, with: .color(R.outline.opacity(0.7)), lineWidth: 2)
        var cross = Path()
        cross.move(to: CGPoint(x: x, y: gy - 28)); cross.addLine(to: CGPoint(x: x, y: gy - 12))
        cross.move(to: CGPoint(x: x - 6, y: gy - 22)); cross.addLine(to: CGPoint(x: x + 6, y: gy - 22))
        ctx.stroke(cross, with: .color(R.outline.opacity(0.6)), lineWidth: 2.5)
    }

    // MARK: characters

    private func drawPlayer(_ ctx: inout GraphicsContext, x: CGFloat, gy: CGFloat, y: CGFloat, run: CGFloat, started: Bool) {
        let r: CGFloat = 26
        let cy = gy - r - y - 6
        // feet
        let swing = (started && y <= 0.5) ? sin(run) * 9 : 0
        for sgn in [CGFloat(-1), CGFloat(1)] {
            let fx = x + sgn * 11 + swing * sgn
            let fy = gy - 6 - (y > 0.5 ? 3 : max(0, sin(run + (sgn > 0 ? 0 : .pi)) * 4))
            ctx.fill(Path(ellipseIn: CGRect(x: fx - 8, y: fy - 4, width: 16, height: 9)), with: .color(R.orange))
            ctx.stroke(Path(ellipseIn: CGRect(x: fx - 8, y: fy - 4, width: 16, height: 9)), with: .color(R.outline), lineWidth: 2)
        }
        // ears
        for sgn in [CGFloat(-1), CGFloat(1)] {
            let e = CGRect(x: x + sgn * 16 - 8, y: cy - r - 4, width: 16, height: 16)
            ctx.fill(Path(ellipseIn: e), with: .color(R.purple))
            ctx.stroke(Path(ellipseIn: e), with: .color(R.outline), lineWidth: 2.5)
        }
        // body
        let body = CGRect(x: x - r, y: cy - r, width: r * 2, height: r * 2)
        ctx.fill(Path(ellipseIn: body), with: .color(R.purple))
        ctx.stroke(Path(ellipseIn: body), with: .color(R.outline), lineWidth: 3)
        // eyes (scared look)
        for dx in [CGFloat(-8), CGFloat(8)] {
            let eye = CGRect(x: x + dx - 7, y: cy - 12, width: 14, height: 17)
            ctx.fill(Path(ellipseIn: eye), with: .color(.white))
            ctx.stroke(Path(ellipseIn: eye), with: .color(R.outline), lineWidth: 1.5)
            ctx.fill(Path(ellipseIn: CGRect(x: x + dx - 3 + 2, y: cy - 7, width: 6, height: 7)), with: .color(R.outline))
        }
        // open mouth
        ctx.fill(Path(ellipseIn: CGRect(x: x - 5, y: cy + 8, width: 10, height: 9)), with: .color(R.outline))
    }

    private func drawPerson(_ ctx: inout GraphicsContext, x: CGFloat, gy: CGFloat, shirt: Color,
                            run: CGFloat, torch: Bool, dim: Double) {
        let s: CGFloat = 1.0
        let hipY = gy - 24 * s
        // legs
        for k in [CGFloat(0), CGFloat.pi] {
            let fx = x + sin(run + k) * 11
            let fy = gy - max(0, -sin(run + k + 1.2)) * 7
            var leg = Path()
            leg.move(to: CGPoint(x: x, y: hipY))
            leg.addLine(to: CGPoint(x: fx, y: fy))
            ctx.stroke(leg, with: .color(rgb((0.2, 0.2, 0.28), dim)), style: StrokeStyle(lineWidth: 6, lineCap: .round))
        }
        // torso
        let torso = CGRect(x: x - 10, y: gy - 54, width: 20, height: 32)
        ctx.fill(Path(roundedRect: torso, cornerRadius: 7), with: .color(shirt.opacity(dim > 0.5 ? 1 : 0.8)))
        ctx.stroke(Path(roundedRect: torso, cornerRadius: 7), with: .color(R.outline), lineWidth: 2)
        // head
        let head = CGRect(x: x - 10, y: gy - 74, width: 20, height: 20)
        ctx.fill(Path(ellipseIn: head), with: .color(R.skin))
        ctx.stroke(Path(ellipseIn: head), with: .color(R.outline), lineWidth: 2)
        // angry brow + open mouth
        var brow = Path()
        brow.move(to: CGPoint(x: x - 1, y: gy - 68)); brow.addLine(to: CGPoint(x: x + 7, y: gy - 65))
        ctx.stroke(brow, with: .color(R.outline), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        ctx.fill(Path(ellipseIn: CGRect(x: x + 1, y: gy - 61, width: 6, height: 5)), with: .color(R.outline))
        ctx.fill(Path(ellipseIn: CGRect(x: x + 3, y: gy - 66, width: 3, height: 3)), with: .color(R.outline))
        // raised arm with torch or fork
        let handX = x + 16
        let handY = gy - 66 + sin(run * 0.5) * 3
        var arm = Path()
        arm.move(to: CGPoint(x: x + 6, y: gy - 48))
        arm.addLine(to: CGPoint(x: handX, y: handY))
        ctx.stroke(arm, with: .color(R.skin), style: StrokeStyle(lineWidth: 5, lineCap: .round))
        if torch {
            var stick = Path()
            stick.move(to: CGPoint(x: handX, y: handY + 6))
            stick.addLine(to: CGPoint(x: handX + 2, y: handY - 16))
            ctx.stroke(stick, with: .color(Color(red: 0.45, green: 0.30, blue: 0.18)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            let fl = sin(run * 2) * 2
            ctx.fill(Path(ellipseIn: CGRect(x: handX - 6, y: handY - 33 + fl, width: 14, height: 18)), with: .color(R.flame))
            ctx.fill(Path(ellipseIn: CGRect(x: handX - 2, y: handY - 28 + fl, width: 6, height: 10)), with: .color(Color(red: 1, green: 0.92, blue: 0.5)))
        } else {
            var fork = Path()
            fork.move(to: CGPoint(x: handX, y: handY + 8))
            fork.addLine(to: CGPoint(x: handX + 2, y: handY - 26))
            fork.move(to: CGPoint(x: handX - 5, y: handY - 20)); fork.addLine(to: CGPoint(x: handX - 5, y: handY - 30))
            fork.move(to: CGPoint(x: handX + 9, y: handY - 20)); fork.addLine(to: CGPoint(x: handX + 9, y: handY - 30))
            fork.move(to: CGPoint(x: handX - 5, y: handY - 20)); fork.addLine(to: CGPoint(x: handX + 9, y: handY - 20))
            ctx.stroke(fork, with: .color(Color(red: 0.75, green: 0.78, blue: 0.82)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }

    private func drawZombie(_ ctx: inout GraphicsContext, x: CGFloat, gy: CGFloat, tall: Bool,
                            phase: CGFloat, hit: Bool, dim: Double) {
        let s: CGFloat = tall ? 1.45 : 1.0
        let alpha: Double = hit ? 0.28 : 1
        let hipY = gy - 24 * s

        // legs (shuffle)
        for k in [CGFloat(0), CGFloat.pi] {
            let fx = x + sin(phase + k) * 7 * s
            var leg = Path()
            leg.move(to: CGPoint(x: x, y: hipY))
            leg.addLine(to: CGPoint(x: fx, y: gy))
            ctx.stroke(leg, with: .color(R.zPants.opacity(alpha)), style: StrokeStyle(lineWidth: 6 * s, lineCap: .round))
        }
        // torso (torn shirt)
        let torso = CGRect(x: x - 11 * s, y: gy - 56 * s, width: 22 * s, height: 34 * s)
        ctx.fill(Path(roundedRect: torso, cornerRadius: 6 * s), with: .color(R.zShirt.opacity(alpha)))
        ctx.stroke(Path(roundedRect: torso, cornerRadius: 6 * s), with: .color(R.outline.opacity(alpha)), lineWidth: 2)
        var tear = Path()
        tear.move(to: CGPoint(x: x - 11 * s, y: gy - 22 * s))
        tear.addLine(to: CGPoint(x: x - 6 * s, y: gy - 28 * s))
        tear.addLine(to: CGPoint(x: x, y: gy - 22 * s))
        tear.addLine(to: CGPoint(x: x + 6 * s, y: gy - 29 * s))
        tear.addLine(to: CGPoint(x: x + 11 * s, y: gy - 22 * s))
        ctx.stroke(tear, with: .color(R.zSkin.opacity(alpha)), lineWidth: 3)
        // head
        let head = CGRect(x: x - 11 * s, y: gy - 78 * s, width: 22 * s, height: 22 * s)
        ctx.fill(Path(ellipseIn: head), with: .color(R.zSkin.opacity(alpha)))
        ctx.stroke(Path(ellipseIn: head), with: .color(R.outline.opacity(alpha)), lineWidth: 2)
        // eyes (one big, one small) + mouth
        ctx.fill(Path(ellipseIn: CGRect(x: x - 8 * s, y: gy - 72 * s, width: 8 * s, height: 8 * s)), with: .color(.white.opacity(alpha)))
        ctx.fill(Path(ellipseIn: CGRect(x: x - 7 * s, y: gy - 70.5 * s, width: 4 * s, height: 4 * s)), with: .color(Color.red.opacity(alpha)))
        ctx.fill(Path(ellipseIn: CGRect(x: x + 1 * s, y: gy - 71 * s, width: 6 * s, height: 6 * s)), with: .color(.white.opacity(alpha)))
        ctx.fill(Path(ellipseIn: CGRect(x: x + 2 * s, y: gy - 70 * s, width: 3 * s, height: 3 * s)), with: .color(Color.red.opacity(alpha)))
        var mouth = Path()
        mouth.move(to: CGPoint(x: x - 6 * s, y: gy - 62 * s))
        mouth.addLine(to: CGPoint(x: x - 3 * s, y: gy - 60 * s))
        mouth.addLine(to: CGPoint(x: x, y: gy - 62 * s))
        mouth.addLine(to: CGPoint(x: x + 3 * s, y: gy - 60 * s))
        mouth.addLine(to: CGPoint(x: x + 6 * s, y: gy - 62 * s))
        ctx.stroke(mouth, with: .color(R.outline.opacity(alpha)), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        // arms stretched toward the player (left)
        for off in [CGFloat(0), CGFloat(7)] {
            var arm = Path()
            arm.move(to: CGPoint(x: x - 6 * s, y: gy - 48 * s + off * s))
            arm.addLine(to: CGPoint(x: x - 30 * s, y: gy - 50 * s + off * s + sin(phase * 0.8 + off) * 3))
            ctx.stroke(arm, with: .color(R.zSkin.opacity(alpha)), style: StrokeStyle(lineWidth: 5 * s, lineCap: .round))
        }
    }
}
