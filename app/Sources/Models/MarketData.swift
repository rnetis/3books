import Foundation

// MARK: - Market data models (mirror of lab/engine.py)

struct Candle: Identifiable, Equatable {
    let t: Int          // open time, ms
    let o: Double
    let h: Double
    let l: Double
    let c: Double
    let v: Double       // base volume
    let qv: Double      // quote volume
    let trades: Int
    let takerBuy: Double

    var id: Int { t }
}

struct Ticker24h: Identifiable {
    let symbol: String          // e.g. "BTC-SWAP-USDT"
    let last: Double
    let high: Double
    let low: Double
    let open: Double
    let baseVolume: Double
    let quoteVolume: Double     // ranking key (24h)
    let openInterest: Double
    let changePct: Double       // 24h fraction (0.0359 = +3.59 %)

    var id: String { symbol }
}

// MARK: - Renko

struct Brick: Identifiable, Equatable {
    let direction: Int          // +1 up, -1 down
    let open: Double
    let close: Double
    let tOpen: Int
    var tClose: Int
    var volume: Double = 0
    var candles: Int = 0
    var low: Double = 0
    var high: Double = 0

    var id: Int { tOpen * 2 + (direction > 0 ? 1 : 0) }
}

// MARK: - Signal

enum TradeDirection: String, Codable {
    case long = "LONG"
    case short = "SHORT"
    case neutral = "NEUTRAL"
}

struct FactorBreakdown: Identifiable {
    let key: String             // A_wyckoff / B_renko / C_tape / D_miner
    let title: String
    let book: String
    let max: Int
    let long: Int
    let short: Int
    let notes: [String]

    var id: String { key }
}

struct ScanSignal: Identifiable {
    let symbol: String
    let price: Double
    let direction: TradeDirection
    let score: Int
    let scoreLong: Int
    let scoreShort: Int
    let notify: Bool
    let brickSize: Double
    let brickCount: Int
    let entry: Double?
    let stop: Double?
    let target1: Double?
    let target2: Double?
    let stretchTarget: Double?
    let breakdown: [FactorBreakdown]
    let phase: String
    let timestamp: Int

    var id: String { symbol }
    var risk: Double {
        guard let e = entry, let s = stop else { return 0 }
        return abs(e - s)
    }
    var riskReward: Double {
        guard let e = entry, let t = target1, risk > 0 else { return 0 }
        return abs(t - e) / risk
    }
}

// MARK: - Settings

struct ScanSettings: Codable, Equatable {
    var universeSize: Int = 30
    var notifyThreshold: Int = 75
    var brickMultiplier: Double = 0.5
    var useFixedBrick: Bool = false
    var fixedBrickPct: Double = 0.1      // % of price when fixed mode
    var scanIntervalSeconds: Int = 60
    var cooldownMinutes: Int = 15
    var notificationsEnabled: Bool = true

    static let `default` = ScanSettings()
}
