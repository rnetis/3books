import SwiftUI
import BackgroundTasks

@main
struct RenkoTraderApp: App {

    @StateObject private var scanner = ScannerService()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Background app-refresh task: scan once while the app is suspended.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: ScannerService.backgroundTaskID,
                                        using: nil) { task in
            let scanner = ScannerService()
            Task {
                await scanner.scanOnce(notify: true)
                task.setTaskCompleted(success: true)
            }
            scanner.scheduleBackgroundRefresh()
        }
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                ScannerView()
                    .environmentObject(scanner)
                    .tabItem { Label("Scanner", systemImage: "chart.bar.fill") }
                SettingsView()
                    .environmentObject(scanner)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .onAppear {
                NotificationManager.shared.requestAuthorization()
                scanner.startForegroundLoop()
            }
            .onChange(of: scenePhase) { phase in
                switch phase {
                case .background:
                    scanner.scheduleBackgroundRefresh()
                default:
                    break
                }
            }
        }
    }
}
