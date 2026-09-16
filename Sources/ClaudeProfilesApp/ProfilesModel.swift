import Foundation
import ProfileKit
import SwiftUI

/// One row in the menu: a profile, its account, its usage, and whether it is up.
struct ProfileRow: Identifiable, Equatable {
    let id: UUID
    let label: String
    let email: String?
    let seatTier: String?
    let isRunning: Bool
    let usage: UsageHistory?
    let projectCount: Int?
    /// The unmanaged default profile cannot be launched or renamed by this tool.
    let isDefault: Bool

    var fiveHour: Double? { usage?.current(.fiveHour) }
    var weekly: Double? { usage?.current(.sevenDay) }

    /// A model- or feature-specific meter this account reports.
    struct ExtraWindow: Identifiable, Equatable {
        let window: UsageWindow
        let value: Double
        var id: String { window.rawValue }
    }

    /// Meters beyond the two headline ones, only when this account reports them.
    var extraWindows: [ExtraWindow] {
        guard let usage else { return [] }
        return usage.reportedSecondaryWindows.compactMap { window in
            usage.current(window).map { ExtraWindow(window: window, value: $0) }
        }
    }
}

@MainActor
@Observable
final class ProfilesModel {
    private(set) var rows: [ProfileRow] = []
    private(set) var sessions: [SessionRecord] = []

    /// Mirrors `SMAppService` state. This must be STORED, not computed:
    /// `@Observable` tracks property access, and a computed property that reads
    /// an external framework gives it nothing to invalidate — so the checkbox
    /// never redrew even though registration had succeeded.
    private(set) var launchesAtLogin = false
    private(set) var loginItemStatus = ""
    private(set) var loginItemNeedsApproval = false
    private(set) var lastRefresh: Date?
    var errorMessage: String?

    private var timer: Timer?
    private var lastSessionScan: Date?
    private let alerts = UsageAlerts()

    /// The app rewrites usage roughly every few minutes; polling faster than
    /// that just burns wakeups for identical bytes.
    private let refreshInterval: TimeInterval = 60

    func start() {
        alerts.requestAuthorization()
        LoginItem.logDiagnostics()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let (identity, fingerprint) = ProfileStore.defaultProfile()
        var built: [ProfileRow] = [
            ProfileRow(
                id: ProfileStore.defaultPseudoID,
                label: "Default",
                email: identity?.email,
                seatTier: identity?.seatTier,
                isRunning: Launcher.isDefaultRunning,
                usage: UsageReader.readDefault(),
                projectCount: fingerprint?.projects,
                isDefault: true)
        ]

        for profile in ProfileStore.all() {
            built.append(
                ProfileRow(
                    id: profile.id,
                    label: profile.label,
                    email: profile.identity?.email,
                    seatTier: profile.identity?.seatTier,
                    isRunning: Launcher.isRunning(profile),
                    usage: UsageReader.read(for: profile),
                    projectCount: profile.fingerprint?.projects,
                    isDefault: false))
        }

        rows = built
        // Scanning transcript heads across every profile takes well under a
        // second, but there is no reason to do it on every usage tick.
        if sessions.isEmpty || lastRefresh == nil
            || Date().timeIntervalSince(lastSessionScan ?? .distantPast) > 300
        {
            sessions = Array(SessionIndex.all(limit: 60).prefix(8))
            lastSessionScan = .now
        }
        refreshLoginItemState()
        lastRefresh = .now
        alerts.evaluate(rows)
    }

    /// Opens the window that owns a session. Cloud sessions are stamped with
    /// the account that created them, so there is exactly one right window.
    func reveal(_ session: SessionRecord) {
        guard let profileID = session.profileID,
            let row = rows.first(where: { $0.id == profileID })
        else { return }
        launch(row)
    }

    func launch(_ row: ProfileRow) {
        if row.isDefault {
            // The default profile is Claude's own state: launch it with no
            // environment overrides, exactly as opening it from the Dock would.
            do { try Launcher.launchOrFocusDefault() } catch {
                errorMessage = String(describing: error)
            }
            refresh()
            return
        }
        guard let profile = ProfileStore.load(id: row.id) else { return }
        do {
            if Launcher.isRunning(profile) {
                // Already up — bring it forward rather than starting a second copy.
                focus(profile)
            } else {
                try Launcher.launch(profile)
            }
            refresh()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func focus(_ profile: Profile) {
        let pids = Set(Launcher.runningPIDs(profile))
        for app in NSWorkspace.shared.runningApplications
        where pids.contains(app.processIdentifier) {
            app.activate()
            return
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
            errorMessage = nil
        } catch {
            errorMessage = "login item: \(error.localizedDescription)"
        }
        LoginItem.logDiagnostics()
        refreshLoginItemState()
    }

    func refreshLoginItemState() {
        let status = LoginItem.status
        launchesAtLogin = status == .enabled
        loginItemNeedsApproval = status == .requiresApproval
        loginItemStatus = LoginItem.describe(status)
    }

    func openLoginItemSettings() { LoginItem.openSystemSettings() }

    /// Worst-case usage across every account, for the menu bar title.
    var headline: String {
        let weeklies = rows.compactMap(\.weekly)
        guard let worst = weeklies.max() else { return "—" }
        return "\(Int(worst.rounded()))%"
    }
}
