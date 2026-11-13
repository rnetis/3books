import SwiftUI

/// Signal detail: Renko canvas, trade plan, and the full score breakdown
/// showing which book contributed what.
struct SignalDetailView: View {

    let signal: ScanSignal

    var body: some View {
        ZStack {
            TerminalTheme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 12) {
                    header
                    tradePlan
                    RenkoCanvasView(symbol: signal.symbol,
                                    direction: signal.direction,
                                    brickSize: signal.brickSize)
                    scoreBreakdown
                }
                .padding(12)
            }
        }
        .navigationTitle(signal.symbol.replacingOccurrences(of: "-SWAP-USDT", with: ""))
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(signal.direction.rawValue) \(signal.score)/100")
                .font(.system(.title2, design: .monospaced).bold())
                .foregroundColor(TerminalTheme.directionColor(signal.direction))
            Spacer()
            Text("last \(String(format: "%.6g", signal.price)) · \(signal.brickCount) bricks")
                .mono()
                .foregroundColor(TerminalTheme.dim)
        }
        .terminalCard()
    }

    private var tradePlan: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TRADE PLAN").mono().foregroundColor(TerminalTheme.dim)
            planRow("entry", signal.entry)
            planRow("stop", signal.stop)
            planRow("1R (scalp unit)", signal.target1)
            planRow("2R (runner)", signal.target2)
            if let s = signal.stretchTarget {
                planRow("wyckoff cause projection", s)
            }
            HStack {
                Text(String(format: "risk %.4g · R:R %.2f", signal.risk, signal.riskReward))
                    .mono()
                Spacer()
                Text("max 3% capital exposure (Miner p.159)").mono()
            }
            .foregroundColor(TerminalTheme.dim)
        }
        .terminalCard()
    }

    private func planRow(_ label: String, _ value: Double?) -> some View {
        HStack {
            Text(label).mono().foregroundColor(TerminalTheme.dim)
            Spacer()
            Text(value.map { String(format: "%.6g", $0) } ?? "—")
                .font(.system(.callout, design: .monospaced).bold())
                .foregroundColor(.white)
        }
    }

    private var scoreBreakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SCORE BREAKDOWN — 30 Wyckoff / 20 Renko / 25 Tape / 25 Miner")
                .mono()
                .foregroundColor(TerminalTheme.dim)
            ForEach(signal.breakdown) { factor in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(factor.title) — \(factor.book)")
                            .mono()
                            .foregroundColor(.white)
                        Spacer()
                        let pts = signal.direction == .short ? factor.short : factor.long
                        Text("\(pts)/\(factor.max)")
                            .font(.system(.caption, design: .monospaced).bold())
                            .foregroundColor(TerminalTheme.scoreColor(pts * 100 / factor.max))
                    }
                    ScoreBar(long: factor.long, short: factor.short, max: factor.max)
                    ForEach(factor.notes, id: \.self) { note in
                        Text("· \(note)")
                            .mono()
                            .foregroundColor(TerminalTheme.dim)
                    }
                }
                .terminalCard()
            }
        }
    }
}

struct ScoreBar: View {
    let long: Int
    let short: Int
    let max: Int

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Rectangle().fill(TerminalTheme.green)
                    .frame(width: geo.size.width * CGFloat(long) / CGFloat(max))
                Rectangle().fill(TerminalTheme.red)
                    .frame(width: geo.size.width * CGFloat(short) / CGFloat(max))
                Rectangle().fill(TerminalTheme.grid)
            }
        }
        .frame(height: 6)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
