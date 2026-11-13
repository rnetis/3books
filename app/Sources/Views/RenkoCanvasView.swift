import SwiftUI

/// Live Renko chart drawn with Canvas from 1-minute Toobit klines.
struct RenkoCanvasView: View {

    let symbol: String
    let direction: TradeDirection
    let brickSize: Double

    @State private var bricks: [Brick] = []
    @State private var range: (support: Double, resistance: Double)?

    private static let client = ToobitClient()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("RENKO 1m · brick \(String(format: "%.6g", brickSize))")
                    .mono()
                    .foregroundColor(TerminalTheme.dim)
                Spacer()
                Text("▲\(bricks.filter { $0.direction == 1 }.count) ▼\(bricks.filter { $0.direction == -1 }.count)")
                    .mono()
                    .foregroundColor(TerminalTheme.dim)
            }
            if bricks.isEmpty {
                Rectangle()
                    .fill(TerminalTheme.grid)
                    .frame(height: 220)
                    .overlay(Text("loading bricks…").mono()
                        .foregroundColor(TerminalTheme.dim))
            } else {
                Canvas { context, size in
                    draw(&context, size: size)
                }
                .frame(height: 220)
                .background(RoundedRectangle(cornerRadius: 8).fill(TerminalTheme.panel))
            }
        }
        .task {
            await load()
        }
    }

    private func load() async {
        do {
            var k1 = try await Self.client.klines(symbol: symbol, interval: "1m", limit: 1000)
            k1 = SignalScorer.dropPartial(k1, intervalMS: 60_000)
            let built = RenkoEngine.buildBricks(candles: k1, size: brickSize)
            bricks = Array(built.suffix(120))
            range = WyckoffAnalyzer.detectRange(built).map { ($0.support, $0.resistance) }
        } catch {
            bricks = []
        }
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        guard let minLow = bricks.map(\.low).min(),
              let maxHigh = bricks.map(\.high).max() else { return }
        let span = max(maxHigh - minLow, 1e-12)
        let padding: CGFloat = 12
        let drawableH = size.height - padding * 2
        let brickW = size.width / CGFloat(bricks.count) * 0.8
        let gap = size.width / CGFloat(bricks.count)

        func y(_ price: Double) -> CGFloat {
            padding + (1 - CGFloat((price - minLow) / span)) * drawableH
        }

        // range lines (Ice / Creek)
        if let rng = range, rng.support >= minLow, rng.resistance <= maxHigh {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y(rng.resistance)))
            path.addLine(to: CGPoint(x: size.width, y: y(rng.resistance)))
            context.stroke(path, with: .color(TerminalTheme.amber.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            var path2 = Path()
            path2.move(to: CGPoint(x: 0, y: y(rng.support)))
            path2.addLine(to: CGPoint(x: size.width, y: y(rng.support)))
            context.stroke(path2, with: .color(TerminalTheme.amber.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            context.draw(Text("creek").font(.system(size: 8, design: .monospaced))
                .foregroundColor(TerminalTheme.amber.opacity(0.8)),
                at: CGPoint(x: size.width - 24, y: y(rng.resistance) - 6))
            context.draw(Text("ice").font(.system(size: 8, design: .monospaced))
                .foregroundColor(TerminalTheme.amber.opacity(0.8)),
                at: CGPoint(x: size.width - 20, y: y(rng.support) - 6))
        }

        // bricks
        for (i, brick) in bricks.enumerated() {
            let x = CGFloat(i) * gap + gap * 0.1
            let top = y(max(brick.open, brick.close))
            let bottom = y(min(brick.open, brick.close))
            let rect = CGRect(x: x, y: top,
                              width: max(brickW, 2), height: max(bottom - top, 1))
            let color = brick.direction == 1 ? TerminalTheme.green : TerminalTheme.red
            context.fill(Path(rect), with: .color(color.opacity(0.9)))
            context.stroke(Path(rect), with: .color(color), lineWidth: 0.5)
        }
    }
}
