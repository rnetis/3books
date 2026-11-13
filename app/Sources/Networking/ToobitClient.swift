import Foundation

/// Async client for the public Toobit USDT-M futures REST endpoints.
/// No API keys — market data only. Endpoint map: docs/api-notes.md.
struct ToobitClient {

    static let base = URL(string: "https://api.toobit.com")!

    enum ToobitError: LocalizedError {
        case badStatus(Int)
        case badShape(String)

        var errorDescription: String? {
            switch self {
            case .badStatus(let code): return "Toobit HTTP \(code)"
            case .badShape(let what): return "Unexpected Toobit payload: \(what)"
            }
        }
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Core fetch

    private func fetch(path: String, query: [URLQueryItem]) async throws -> Data {
        var components = URLComponents(url: Self.base.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ToobitError.badShape("url") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("renko-toobit-scanner/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ToobitError.badStatus(http.statusCode)
        }
        return data
    }

    // MARK: - Endpoints

    /// GET /quote/v1/contract/ticker/24hr — all swap tickers (universe source).
    func tickers() async throws -> [Ticker24h] {
        let data = try await fetch(path: "quote/v1/contract/ticker/24hr", query: [])
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ToobitError.badShape("ticker array")
        }
        return array.compactMap { d in
            guard let symbol = d["s"] as? String,
                  let last = Double(d["c"] as? String ?? "") else { return nil }
            return Ticker24h(symbol: symbol,
                             last: last,
                             high: Double(d["h"] as? String ?? "") ?? 0,
                             low: Double(d["l"] as? String ?? "") ?? 0,
                             open: Double(d["o"] as? String ?? "") ?? 0,
                             baseVolume: Double(d["v"] as? String ?? "") ?? 0,
                             quoteVolume: Double(d["qv"] as? String ?? "") ?? 0,
                             openInterest: Double(d["op"] as? String ?? "") ?? 0,
                             changePct: Double(d["pcp"] as? String ?? "") ?? 0)
        }
    }

    /// GET /quote/v1/klines — Binance-style rows.
    /// [t, o, h, l, c, baseVol, 0, quoteVol, trades, takerBuyBase, takerBuyQuote]
    func klines(symbol: String, interval: String, limit: Int) async throws -> [Candle] {
        let data = try await fetch(path: "quote/v1/klines", query: [
            .init(name: "symbol", value: symbol),
            .init(name: "interval", value: interval),
            .init(name: "limit", value: String(limit)),
        ])
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[Any]] else {
            throw ToobitError.badShape("kline rows")
        }
        return rows.compactMap { row in
            guard row.count >= 9,
                  let t = row[0] as? Int64 ?? (row[0] as? NSNumber)?.int64Value,
                  let o = Self.str(row[1]), let h = Self.str(row[2]),
                  let l = Self.str(row[3]), let c = Self.str(row[4]),
                  let v = Self.str(row[5]) else { return nil }
            let qv = Self.str(row.count > 7 ? row[7] : nil) ?? 0
            let trades = (row[8] as? NSNumber)?.intValue ?? 0
            let tb = Self.str(row.count > 9 ? row[9] : nil) ?? 0
            return Candle(t: Int(t), o: o, h: h, l: l, c: c, v: v,
                          qv: qv, trades: trades, takerBuy: tb)
        }
    }

    /// GET /quote/v1/openInterest
    func openInterest(symbol: String) async throws -> Double {
        let data = try await fetch(path: "quote/v1/openInterest",
                                   query: [.init(name: "symbol", value: symbol)])
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["openInterestList"] as? [[String: Any]],
              let first = list.first,
              let size = first["size"] as? String else { return 0 }
        return Double(size) ?? 0
    }

    /// GET /api/v1/futures/fundingRate
    func fundingRate(symbol: String) async throws -> Double? {
        let data = try await fetch(path: "api/v1/futures/fundingRate",
                                   query: [.init(name: "symbol", value: symbol)])
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = list.first,
              let rate = first["rate"] as? String else { return nil }
        return Double(rate)
    }

    private static func str(_ any: Any?) -> Double? {
        if let s = any as? String { return Double(s) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }
}
