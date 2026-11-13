import Foundation

/// Factor A — Wyckoff structure (30 pts) — mirror of lab/engine.py wyckoff_factor.
/// Book: Villahermosa, "The Wyckoff Methodology in Depth". Rules: docs/strategy.md A0-A3.
enum WyckoffAnalyzer {

    struct WyckoffRange {
        let support: Double
        let resistance: Double
        let lowTouches: Int
        let highTouches: Int
        let startIdx: Int
    }

    struct Shake {
        let kind: String            // "spring" | "utad"
        let penetration: Double     // depth beyond the level, in bricks
        let volumeVsAvg: Double     // shake brick volume / volume SMA(20)
        let reentryBricks: Int      // bricks to reclaim the range (0 = none yet)
        let idx: Int                // absolute brick index of the shake brick
        let extreme: Double         // spring low / UTAD high
        var testValid = false
        var broken = false
    }

    struct Result {
        var points: [String: Int] = [:]
        var range: WyckoffRange?
        var shake: Shake?
        var phase = "?"
        var notes: [String] = []

        var total: Int { points.values.reduce(0, +) }
    }

    // MARK: - Range

    /// Group pivot prices into levels; most-touched level wins (tie: most recent).
    /// A one-off extreme (the spring's own low) must not become support.
    private static func clusterLevel(_ vals: [Double], tol: Double)
        -> (level: Double, touches: Int, lastIdx: Int)? {
        var best: (Double, Int, Int)?
        for (i, v) in vals.enumerated() {
            let near = vals.enumerated().filter { abs($1.element - v) <= tol }
            if near.count < 2 { continue }
            let cand = (v, near.count, near.map(\.offset).max() ?? i)
            if best == nil || cand.1 > best!.1 || (cand.1 == best!.1 && cand.2 > best!.2) {
                best = cand
            }
        }
        guard let b = best else { return nil }
        return (b.0, b.1, b.2)
    }

    static func detectRange(_ bricks: [Brick], lookback: Int = 60,
                            pivotLB: Int = 3) -> WyckoffRange? {
        let seg = Array(bricks.suffix(lookback))
        guard seg.count >= 12 else { return nil }
        let offset = bricks.count - seg.count
        let closes = seg.map(\.close)
        let piv = RenkoEngine.pivots(closes, lookback: pivotLB)
        let highs = piv.filter(\.isHigh).map { closes[$0.index] }
        let lows = piv.filter { !$0.isHigh }.map { closes[$0.index] }
        guard highs.count >= 2, lows.count >= 2,
              let maxC = closes.max(), let minC = closes.min() else { return nil }
        let tol = (maxC - minC) * 0.06
        guard let sup = clusterLevel(lows, tol: tol),
              let res = clusterLevel(highs, tol: tol),
              res.level > sup.level,
              (res.level - sup.level) / sup.level >= 0.002 else { return nil }
        let start = (piv.first?.index ?? 0) + offset
        return WyckoffRange(support: sup.level, resistance: res.level,
                            lowTouches: sup.touches, highTouches: res.touches,
                            startIdx: start)
    }

    // MARK: - Shake (spring / UTAD)

    static func detectShake(_ bricks: [Brick], range: WyckoffRange,
                            volSMA: [Double], window: Int = 15) -> Shake? {
        let tail = Array(bricks.suffix(window))
        let offset = bricks.count - tail.count
        guard tail.count >= 4, let last = bricks.last else { return nil }
        let size = abs(last.close - last.open)
        guard size > 0 else { return nil }

        func volRef(_ relIdx: Int, fallback: Double) -> Double {
            let j = offset + relIdx - 1
            if j >= 0, j < volSMA.count, !volSMA[j].isNaN { return volSMA[j] }
            return fallback
        }

        for (i, b) in tail.enumerated() {
            if b.close < range.support {                       // spring side
                let below = Array(tail[i...])
                let extreme = below.map(\.low).min() ?? b.close
                let depth = (range.support - extreme) / size
                var reentry = 0
                let upper = min(i + 6, tail.count)
                if upper > i + 1 {
                    for j in (i + 1)..<upper where tail[j].close > range.support {
                        reentry = j - i
                        break
                    }
                }
                return Shake(kind: "spring", penetration: depth,
                             volumeVsAvg: b.volume / volRef(i, fallback: b.volume),
                             reentryBricks: reentry, idx: offset + i, extreme: extreme)
            }
            if b.close > range.resistance {                    // UTAD side
                let above = Array(tail[i...])
                let extreme = above.map(\.high).max() ?? b.close
                let depth = (extreme - range.resistance) / size
                var reentry = 0
                let upper = min(i + 6, tail.count)
                if upper > i + 1 {
                    for j in (i + 1)..<upper where tail[j].close < range.resistance {
                        reentry = j - i
                        break
                    }
                }
                return Shake(kind: "utad", penetration: depth,
                             volumeVsAvg: b.volume / volRef(i, fallback: b.volume),
                             reentryBricks: reentry, idx: offset + i, extreme: extreme)
            }
        }
        return nil
    }

    // MARK: - Full factor

    static func analyze(_ bricks: [Brick]) -> Result {
        var out = Result()
        guard bricks.count >= 20, let last = bricks.last else {
            out.notes.append("not enough bricks")
            return out
        }
        let size = abs(last.close - last.open)
        guard size > 0 else {
            out.notes.append("degenerate bricks")
            return out
        }
        let vols = bricks.map(\.volume)
        let volSMA = RenkoEngine.sma(vols, period: 20)

        guard let rng = detectRange(bricks) else {
            out.notes.append("no trading range — no wyckoff edge")
            return out
        }
        out.range = rng
        out.notes.append(String(format: "range %.6g-%.6g (%.1f bricks, %dL/%dH touches)",
                                rng.support, rng.resistance,
                                (rng.resistance - rng.support) / size,
                                rng.lowTouches, rng.highTouches))

        // A0 range quality (0-6)
        out.points["range_touches"] =
            (rng.lowTouches >= 2 && rng.highTouches >= 2) ? 3 : 0
        out.points["range_cause"] = ((rng.resistance - rng.support) / size >= 4) ? 2 : 0
        let half = bricks.count / 2
        let firstV = vols.prefix(half).reduce(0, +) / Double(max(half, 1))
        let secondV = vols.suffix(bricks.count - half).reduce(0, +)
            / Double(max(bricks.count - half, 1))
        out.points["range_vol_contract"] = secondV < firstV ? 1 : 0

        guard let shake = detectShake(bricks, range: rng, volSMA: volSMA) else {
            out.phase = "B"
            out.notes.append("no spring/UTAD in window")
            return out
        }
        var sh = shake
        out.shake = sh
        let longSide = sh.kind == "spring"
        let after = Array(bricks[(sh.idx + 1)...])

        // A-failure override: a later brick closes beyond the shake extreme again
        if longSide {
            sh.broken = after.contains { $0.close < sh.extreme - 1e-12 }
        } else {
            sh.broken = after.contains { $0.close > sh.extreme + 1e-12 }
        }
        if sh.broken {
            out.phase = "B"
            out.shake = sh
            out.notes.append("\(sh.kind) failed — new extreme beyond the shake; wyckoff reset")
            return out
        }
        out.shake = sh

        // A1 shake quality (0-12)
        out.points["shake"] = 5
        if sh.reentryBricks > 0, sh.reentryBricks <= 2, sh.penetration <= 1.0 {
            out.points["shake_typology"] = 2          // fast shallow reclaim — spring #3
        } else if sh.penetration >= 2.0 {
            out.points["shake_typology"] = 1          // terminal shakeout class
        }
        if sh.penetration <= 2.0 { out.points["shake_depth"] = 2 }
        if sh.volumeVsAvg <= 1.0 { out.points["shake_volume"] = 2 }

        // A2 test validity (0-6): only after the reclaim; first pullback holds the
        // extreme on volume lower than the two previous bricks (book Ch. 17/18).
        if sh.reentryBricks > 0 {
            let reIdx = sh.idx + sh.reentryBricks
            let want = longSide ? -1 : 1
            for (k, b) in bricks[(reIdx + 1)...].enumerated() {
                if b.direction == want {
                    let holds = longSide ? b.close > sh.extreme : b.close < sh.extreme
                    if holds {
                        sh.testValid = true
                        out.shake = sh
                        out.points["test_hold"] = 3
                        let tIdx = reIdx + 1 + k
                        let v1 = tIdx >= 2 ? vols[tIdx - 2] : Double.infinity
                        let v2 = tIdx >= 1 ? vols[tIdx - 1] : Double.infinity
                        if b.volume < v1, b.volume < v2 { out.points["test_volume"] = 2 }
                        if b.candles >= 3 { out.points["test_range"] = 1 }
                    }
                    break
                }
            }
        }

        // A3 phase / SOS / LPS (0-6)
        let mid = (rng.support + rng.resistance) / 2
        let aboveMid = longSide ? last.close > mid : last.close < mid
        let run = longSide ? RenkoEngine.runHead(bricks) : -RenkoEngine.runHead(bricks)
        let lastVRef = volSMA.last.flatMap { $0.isNaN ? nil : $0 } ?? 0
        if aboveMid, run >= 3, vols.last! > lastVRef {
            out.points["phase_d_sos"] = 2
            out.phase = "D"
        } else if aboveMid {
            out.phase = "C->D"
        } else {
            out.phase = "C"
        }
        if bricks.count - rng.startIdx >= 12 { out.points["phase_b_cause"] = 2 }
        if !after.isEmpty {
            let held = longSide
                ? (after.map(\.low).min() ?? 0) > sh.extreme
                : (after.map(\.high).max() ?? 0) < sh.extreme
            let preStart = max(sh.idx - 3, 0)
            let preV = vols[preStart..<sh.idx].reduce(0, +)
            if held, after.map(\.volume).reduce(0, +) < preV {
                out.points["lps"] = 2
            }
        }
        out.notes.append(String(
            format: "%@ depth %.1f brick, vol %.2fx avg, re-entry %d bricks, test %@",
            sh.kind, sh.penetration, sh.volumeVsAvg, sh.reentryBricks,
            sh.testValid ? "valid" : "pending"))
        return out
    }

    /// Points belong to the detected event's side; the mirror side only carries
    /// A0 range points.
    static func pointsFor(_ result: Result, side: TradeDirection) -> Int {
        guard result.range != nil else { return 0 }
        guard let shake = result.shake, !shake.broken else {
            return min(result.total, 6)
        }
        let isLongEvent = shake.kind == "spring"
        return (side == .long) == isLongEvent ? result.total : 0
    }
}
