import Foundation

/// Factor B — Renko trend quality (20 pts) — mirror of lab/engine.py renko_factor.
enum RenkoFactor {

    struct Result {
        let long: Int
        let short: Int
        let run: Int
        let consistency: Double
        let speed: Double
    }

    static func evaluate(_ bricks: [Brick]) -> Result {
        guard bricks.count >= 5, let last = bricks.last else {
            return Result(long: 0, short: 0, run: 0, consistency: 0, speed: 0)
        }
        let head = RenkoEngine.runHead(bricks)
        let upRun = last.direction == 1 ? head : 0
        let dnRun = last.direction == -1 ? head : 0
        let cons = RenkoEngine.consistency(bricks, window: 10)
        let avgSpeed = RenkoEngine.bricksPerCandle(bricks, window: 20)
        let headSpeed = RenkoEngine.bricksPerCandle(bricks, window: max(head, 2))

        func structureOK(side: TradeDirection) -> Bool {
            let seg = bricks.suffix(6)
            let tops = seg.filter { $0.direction == (side == .long ? 1 : -1) }
                .map(\.close)
            guard tops.count >= 2 else { return false }
            return side == .long ? tops.last! > tops.first! : tops.last! < tops.first!
        }

        func score(run: Int, side: TradeDirection) -> Int {
            var s = min(run, 8)                          // 0-8 run length
            s += Int(round(cons * 6))                    // 0-6 consistency
            s += structureOK(side: side) ? 4 : 0         // 0-4 staircase
            if run >= 3, headSpeed > avgSpeed { s += 2 } // 0-2 speed
            return min(s, 20)
        }

        return Result(long: score(run: upRun, side: .long),
                      short: score(run: dnRun, side: .short),
                      run: head, consistency: cons, speed: headSpeed)
    }
}

/// Factor C — Day Traders' Bible tape rules (25 pts) — mirror of tape_factor.
/// Book: Wyckoff, "The Day Traders' Bible". Rules: docs/strategy.md C1-C6.
enum TapeRules {

    struct Result {
        var long = 0
        var short = 0
        var standAside = false
        var warn: String?
        var advDecShare: Double?
        var notes: [String] = []
    }

    static func evaluate(_ candles: [Candle], brickSize: Double) -> Result {
        var out = Result()
        let window = Array(candles.suffix(30))
        guard window.count >= 15 else {
            out.notes.append("not enough candles")
            return out
        }
        let closes = window.map(\.c)
        let piv = RenkoEngine.pivots(closes, lookback: 2)
        let highs = piv.filter(\.isHigh).map { closes[$0.index] }
        let lows = piv.filter { !$0.isHigh }.map { closes[$0.index] }

        // C1 trend of the market (0-6): consecutive higher tops & bottoms
        func trendPts(_ seq: [Double], rising: Bool) -> Int {
            var n = 0
            for (a, b) in zip(seq, seq.dropFirst()) {
                if rising ? (b > a) : (b < a) { n += 1 }
            }
            return min(n * 2, 6)
        }
        var longPts = trendPts(Array(highs.suffix(3)), rising: true)
            + trendPts(Array(lows.suffix(3)), rising: true)
        var shortPts = trendPts(Array(highs.suffix(3)), rising: false)
            + trendPts(Array(lows.suffix(3)), rising: false)
        longPts = min(longPts, 6)
        shortPts = min(shortPts, 6)

        // C2 advances vs declines volume (0-8)
        let upV = window.filter { $0.c > $0.o }.map(\.v).reduce(0, +)
        let dnV = window.filter { $0.c < $0.o }.map(\.v).reduce(0, +)
        let share = (upV + dnV) > 0 ? upV / (upV + dnV) : 0.5
        out.advDecShare = (share * 1000).rounded() / 1000
        longPts += Int(round(max(0, share - 0.5) * 16))
        shortPts += Int(round(max(0, 0.5 - share) * 16))

        // C3 closing strength (0-5): winners close in their top/bottom third
        let bull = window.filter { $0.c > $0.o }
        let bear = window.filter { $0.c < $0.o }
        if !bull.isEmpty {
            let strong = bull.filter { ($0.c - $0.l) > 2 * ($0.h - $0.c) }.count
            longPts += Int(round(min(Double(strong) / Double(bull.count) / 0.7, 1.0) * 5))
        }
        if !bear.isEmpty {
            let strong = bear.filter { ($0.h - $0.c) > 2 * ($0.c - $0.l) }.count
            shortPts += Int(round(min(Double(strong) / Double(bear.count) / 0.7, 1.0) * 5))
        }

        // C4 normal reaction 1/2-2/3 of the preceding swing (0-3)
        if let lastHigh = highs.last, let lastLow = lows.last, lastHigh > lastLow {
            let retrace = (closes.last! - lastLow) / (lastHigh - lastLow)
            if retrace >= 0.5 { longPts += 3 } else if retrace >= 0.33 { longPts += 1 }
            let retraceS = (lastHigh - closes.last!) / (lastHigh - lastLow)
            if retraceS >= 0.5 { shortPts += 3 } else if retraceS >= 0.33 { shortPts += 1 }
        }

        // C5 position of day vs session midrange (0-3)
        let session = candles.suffix(240)
        if session.count >= 30 {
            let hi = session.map(\.h).max() ?? 0
            let lo = session.map(\.l).min() ?? 0
            let mid = (hi + lo) / 2
            if closes.last! > mid {
                longPts += closes.last! < mid + (hi - mid) / 2 ? 2 : 3
            }
            if closes.last! < mid {
                shortPts += closes.last! > mid - (mid - lo) / 2 ? 2 : 3
            }
        }

        // C6 stand-aside filters — the book's "when NOT to trade"
        let wRange = (window.map(\.h).max() ?? 0) - (window.map(\.l).min() ?? 0)
        let vAvg = window.map(\.v).reduce(0, +) / Double(window.count)
        let sessionVols = candles.suffix(60)
        let svAvg = sessionVols.map(\.v).reduce(0, +) / Double(max(sessionVols.count, 1))
        if wRange <= 2 * brickSize, vAvg <= 0.6 * svAvg {
            out.standAside = true
            out.warn = "lifeless market (narrow radius + small volume) — stand aside"
        } else if wRange <= brickSize, vAvg >= 2.5 * svAvg {
            out.standAside = true
            out.warn = "abnormal volume in tiny radius — manipulation watch, stand aside"
        }

        out.long = min(longPts, 25)
        out.short = min(shortPts, 25)
        return out
    }
}
