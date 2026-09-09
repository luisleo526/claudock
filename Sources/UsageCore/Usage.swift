import Foundation

public struct UsageWindow: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let percent: Double
    public let resetsAt: Date?
    public var fraction: Double { min(1, max(0, percent / 100)) }
    public init(id: String, title: String, percent: Double, resetsAt: Date?) {
        self.id = id; self.title = title; self.percent = percent; self.resetsAt = resetsAt
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let windows: [UsageWindow]
    public let fetchedAt: Date
    public let extraUsageEnabled: Bool
    public let extraUsagePercent: Double?
    public init(windows: [UsageWindow], fetchedAt: Date = Date(), extraUsageEnabled: Bool = false, extraUsagePercent: Double? = nil) {
        self.windows = windows; self.fetchedAt = fetchedAt
        self.extraUsageEnabled = extraUsageEnabled; self.extraUsagePercent = extraUsagePercent
    }
    public var peak: Double? { windows.map(\.percent).max() }

    /// The most constrained Fable allowance leads the account row, independent of API ordering.
    /// A numeric suffix is part of a model name (for example, Fable 5 or Fable5).
    public var featuredFableWindow: UsageWindow? {
        windows.filter {
            $0.title.range(of: #"\bFable(?:[ \t]*[0-9]+(?:\.[0-9]+)*)?\b"#,
                           options: [.caseInsensitive, .regularExpression]) != nil
        }.sorted { first, second in
            if first.percent != second.percent { return first.percent > second.percent }
            let firstTitle = first.title.lowercased(), secondTitle = second.title.lowercased()
            if firstTitle != secondTitle { return firstTitle < secondTitle }
            let firstReset = first.resetsAt ?? .distantFuture, secondReset = second.resetsAt ?? .distantFuture
            if firstReset != secondReset { return firstReset < secondReset }
            return first.id < second.id
        }.first
    }

    /// Keep the familiar session/week pair ahead of additional model limits.
    /// Excluding by identity ensures the featured window is never rendered a second time.
    public var secondaryWindows: [UsageWindow] {
        let featuredID = featuredFableWindow?.id
        func priority(_ window: UsageWindow) -> Int {
            if window.id == "five_hour" || window.id.hasPrefix("session-") || window.title == "5-hour session" { return 0 }
            if window.id == "seven_day" || window.id.hasPrefix("weekly_all-") || window.title == "Weekly · all models" { return 1 }
            return 2
        }
        return windows.enumerated().filter { $0.element.id != featuredID }.sorted {
            let firstPriority = priority($0.element), secondPriority = priority($1.element)
            return firstPriority == secondPriority ? $0.offset < $1.offset : firstPriority < secondPriority
        }.map(\.element)
    }

    /// Account selection follows the same priority as the display. Always label
    /// this reading with its actual title; API array position does not imply session.
    public var preferredLaunchWindow: UsageWindow? {
        featuredFableWindow ?? secondaryWindows.first
    }

    public static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MonitorError.invalidResponse }
        var windows: [UsageWindow] = []
        // New Claude responses describe model limits explicitly in this array.
        // Keep every scoped entry, including model names unknown to this app.
        if let limits = root["limits"] as? [[String: Any]] {
            for (index, entry) in limits.enumerated() {
                guard let value = number(entry["percent"]) else { continue }
                let kind = entry["kind"] as? String ?? "limit"
                let scope = entry["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                let surface = scope?["surface"] as? [String: Any]
                let label = model?["display_name"] as? String ?? surface?["display_name"] as? String
                let title: String
                switch kind {
                case "session": title = "5-hour session"
                case "weekly_all": title = "Weekly · all models"
                case "weekly_scoped": title = "Weekly · \(label ?? "model limit")"
                default: title = label ?? kind.replacingOccurrences(of: "_", with: " ").capitalized
                }
                windows.append(UsageWindow(id: "\(kind)-\(index)", title: title, percent: value, resetsAt: parseDate(entry["resets_at"])))
            }
        }
        let legacy = [("five_hour", "5-hour session", "session"), ("seven_day", "Weekly · all models", "weekly_all"),
                      ("seven_day_opus", "Weekly · Opus", "weekly_scoped"), ("seven_day_sonnet", "Weekly · Sonnet", "weekly_scoped"),
                      ("seven_day_oauth_apps", "Weekly · OAuth apps", "weekly_scoped"), ("seven_day_cowork", "Weekly · Cowork", "weekly_scoped")]
        for (key, title, kind) in legacy {
            guard !windows.contains(where: { kind == "weekly_scoped" ? $0.title == title : $0.id.hasPrefix(kind + "-") }),
                  let entry = root[key] as? [String: Any], let value = number(entry["utilization"]) else { continue }
            windows.append(UsageWindow(id: key, title: title, percent: value, resetsAt: parseDate(entry["resets_at"])))
        }
        guard !windows.isEmpty else { throw MonitorError.invalidResponse }
        let spend = root["spend"] as? [String: Any]
        let extra = root["extra_usage"] as? [String: Any]
        return UsageSnapshot(windows: windows, fetchedAt: now,
                             extraUsageEnabled: spend?["enabled"] as? Bool ?? extra?["is_enabled"] as? Bool ?? false,
                             extraUsagePercent: number(spend?["percent"]) ?? number(extra?["utilization"]))
    }
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              n.doubleValue >= 0, n.doubleValue < Double(Int.max) else { return nil }
        return n.doubleValue
    }
    public static func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }
}

import CoreFoundation

public enum MonitorError: Error, LocalizedError, Equatable, Sendable {
    case noCredentials, keychainLocked, expired, unauthorized, rateLimited(Date), network, invalidResponse, server(Int), unsupported(String)
    case loginRequired, permissionDenied, refreshBusy, credentialChanged, credentialWriteFailed, refreshFailed
    case refreshUncertain
    public var errorDescription: String? {
        switch self {
        case .noCredentials: return "Sign in to this Claude profile to see usage."
        case .keychainLocked: return "Keychain access unavailable. Unlock your Mac and refresh."
        case .expired: return "Access token expired. Open Claudock or this Claude profile to renew it."
        case .unauthorized: return "Claude rejected the renewed access token. Open this profile to check its login."
        case .loginRequired: return "This login cannot be renewed. Re-login in Manage profiles."
        case .permissionDenied: return "This credential cannot read usage. Check the account's access in Claude Code."
        case .refreshBusy: return "Credential update is busy. Try again or open this profile in Claude Code."
        case .credentialChanged: return "Credentials changed during renewal. Refresh to read the current login."
        case .credentialWriteFailed: return "Could not update saved credentials. Unlock Keychain or open this profile in Claude Code."
        case .refreshFailed: return "Could not renew the access token. Claudock will retry after a cooldown."
        case .refreshUncertain: return "The last renewal could not be confirmed. Open this profile in Claude Code or re-login."
        case .rateLimited: return "Claude is limiting requests. Refresh will retry after a cooldown."
        case .network: return "Cannot reach Claude. Keeping the last reading."
        case .invalidResponse: return "Claude returned an unrecognized usage response."
        case .server(let code): return "Claude usage is unavailable (HTTP \(code))."
        case .unsupported(let note): return note
        }
    }
}
