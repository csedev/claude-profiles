import Foundation

/// One meter as the server reports it, with its reset time.
public struct LiveMeter: Sendable, Equatable, Identifiable {
    public let key: String
    public let title: String
    public let utilization: Double
    public let resetsAt: Date?

    public var id: String { key }

    public init(key: String, title: String, utilization: Double, resetsAt: Date?) {
        self.key = key
        self.title = title
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

public struct LiveUsage: Sendable, Equatable {
    public let meters: [LiveMeter]
    public let fetchedAt: Date

    public func meter(_ key: String) -> LiveMeter? { meters.first { $0.key == key } }
}

/// Fetches the full usage picture from `/api/oauth/usage`.
///
/// The local `plan-usage-history.json` persists only a fixed subset of windows
/// and no reset times. Per-model weekly windows — the "Weekly · Fable" row in
/// Claude's own popup — arrive in a `model_scoped` array whose labels are
/// supplied by the server, so they cannot be derived locally at all.
public enum UsageAPI {
    static let path = "/api/oauth/usage"
    /// `skip_spend=1` keeps polling from counting against the quota being polled.
    static let queryItems = [URLQueryItem(name: "skip_spend", value: "1")]

    /// Built with `URLComponents`, not `appending(path:)` — the latter treats the
    /// whole string as a path component and percent-encodes `?`, which turns a
    /// query string into part of the path and yields a 404.
    static func endpoint(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        return components.url!
    }

    public static var baseURL: URL {
        if let override = ProcessInfo.processInfo.environment["ANTHROPIC_BASE_URL"],
            let url = URL(string: override)
        {
            return url
        }
        return URL(string: "https://api.anthropic.com")!
    }

    /// Fixed windows, in the order worth showing.
    static let fixedWindows: [(key: String, title: String)] = [
        ("five_hour", "5-hour limit"),
        ("seven_day", "Weekly · all models"),
        ("seven_day_overage_included", "Weekly · incl. overage"),
        ("seven_day_opus", "Weekly · Opus"),
        ("seven_day_sonnet", "Weekly · Sonnet"),
        ("seven_day_oauth_apps", "Weekly · apps"),
        ("seven_day_cowork", "Weekly · Cowork"),
        ("seven_day_omelette", "Weekly · Omelette"),
    ]

    public enum APIError: Error, CustomStringConvertible {
        case noToken
        case http(Int, String)
        case malformed

        public var description: String {
            switch self {
            case .noToken:
                return "no usage token for this profile — run `claude-profiles token <label>`"
            case .http(let code, let body):
                return "usage request failed (HTTP \(code)): \(body.prefix(200))"
            case .malformed:
                return "could not parse the usage response"
            }
        }
    }

    /// Cheap check that a token is accepted at all, to separate "bad token"
    /// from "wrong endpoint or missing scope".
    public static func validate(token: String) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: endpoint("/api/oauth/validate"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (status, String(decoding: data, as: UTF8.self))
    }

    public static func fetch(token: String) async throws -> LiveUsage {
        var request = URLRequest(url: endpoint(path, query: queryItems))
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.malformed }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.malformed
        }
        return parse(root)
    }

    static func date(from any: Any?) -> Date? {
        if let seconds = any as? NSNumber {
            return Date(timeIntervalSince1970: seconds.doubleValue)
        }
        if let string = any as? String {
            return ISO8601DateFormatter().date(from: string)
        }
        return nil
    }

    static func meter(key: String, title: String, from any: Any?) -> LiveMeter? {
        guard let dict = any as? [String: Any],
            let utilization = (dict["utilization"] as? NSNumber)?.doubleValue
        else { return nil }
        return LiveMeter(
            key: key, title: title, utilization: utilization,
            resetsAt: date(from: dict["resets_at"] ?? dict["resetsAt"]))
    }

    /// Tolerant by design: unknown fixed windows are skipped, and `model_scoped`
    /// is additive — absent when the server has nothing to say, empty when it
    /// has nothing to report.
    static func parse(_ root: [String: Any]) -> LiveUsage {
        let limits = root["limits"] as? [String: Any] ?? root
        var meters: [LiveMeter] = []

        for (key, title) in fixedWindows {
            if let m = meter(key: key, title: title, from: limits[key]) { meters.append(m) }
        }

        // Per-model weekly windows. Labels come from the server — this is where
        // "Weekly · Fable" comes from, and why it cannot be hardcoded.
        if let scoped = limits["model_scoped"] as? [[String: Any]] {
            for entry in scoped {
                guard let name = entry["display_name"] as? String,
                    let utilization = (entry["utilization"] as? NSNumber)?.doubleValue
                else { continue }
                meters.append(
                    LiveMeter(
                        key: "model_scoped:\(name)", title: "Weekly · \(name)",
                        utilization: utilization,
                        resetsAt: date(from: entry["resets_at"])))
            }
        }

        if let extra = limits["extra_usage"] as? [String: Any],
            extra["is_enabled"] as? Bool == true,
            let utilization = (extra["utilization"] as? NSNumber)?.doubleValue
        {
            meters.append(
                LiveMeter(
                    key: "extra_usage", title: "Extra usage", utilization: utilization,
                    resetsAt: nil))
        }

        return LiveUsage(meters: meters, fetchedAt: .now)
    }
}
