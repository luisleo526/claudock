import Foundation

/// Synthetic preview data; no account, Keychain, filesystem, or network reads.
public enum DemoData {
    public static var profiles: [Profile] {
        ["personal", "studio", "weekend", "research"].map { Profile(command: "claude-" + $0, configDirectory: "/Users/demo/.claude-" + $0) }
    }
    public static func usage(index: Int) -> UsageSnapshot {
        let session = [23.0, 68, 7, 91][index]
        let week = [42.0, 81, 16, 64][index]
        let fable = [36.0, 92, 18, 73][index]
        return UsageSnapshot(windows: [
            UsageWindow(id: "session", title: "5-hour session", percent: session, resetsAt: Date().addingTimeInterval(Double(3600 + index * 1800))),
            UsageWindow(id: "weekly", title: "Weekly · all models", percent: week, resetsAt: Date().addingTimeInterval(Double(86_400 * (index + 1)))),
            UsageWindow(id: "fable", title: "Weekly · Fable", percent: fable, resetsAt: Date().addingTimeInterval(Double(86_400 * (index + 1))))
        ])
    }
    public static func analytics(days: Int) -> AnalyticsSnapshot {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let daily = (0..<days).map { offset in
            DailyTokens(day: calendar.date(byAdding: .day, value: offset - days + 1, to: today)!,
                        tokens: Int64([3_820_000, 6_450_000, 4_130_000, 8_720_000, 5_110_000, 2_940_000, 7_380_000][offset % 7]))
        }
        let sum = daily.reduce(Int64(0)) { $0 + $1.tokens }
        let totals = TokenTotals(input: sum / 5, output: sum / 10, cacheRead: sum * 6 / 10, cacheWrite: sum - sum / 5 - sum / 10 - sum * 6 / 10)
        let rows = profiles.enumerated().map { index, profile in
            let shares = [0.42, 0.31, 0.17, 0.10]
            let share = shares[index]
            return ProfileTokens(command: profile.command,
                                 tokens: TokenTotals(input: Int64(Double(totals.input) * share), output: Int64(Double(totals.output) * share),
                                                     cacheRead: Int64(Double(totals.cacheRead) * share), cacheWrite: Int64(Double(totals.cacheWrite) * share)), sessions: [12, 9, 5, 3][index])
        }
        let sessions = (0..<29).map { index in
            SessionRecord(sessionUUID: "00000000-0000-0000-0000-000000000000", profileCommand: profiles[index % 4].command,
                          filePath: "/demo/\(index).jsonl", projectPath: "/Users/demo/Projects/\(["orbit", "paperplane", "garden", "notes"][index % 4])",
                          title: ["orbit", "paperplane", "garden", "notes"][index % 4], modifiedAt: Date().addingTimeInterval(Double(-index * 4300)),
                          tokens: TokenTotals(input: 148_000, output: 47_000, cacheRead: 810_000, cacheWrite: 82_000), hasUsage: true)
        }
        return AnalyticsSnapshot(sessions: sessions, daily: daily, profiles: rows, totals: totals, truncated: false)
    }
}
