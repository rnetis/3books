import SwiftUI

struct SettingsView: View {

    @EnvironmentObject var scanner: ScannerService
    @ObservedObject private var notifications = NotificationManager.shared

    var body: some View {
        NavigationStack {
            ZStack {
                TerminalTheme.background.ignoresSafeArea()
                Form {
                    notificationsSection
                    scoringSection
                    universeSection
                    timingSection
                    aboutSection
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.dark)
        }
    }

    private var notificationsSection: some View {
        Section("Notifications") {
            Toggle("Enabled", isOn: $scanner.settings.notificationsEnabled)
            Stepper("Notify at score ≥ \(scanner.settings.notifyThreshold)",
                    value: $scanner.settings.notifyThreshold, in: 50...95, step: 5)
            Stepper("Cooldown \(scanner.settings.cooldownMinutes) min per symbol",
                    value: $scanner.settings.cooldownMinutes, in: 5...60, step: 5)
            if !notifications.authorized {
                Button("Allow notifications") {
                    NotificationManager.shared.requestAuthorization()
                }
            }
            Button("Send test notification") {
                NotificationManager.shared.requestAuthorization()
                NotificationManager.shared.sendTest()
            }
        }
    }

    private var scoringSection: some View {
        Section("Brick engine") {
            Toggle("Fixed brick size", isOn: $scanner.settings.useFixedBrick)
            if scanner.settings.useFixedBrick {
                Stepper("brick = \(String(format: "%.2f", scanner.settings.fixedBrickPct))% of price",
                        value: $scanner.settings.fixedBrickPct, in: 0.02...1.0, step: 0.02)
            } else {
                Stepper("ATR(14) × \(String(format: "%.2f", scanner.settings.brickMultiplier))",
                        value: $scanner.settings.brickMultiplier, in: 0.1...2.0, step: 0.1)
            }
        }
    }

    private var universeSection: some View {
        Section("Universe (top liquidity)") {
            Stepper("Top \(scanner.settings.universeSize) by 24h quote volume",
                    value: $scanner.settings.universeSize, in: 10...50, step: 5)
        }
    }

    private var timingSection: some View {
        Section("Scan loop") {
            Stepper("Foreground refresh \(scanner.settings.scanIntervalSeconds)s",
                    value: $scanner.settings.scanIntervalSeconds, in: 30...300, step: 30)
            Button("Scan now") {
                Task { await scanner.scanOnce() }
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            VStack(alignment: .leading, spacing: 4) {
                Text("renko-toobit-scanner · on-device only").mono()
                Text("Wyckoff 30 / Renko 20 / Tape 25 / Miner 25. Educational tool — not financial advice. No orders are placed; you execute manually on Toobit.")
                    .mono()
                    .foregroundColor(TerminalTheme.dim)
            }
            .padding(.vertical, 4)
        }
    }
}
