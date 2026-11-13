import SwiftUI

/// Main scanner screen: ranked signals from the live Toobit USDT-M universe.
struct ScannerView: View {

    @EnvironmentObject var scanner: ScannerService

    var body: some View {
        NavigationStack {
            ZStack {
                TerminalTheme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    statusBar
                    if scanner.signals.isEmpty {
                        emptyState
                    } else {
                        signalList
                    }
                }
            }
            .navigationTitle("RenkoScanner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await scanner.scanOnce() }
                    } label: {
                        if scanner.isScanning {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(scanner.isScanning)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(scanner.statusText)
                .mono()
                .foregroundColor(TerminalTheme.dim)
            Text("universe: top \(scanner.settings.universeSize) by 24h quote volume · threshold \(scanner.settings.notifyThreshold)")
                .mono()
                .foregroundColor(TerminalTheme.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 40))
                .foregroundColor(TerminalTheme.grid)
            Text("No signals yet")
                .mono()
                .foregroundColor(TerminalTheme.dim)
            Text("Tap ↻ to run the first scan.")
                .mono()
                .foregroundColor(TerminalTheme.dim)
            Spacer()
        }
    }

    private var signalList: some View {
        List {
            ForEach(grouped.keys.sorted(), id: \.self) { key in
                Section(key) {
                    ForEach(grouped[key] ?? []) { signal in
                        NavigationLink(destination: SignalDetailView(signal: signal)) {
                            SignalRow(signal: signal)
                        }
                        .listRowBackground(TerminalTheme.panel)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(TerminalTheme.background)
    }

    private var grouped: [String: [ScanSignal]] {
        Dictionary(grouping: scanner.signals.filter { $0.direction != .neutral }) {
            $0.direction == .long ? "▲ LONG setups" : "▼ SHORT setups"
        }
        .merging(["— neutral / stand-aside": scanner.signals.filter { $0.direction == .neutral }]) { a, b in a + b }
    }
}

struct SignalRow: View {
    let signal: ScanSignal

    var body: some View {
        HStack(spacing: 10) {
            Text("\(signal.score)")
                .font(.system(.title3, design: .monospaced).bold())
                .foregroundColor(TerminalTheme.scoreColor(signal.score))
                .frame(width: 44, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(signal.symbol.replacingOccurrences(of: "-SWAP-USDT", with: ""))
                    .font(.system(.body, design: .monospaced).bold())
                    .foregroundColor(TerminalTheme.directionColor(signal.direction))
                if let warn = signal.breakdown.first(where: { $0.key == "C_tape" })?.notes.first,
                   signal.direction == .neutral {
                    Text(warn).mono().foregroundColor(TerminalTheme.dim)
                } else {
                    Text(factorText)
                        .mono()
                        .foregroundColor(TerminalTheme.dim)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.6g", signal.price))
                    .mono()
                    .foregroundColor(.white)
                Text(signal.direction == .neutral ? "—" : "phase \(signal.phase)")
                    .mono()
                    .foregroundColor(TerminalTheme.dim)
            }
        }
        .padding(.vertical, 2)
    }

    private var factorText: String {
        func points(_ key: String) -> Int {
            signal.breakdown.first { $0.key == key }?.long ?? 0
        }
        return "A\(points("A_wyckoff"))·B\(points("B_renko"))·C\(points("C_tape"))·D\(points("D_miner"))"
    }
}
