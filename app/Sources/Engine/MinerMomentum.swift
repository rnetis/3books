import Foundation

/// Factor D — Miner dual-time-frame momentum + trigger (25 pts)
/// — mirror of lab/engine.py miner_factor.
/// Book: Miner, "High Probability Trading Strategies". Rules: docs/strategy.md D0-D3.
enum MinerMomentum {

    struct Result {
        var points: [String: Int] = [:]
        var htfState = "?"
        var ltfReversalAge: Int?
        var trigger: String?
        var entry: Double?
        var stop: Double?
        var notes: [String] = []

        var total: Int { points.values.reduce(0, +) }
    }

    /// Slow stochastic: fast %K over kPeriod, slow %K = SMA(smooth) of fast %K,
    /// %D = SMA(smooth) of slow %K. OB/OS lines 75/25 (book p.41-44).
    static func stochastic(_ candles: [Candle], kPeriod: Int = 14, smooth: Int = 3)
        -> (slowK: [Double], d: [Double]) {
        var fastK = [Double](repeating: 50, count: candles.count)
        for i in (kPeriod - 1)..<candles.count {
            let seg = candles[(i - kPeriod + 1)...i]
            let hi = seg.map(\.h).max() ?? 0
            let lo = seg.map(\.l).min() ?? 0
            fastK[i] = hi > lo ? 100 * (candles[i].c - lo) / (hi - lo) : 50
        }
        let sk = RenkoEngine.sma(fastK, period: smooth).map { $0.isNaN ? 50 : $0 }
        let d = RenkoEngine.sma(sk, period: smooth).map { $0.isNaN ? 50 : $0 }
        return (sk, d)
    }

    static func evaluate(ltf: [Candle], htf: [Candle],
                         tick: Double, brick: Double) -> Result {
        var out = Result()
        guard htf.count >= 30, ltf.count >= 25 else {
            out.notes.append("not enough candles")
            return out
        }
        let (skH, dH) = stochastic(htf)
        let (skL, dL) = stochastic(ltf)
        let k = skH.last!
        let dd = dH.last!
        let obH = k >= 75 && dd >= 75
        let osH = k <= 25 && dd <= 25
        if k > dd, !obH {
            out.htfState = "bull"; out.points["htf"] = 8
        } else if k > dd, obH {
            out.htfState = "bull-OB"; out.points["htf"] = 4
        } else if osH {
            out.htfState = "OS"; out.points["htf"] = 3
        } else if k < dd, !osH {
            out.htfState = "bear"; out.points["htf"] = 8
        } else if k < dd, osH {
            out.htfState = "bear-OS"; out.points["htf"] = 4
        } else {
            out.htfState = "flat"
        }

        // LTF reversal: slowK crosses %D within the last 5 candles,
        // made below OB / above OS (book Table 2.1)
        let searchStart = max(ltf.count - 5, 1)
        for j in searchStart..<ltf.count {
            if skL[j - 1] <= dL[j - 1], skL[j] > dL[j], skL[j] < 75 {
                let age = ltf.count - 1 - j
                out.points["ltf_reversal_long"] = age <= 1 ? 7 : 5
                if out.ltfReversalAge == nil { out.ltfReversalAge = age }
                break
            }
        }
        for j in searchStart..<ltf.count {
            if skL[j - 1] >= dL[j - 1], skL[j] < dL[j], skL[j] > 25 {
                let ageS = ltf.count - 1 - j
                out.points["ltf_reversal_short"] = ageS <= 1 ? 7 : 5
                if out.ltfReversalAge == nil { out.ltfReversalAge = ageS }
                break
            }
        }

        // Tr-1BH/L trigger + swing stop (book p.140)
        let sizeRef = brick > 0 ? brick : abs(ltf.last!.c - ltf.last!.o)
        let i = ltf.count - 1
        if (out.points["ltf_reversal_long"] ?? 0) > 0 {
            let entry = ltf[i].h + tick
            let swingLow = ltf[(ltf.count - 6)..<i].map(\.l).min() ?? ltf[i].l
            let stop = swingLow - tick
            let risk = entry - stop
            if risk > 0, risk <= 2 * sizeRef {
                out.points["trigger_long"] = 4
                out.points["stop_long"] = 3
                out.points["rr_long"] = 2
                if out.entry == nil {
                    out.entry = entry
                    out.stop = stop
                    out.trigger = String(
                        format: "LONG Tr-1BH: buy-stop %.6g, stop %.6g (1R %.6g)",
                        entry, stop, entry + risk)
                }
            }
        }
        if (out.points["ltf_reversal_short"] ?? 0) > 0 {
            let entry = ltf[i].l - tick
            let swingHigh = ltf[(ltf.count - 6)..<i].map(\.h).max() ?? ltf[i].h
            let stop = swingHigh + tick
            let risk = stop - entry
            if risk > 0, risk <= 2 * sizeRef {
                out.points["trigger_short"] = 4
                out.points["stop_short"] = 3
                out.points["rr_short"] = 2
                if out.entry == nil {
                    out.entry = entry
                    out.stop = stop
                    out.trigger = String(
                        format: "SHORT Tr-1BL: sell-stop %.6g, stop %.6g (1R %.6g)",
                        entry, stop, entry - risk)
                }
            }
        }
        if out.trigger != nil { out.points["plan"] = 1 }
        let ageText = out.ltfReversalAge.map(String.init) ?? "none"
        out.notes.append(String(
            format: "HTF %@ (K %.0f/D %.0f), LTF reversal age %@",
            out.htfState, k, dd, ageText))
        return out
    }

    static func pointsFor(_ result: Result, side: TradeDirection) -> Int {
        let suffix = side == .long ? "long" : "short"
        var total = result.points["htf"] ?? 0
        total += result.points["ltf_reversal_\(suffix)"] ?? 0
        total += result.points["trigger_\(suffix)"] ?? 0
        total += result.points["stop_\(suffix)"] ?? 0
        total += result.points["rr_\(suffix)"] ?? 0
        total += result.points["plan"] ?? 0
        return total
    }
}
