import Foundation

/// Composite scorer — mirror of lab/engine.py scan_symbol.
/// A Wyckoff 30 + B Renko 20 + C tape 25 + D Miner 25 = 100.
/// Weights are the user-selected balanced blend; rubric: docs/strategy.md.
enum SignalScorer {

    static func scan(symbol: String, k1m: [Candle], k15m: [Candle],
                     tick: Double, settings: ScanSettings) -> ScanSignal? {
        let size: Double
        if settings.useFixedBrick {
            size = k1m.last.map { $0.c * settings.fixedBrickPct / 100 } ?? 0
        } else {
            size = RenkoEngine.brickSize(candles: k1m,
                                         multiplier: settings.brickMultiplier)
        }
        guard size > 0 else { return nil }
        let bricks = RenkoEngine.buildBricks(candles: k1m, size: size)
        guard bricks.count >= 15 else { return nil }

        let wyckoff = WyckoffAnalyzer.analyze(bricks)
        let aLong = min(WyckoffAnalyzer.pointsFor(wyckoff, side: .long), 30)
        let aShort = min(WyckoffAnalyzer.pointsFor(wyckoff, side: .short), 30)
        let renko = RenkoFactor.evaluate(bricks)
        let tape = TapeRules.evaluate(k1m, brickSize: size)
        let miner = MinerMomentum.evaluate(ltf: k1m, htf: k15m,
                                           tick: tick, brick: size)

        var sLong = aLong + renko.long + tape.long + MinerMomentum.pointsFor(miner, side: .long)
        var sShort = aShort + renko.short + tape.short + MinerMomentum.pointsFor(miner, side: .short)
        if tape.standAside {
            sLong = min(sLong, 40)
            sShort = min(sShort, 40)
        }

        var direction: TradeDirection = sLong >= sShort ? .long : .short
        var score = max(sLong, sShort)
        if abs(sLong - sShort) < 8 || tape.standAside {
            direction = .neutral
            score = max(sLong, sShort)
        }

        let price = k1m.last!.c
        var entry = miner.entry
        var stop = miner.stop
        if entry == nil || stop == nil {
            switch direction {
            case .long:
                entry = bricks.last?.close
                stop = (bricks.suffix(3).map(\.low).min() ?? price) - size
            case .short:
                entry = bricks.last?.close
                stop = (bricks.suffix(3).map(\.high).max() ?? price) + size
            case .neutral:
                entry = nil
                stop = nil
            }
        }
        let risk = (entry != nil && stop != nil) ? abs(entry! - stop!) : 0
        var t1: Double?
        var t2: Double?
        if let e = entry, risk > 0 {
            let sign: Double = direction == .short ? -1 : 1
            t1 = e + sign * risk
            t2 = e + sign * risk * 2
        }
        var stretch: Double?
        if let rng = wyckoff.range, direction != .neutral {
            let height = rng.resistance - rng.support
            let dur = Double(max(bricks.count - rng.startIdx, 1)) / 60.0
            let proj = height * max(dur, 0.25)
            stretch = direction == .long ? rng.resistance + proj : rng.support - proj
        }

        let breakdown: [FactorBreakdown] = [
            FactorBreakdown(key: "A_wyckoff", title: "Wyckoff structure",
                            book: "The Wyckoff Methodology in Depth",
                            max: 30, long: aLong, short: aShort,
                            notes: wyckoff.notes),
            FactorBreakdown(key: "B_renko", title: "Renko trend",
                            book: "Renko engine (this repo)",
                            max: 20, long: renko.long, short: renko.short,
                            notes: [String(format: "run %d · consistency %.2f · speed %.3f bricks/candle",
                                           renko.run, renko.consistency, renko.speed)]),
            FactorBreakdown(key: "C_tape", title: "Tape rules",
                            book: "The Day Traders' Bible",
                            max: 25, long: tape.long, short: tape.short,
                            notes: {
                                var n = tape.notes
                                if let warn = tape.warn { n.insert(warn, at: 0) }
                                if let s = tape.advDecShare {
                                    n.insert(String(format: "advance/decline volume share %.0f%%",
                                                    s * 100), at: 0)
                                }
                                return n
                            }()),
            FactorBreakdown(key: "D_miner", title: "MTF momentum",
                            book: "High Probability Trading Strategies",
                            max: 25,
                            long: MinerMomentum.pointsFor(miner, side: .long),
                            short: MinerMomentum.pointsFor(miner, side: .short),
                            notes: miner.notes),
        ]

        return ScanSignal(
            symbol: symbol,
            price: price,
            direction: direction,
            score: score,
            scoreLong: sLong,
            scoreShort: sShort,
            notify: (direction == .long || direction == .short)
                && score >= settings.notifyThreshold,
            brickSize: size,
            brickCount: bricks.count,
            entry: entry,
            stop: stop,
            target1: t1,
            target2: t2,
            stretchTarget: stretch,
            breakdown: breakdown,
            phase: wyckoff.phase,
            timestamp: k1m.last!.t)
    }

    /// The last kline is in-progress; engines score completed bars only.
    static func dropPartial(_ candles: [Candle], intervalMS: Int, nowMS: Int? = nil)
        -> [Candle] {
        let now = nowMS ?? Int(Date().timeIntervalSince1970 * 1000)
        if let last = candles.last, last.t + intervalMS > now {
            return Array(candles.dropLast())
        }
        return candles
    }
}
