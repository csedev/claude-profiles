import Foundation
import ProfileKit
import ServiceManagement
import UserNotifications

/// Notifies when an account crosses a usage threshold.
///
/// The weekly window is the one worth interrupting someone for: the 5-hour
/// window refills on its own within an afternoon, but exhausting the weekly
/// allowance shapes the rest of your week.
@MainActor
final class UsageAlerts {
    /// Ascending. A crossing fires once; dropping below re-arms it.
    static let thresholds: [Double] = [80, 95]

    private var lastLevel: [UUID: Double] = [:]
    private var authorized = false

    func requestAuthorization() {
        // Only a bundled app with an identifier has a notification center.
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert]) { [weak self] granted, _ in
                Task { @MainActor in self?.authorized = granted }
            }
    }

    func evaluate(_ rows: [ProfileRow]) {
        guard authorized else { return }
        for row in rows {
            guard let weekly = row.weekly else { continue }
            let previous = lastLevel[row.id] ?? 0
            lastLevel[row.id] = weekly

            // Fire only on an upward crossing, so a steady 85% stays quiet.
            for threshold in Self.thresholds where previous < threshold && weekly >= threshold {
                notify(
                    title: "\(row.label) at \(Int(weekly.rounded()))% weekly",
                    body: row.email ?? "Weekly limit is filling up.")
            }
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Launch-at-login, via the modern `SMAppService` API.
@MainActor
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    /// macOS can accept a registration but hold it pending user approval, which
    /// is a success that still reads as "off".
    static var needsApproval: Bool { status == .requiresApproval }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "not registered"
        case .enabled: "enabled"
        case .requiresApproval: "waiting for approval in System Settings"
        case .notFound: "not found — the app bundle is not where macOS expects it"
        @unknown default: "unknown (\(status.rawValue))"
        }
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Written at launch so failures are diagnosable without a debugger.
    static func logDiagnostics() {
        let lines = [
            "bundlePath: \(Bundle.main.bundlePath)",
            "bundleID: \(Bundle.main.bundleIdentifier ?? "nil")",
            "status: \(describe(status)) (raw \(status.rawValue))",
        ]
        try? Journal.append(
            event: "login-item", profile: nil, detail: lines.joined(separator: " | "))
    }
}
