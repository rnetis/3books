import Foundation
import BackgroundTasks

/// Orchestrates the scan loop: universe → klines → SignalScorer → notifications.
/// Foreground: refresh every `scanIntervalSeconds`. Background: BGAppRefreshTask.
final class ScannerService: ObservableObject {

    static let backgroundTaskID = "com.renkotrader.scan"

    @Published var signals: [ScanSignal] = []
    @Published var universe: [Ticker24h] = []
    @Published var isScanning = false
    @Published var lastScan: Date?
    @Published var statusText = "idle"
    @Published var settings: ScanSettings {
        didSet { persistSettings() }
    }

    private let client = ToobitClient()
    private var tickSizes: [String: Double] = [:]
    private var lastNotified: [String: Date] = [:]
    private var scanTask: Task<Void, Never>?

    init() {
        settings = Self.loadSettings()
    }

    // MARK: - Settings persistence

    private static let settingsKey = "renkotrader.settings"

    static func loadSettings() -> ScanSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let s = try? JSONDecoder().decode(ScanSettings.self, from: data) else {
            return .default
        }
        return s
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    // MARK: - Scan loop

    func startForegroundLoop() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scanOnce()
                guard let self else { return }
                let seconds = UInt64(max(self.settings.scanIntervalSeconds, 30))
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    func stopForegroundLoop() {
        scanTask?.cancel()
        scanTask = nil
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskID)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - One scan pass

    func scanOnce(notify: Bool = true) async {
        guard !isScanning else { return }
        await MainActor.run {
            self.isScanning = true
            self.statusText = "loading universe…"
        }
        defer {
            Task { @MainActor in self.isScanning = false }
        }

        do {
            let tickers = try await client.tickers()
            let swaps = tickers
                .filter { $0.symbol.hasSuffix("-SWAP-USDT") }
                .sorted { $0.quoteVolume > $1.quoteVolume }
            await MainActor.run {
                self.universe = Array(swaps.prefix(self.settings.universeSize))
            }
            if tickSizes.isEmpty { await loadTickSizes() }

            var results: [ScanSignal] = []
            for ticker in swaps.prefix(settings.universeSize) {
                await MainActor.run {
                    self.statusText = "scanning \(ticker.symbol)…"
                }
                if let signal = await scanSymbol(ticker.symbol) {
                    results.append(signal)
                }
            }
            await MainActor.run {
                self.signals = results.sorted { $0.score > $1.score }
                self.lastScan = Date()
                self.statusText = "\(results.count) signals · \(Date().formatted(date: .omitted, time: .shortened))"
            }
            if notify { await fireNotifications(for: results) }
        } catch {
            await MainActor.run {
                self.statusText = "scan failed: \(error.localizedDescription)"
            }
        }
    }

    private func scanSymbol(_ symbol: String) async -> ScanSignal? {
        do {
            async let k1 = client.klines(symbol: symbol, interval: "1m", limit: 1000)
            async let k15 = client.klines(symbol: symbol, interval: "15m", limit: 200)
            let base = symbol.replacingOccurrences(of: "-SWAP-USDT", with: "USDT")
            let tick = tickSizes[base] ?? 1e-6
            let k1 = SignalScorer.dropPartial(try await k1, intervalMS: 60_000)
            let k15 = SignalScorer.dropPartial(try await k15, intervalMS: 900_000)
            return SignalScorer.scan(symbol: symbol, k1m: k1, k15m: k15,
                                     tick: tick, settings: settings)
        } catch {
            return nil
        }
    }

    private func loadTickSizes() async {
        struct Spec: Decodable {
            struct Filter: Decodable { let filterType: String; let tickSize: String? }
            struct Symbol: Decodable { let symbol: String; let filters: [Filter] }
            let symbols: [Symbol]
        }
        do {
            var components = URLComponents(url: ToobitClient.base
                .appendingPathComponent("api/v1/exchangeInfo"),
                resolvingAgainstBaseURL: false)!
            let (data, _) = try await URLSession.shared.data(from: components.url!)
            let specs = try JSONDecoder().decode(Spec.self, from: data)
            var map: [String: Double] = [:]
            for s in specs.symbols {
                for f in s.filters where f.filterType == "PRICE_FILTER" {
                    map[s.symbol] = Double(f.tickSize ?? "")
                }
            }
            tickSizes = map
        } catch {
            tickSizes = [:]
        }
    }

    // MARK: - Notifications with cooldown

    private func fireNotifications(for results: [ScanSignal]) async {
        let cooldown = TimeInterval(settings.cooldownMinutes * 60)
        let now = Date()
        var due: [ScanSignal] = []
        for signal in results where signal.notify {
            if let last = lastNotified[signal.cooldownKey], now.timeIntervalSince(last) < cooldown {
                continue
            }
            lastNotified[signal.cooldownKey] = now
            due.append(signal)
        }
        guard !due.isEmpty else { return }
        await MainActor.run {
            for signal in due {
                NotificationManager.shared.send(signal: signal, settings: settings)
            }
        }
    }
}
