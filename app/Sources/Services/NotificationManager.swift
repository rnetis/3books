import Foundation
import UserNotifications

/// On-device local notifications (user-selected option). Fires when a scan
/// produces a setup whose score >= threshold, with a per-symbol+direction
/// cooldown so a hot symbol doesn't spam.
final class NotificationManager: NSObject, ObservableObject {

    static let shared = NotificationManager()
    @Published var authorized = false

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async { self.authorized = granted }
        }
    }

    func send(signal: ScanSignal, settings: ScanSettings) {
        guard settings.notificationsEnabled, signal.notify else { return }
        let content = UNMutableNotificationContent()
        let arrow = signal.direction == .long ? "▲" : "▼"
        content.title = "\(arrow) \(signal.direction.rawValue) \(signal.symbol) — score \(signal.score)"
        var body = ""
        if let e = signal.entry { body += String(format: "entry %.6g · ", e) }
        if let s = signal.stop { body += String(format: "stop %.6g", s) }
        if let t = signal.target1 { body += String(format: " · 1R %.6g", t) }
        content.body = body.isEmpty ? "Setup crossed your threshold." : body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: signal.identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        UNUserNotificationCenter.current().add(request)
    }

    func sendTest() {
        let content = UNMutableNotificationContent()
        content.title = "RenkoScanner test"
        content.body = "Notifications are working. Scan alerts will look like this."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

extension ScanSignal {
    /// Notification + cooldown identity.
    var identifier: String {
        "\(symbol)-\(direction.rawValue)-\(timestamp)"
    }
    var cooldownKey: String {
        "\(symbol)-\(direction.rawValue)"
    }
}
