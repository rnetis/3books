import Foundation

/// Renko brick engine — 1:1 mirror of lab/engine.py build_bricks.
/// Closes drive continuation and flips; wicks only extend the current
/// direction (no intra-candle zigzag). Anchor = first open on a size grid.
enum RenkoEngine {

    static func brickSize(candles: [Candle], multiplier: Double = 0.5,
                          fixed: Double? = nil) -> Double {
        if let fixed, fixed > 0 { return fixed }
        guard let atr = atr(candles, period: 14) else { return 0 }
        return atr * multiplier
    }

    /// ATR(period) on True Range; nil until enough candles.
    static func atr(_ candles: [Candle], period: Int = 14) -> Double? {
        guard candles.count >= period + 1 else { return nil }
        var trs: [Double] = []
        var prevClose = candles[0].c
        for cd in candles.dropFirst() {
            trs.append(max(cd.h - cd.l, abs(cd.h - prevClose), abs(cd.l - prevClose)))
            prevClose = cd.c
        }
        let tail = trs.suffix(period)
        guard !tail.isEmpty else { return nil }
        return tail.reduce(0, +) / Double(tail.count)
    }

    static func buildBricks(candles: [Candle], size: Double,
                            maxBricksPerCandle: Int = 64) -> [Brick] {
        guard size > 0, let first = candles.first else { return [] }
        var bricks: [Brick] = []
        var edge = (first.o / size).rounded() * size
        var direction = 0
        for cd in candles {
            var emitted = 0
            while emitted < maxBricksPerCandle {
                if cd.c >= edge + size {                 // close-based up / flip up
                    bricks.append(Brick(direction: 1, open: edge, close: edge + size,
                                        tOpen: cd.t, tClose: cd.t,
                                        volume: 0, candles: 0,
                                        low: min(cd.l, edge),
                                        high: max(cd.h, edge + size)))
                    edge += size
                    direction = 1
                } else if cd.c <= edge - size {          // close-based down / flip down
                    bricks.append(Brick(direction: -1, open: edge, close: edge - size,
                                        tOpen: cd.t, tClose: cd.t,
                                        volume: 0, candles: 0,
                                        low: min(cd.l, edge - size),
                                        high: max(cd.h, edge)))
                    edge -= size
                    direction = -1
                } else { break }
                emitted += 1
            }
            if direction > 0 {                           // wicks extend current run only
                while cd.h >= edge + size, emitted < maxBricksPerCandle {
                    bricks.append(Brick(direction: 1, open: edge, close: edge + size,
                                        tOpen: cd.t, tClose: cd.t,
                                        volume: 0, candles: 0,
                                        low: min(cd.l, edge),
                                        high: max(cd.h, edge + size)))
                    edge += size
                    emitted += 1
                }
            } else if direction < 0 {
                while cd.l <= edge - size, emitted < maxBricksPerCandle {
                    bricks.append(Brick(direction: -1, open: edge, close: edge - size,
                                        tOpen: cd.t, tClose: cd.t,
                                        volume: 0, candles: 0,
                                        low: min(cd.l, edge - size),
                                        high: max(cd.h, edge)))
                    edge -= size
                    emitted += 1
                }
            }
            if !bricks.isEmpty {                         // attribute the candle once
                bricks[bricks.count - 1].volume += cd.v
                bricks[bricks.count - 1].candles += 1
                bricks[bricks.count - 1].tClose = cd.t
                bricks[bricks.count - 1].low = min(bricks[bricks.count - 1].low, cd.l)
                bricks[bricks.count - 1].high = max(bricks[bricks.count - 1].high, cd.h)
            }
        }
        return bricks
    }

    // MARK: - Series helpers

    static func sma(_ values: [Double], period: Int) -> [Double] {
        var out = [Double](repeating: Double.nan, count: values.count)
        guard period > 0 else { return out }
        var running = 0.0
        for (i, v) in values.enumerated() {
            running += v
            if i >= period { running -= values[i - period] }
            if i >= period - 1 { out[i] = running / Double(period) }
        }
        return out
    }

    /// Consecutive same-direction bricks at the head of the series.
    static func runHead(_ bricks: [Brick]) -> Int {
        guard let last = bricks.last else { return 0 }
        var n = 0
        for b in bricks.reversed() {
            if b.direction != last.direction { break }
            n += 1
        }
        return n
    }

    /// Share of the last `window` bricks in the head direction.
    static func consistency(_ bricks: [Brick], window: Int = 10) -> Double {
        let tail = bricks.suffix(window)
        guard let last = tail.last, !tail.isEmpty else { return 0 }
        let same = tail.filter { $0.direction == last.direction }.count
        return Double(same) / Double(tail.count)
    }

    /// Bricks printed per candle consumed over the window ('speed').
    static func bricksPerCandle(_ bricks: [Brick], window: Int = 10) -> Double {
        let tail = bricks.suffix(window)
        guard !tail.isEmpty else { return 0 }
        let candlesUsed = tail.reduce(0) { $0 + max($1.candles, 1) }
        guard candlesUsed > 0 else { return 0 }
        return Double(tail.count) / Double(candlesUsed)
    }

    /// Fractal pivots (index, isHigh).
    static func pivots(_ values: [Double], lookback: Int = 3) -> [(index: Int, isHigh: Bool)] {
        var out: [(Int, Bool)] = []
        guard values.count > lookback * 2 else { return out }
        for i in lookback..<(values.count - lookback) {
            let window = Array(values[(i - lookback)...(i + lookback)])
            if values[i] == window.max(), window.filter({ $0 == values[i] }).count == 1 {
                out.append((i, true))
            } else if values[i] == window.min(),
                      window.filter({ $0 == values[i] }).count == 1 {
                out.append((i, false))
            }
        }
        return out
    }
}
