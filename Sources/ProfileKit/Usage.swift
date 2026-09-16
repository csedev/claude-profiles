import Foundation

/// Quota windows the desktop app tracks.
///
/// The complete set, decoded from the app bundle's server contract:
///
///     ["five_hour", "seven_day", "seven_day_opus", "seven_day_oauth_apps",
///      "seven_day_cowork", "seven_day_omelette", "omelette_promotional",
///      "seven_day_sonnet"]                     // plus "xu" = extra usage
///
/// Note there is **no Fable window**. Only Opus and Sonnet get their own weekly
/// meters; everything else — Fable included — counts against the general
/// `seven_day` limit. ("Omelette" is an internal product codename, not a model.)
public enum UsageWindow: String, CaseIterable, Sendable {
    case fiveHour = "fh"
    case sevenDay = "sd"
    case sevenDayOpus = "so"
    case sevenDaySonnet = "sn"
    case sevenDayOAuthApps = "oa"
    case sevenDayCowork = "cw"
    case sevenDayOmelette = "om"
    case omelettePromotional = "op"
    case extraUsage = "xu"

    public var title: String {
        switch self {
        case .fiveHour: "5-hour limit"
        case .sevenDay: "Weekly limit"
        case .sevenDayOpus: "Weekly (Opus)"
        case .sevenDaySonnet: "Weekly (Sonnet)"
        case .sevenDayOAuthApps: "Weekly (apps)"
        case .sevenDayCowork: "Weekly (Cowork)"
        case .sevenDayOmelette: "Weekly (Omelette)"
        case .omelettePromotional: "Omelette (promo)"
        case .extraUsage: "Extra usage"
        }
    }

    /// Always shown, even at zero, because their absence is itself information.
    public static var primary: [UsageWindow] { [.fiveHour, .sevenDay] }

    /// Shown only once the account actually reports them. Model- and
    /// feature-specific meters stay absent for most accounts, so rendering them
    /// unconditionally would be a wall of permanent zeroes.
    public static var secondary: [UsageWindow] {
        allCases.filter { !primary.contains($0) }
    }
}

public struct UsageSample: Sendable, Equatable {
    public let date: Date
    public let org: String?
    public let values: [UsageWindow: Double]

    public func value(_ window: UsageWindow) -> Double? { values[window] }
}

public struct UsageHistory: Sendable, Equatable {
    public let samples: [UsageSample]

    public var latest: UsageSample? { samples.last }
    public var org: String? { samples.last?.org }

    public var span: TimeInterval {
        guard let first = samples.first, let last = samples.last else { return 0 }
        return last.date.timeIntervalSince(first.date)
    }

    public func current(_ window: UsageWindow) -> Double? { latest?.value(window) }

    /// Secondary windows this account actually reports.
    public var reportedSecondaryWindows: [UsageWindow] {
        UsageWindow.secondary.filter { latest?.value($0) != nil }
    }

    public func peak(_ window: UsageWindow) -> Double? {
        samples.compactMap { $0.value(window) }.max()
    }

    /// Values over the trailing interval, for a sparkline.
    public func series(_ window: UsageWindow, since: TimeInterval = 86_400 * 7)
        -> [(date: Date, value: Double)]
    {
        let cutoff = Date().addingTimeInterval(-since)
        return samples.compactMap { s in
            guard s.date >= cutoff, let v = s.value(window) else { return nil }
            return (s.date, v)
        }
    }

    /// Best-effort reset estimate: the most recent point where this window
    /// dropped sharply is treated as the last reset. The app does not record
    /// reset timestamps, so this is inference, not ground truth.
    public func lastReset(_ window: UsageWindow, dropThreshold: Double = 20) -> Date? {
        let points = samples.compactMap { s -> (Date, Double)? in
            guard let v = s.value(window) else { return nil }
            return (s.date, v)
        }
        guard points.count > 1 else { return nil }
        for i in stride(from: points.count - 1, to: 0, by: -1)
        where points[i - 1].1 - points[i].1 >= dropThreshold {
            return points[i].0
        }
        return nil
    }
}

public enum UsageReader {
    /// Reads a profile's local usage history.
    ///
    /// The desktop app maintains this file itself, per user-data-dir, with about
    /// 30 days of samples. Reading it needs no network call, no token, and no
    /// Keychain access — which is why usage aggregation stays compatible with
    /// this tool never touching credentials.
    public static func read(at url: URL) -> UsageHistory? {
        guard let data = try? Data(contentsOf: url),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = obj["samples"] as? [[String: Any]]
        else { return nil }

        let samples: [UsageSample] = raw.compactMap { entry in
            guard let t = entry["t"] as? Double else { return nil }
            var values: [UsageWindow: Double] = [:]
            if let u = entry["u"] as? [String: Any] {
                for (key, value) in u {
                    guard let window = UsageWindow(rawValue: key),
                        let number = value as? NSNumber
                    else { continue }
                    values[window] = number.doubleValue
                }
            }
            return UsageSample(
                date: Date(timeIntervalSince1970: t / 1000),
                org: entry["org"] as? String, values: values)
        }.sorted { $0.date < $1.date }

        return samples.isEmpty ? nil : UsageHistory(samples: samples)
    }

    public static func read(for profile: Profile) -> UsageHistory? {
        read(at: profile.paths.usageHistoryFile)
    }

    /// The unmanaged default profile's usage.
    public static func readDefault() -> UsageHistory? {
        read(at: Paths.defaultElectronDir.appending(path: "plan-usage-history.json"))
    }
}
