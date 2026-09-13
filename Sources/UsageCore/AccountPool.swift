import Foundation

/// One pool belongs to one auto-launched Claude process. Affinity lasts for its
/// conversation; weighted random initial choice spreads independent launches.
actor AccountPool {
    struct Entry: Sendable {
        let profile: Profile
        var usage: UsageSnapshot?
        var blockedUntil: Date = .distantPast
        var active = 0
    }
    private var entries: [String: Entry] = [:]
    private var affinity: [String: String] = [:]
    private let randomUnit: @Sendable () -> Double

    init(randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) { self.randomUnit = randomUnit }

    func update(profiles: [Profile], usage: [String: UsageSnapshot]) {
        let ids = Set(profiles.map(\.id))
        entries = entries.filter { ids.contains($0.key) }
        for profile in profiles {
            var entry = entries[profile.id] ?? Entry(profile: profile)
            if let reading = usage[profile.id] { entry.usage = reading }
            entries[profile.id] = entry
        }
        affinity = affinity.filter { ids.contains($0.value) }
    }

    func select(model: String, conversation: String, excluding: Set<String>, hasRemoteState: Bool,
                now: Date = Date()) -> Profile? {
        // Session affinity is not proof that a remote resource belongs to that
        // account. Auto has no upload/ownership registry, so require a named
        // profile whenever the request references server-side resources.
        guard !hasRemoteState else { return nil }
        let candidates = entries.values.filter {
            !excluding.contains($0.profile.id) && $0.blockedUntil <= now &&
                Self.headroom($0.usage, model: model, now: now) > 0
        }
        let chosen: Entry?
        if let id = affinity[conversation], let sticky = candidates.first(where: { $0.profile.id == id }) {
            chosen = sticky
        } else {
            let ordered = candidates.sorted { $0.profile.command < $1.profile.command }
            let weights = ordered.map { Self.headroom($0.usage, model: model, now: now) / Double($0.active + 1) }
            var target = min(0.999999999, max(0, randomUnit())) * weights.reduce(0, +)
            var selected: Entry?
            for (entry, weight) in zip(ordered, weights) {
                target -= weight
                if target < 0 { selected = entry; break }
            }
            chosen = selected ?? ordered.last
        }
        guard let chosen else { return nil }
        entries[chosen.profile.id]?.active += 1
        affinity[conversation] = chosen.profile.id
        if affinity.count > 1024 { affinity = [conversation: chosen.profile.id] }
        return chosen.profile
    }

    func release(_ profile: Profile) {
        guard var entry = entries[profile.id] else { return }
        entry.active = max(0, entry.active - 1)
        entries[profile.id] = entry
    }
    func block(_ profile: Profile, until: Date) {
        guard var entry = entries[profile.id] else { return }
        entry.blockedUntil = max(entry.blockedUntil, until)
        entries[profile.id] = entry
    }

    static func headroom(_ usage: UsageSnapshot?, model: String, now: Date) -> Double {
        guard let usage, now.timeIntervalSince(usage.fetchedAt) < 600 else { return 50 }
        let family = ["fable", "opus", "sonnet", "haiku"].first { model.lowercased().contains($0) }
        let relevant = usage.windows.filter { window in
            let key = window.id.lowercased(), title = window.title.lowercased()
            let global = ["five_hour", "seven_day"].contains(key) || key.hasPrefix("session-") ||
                key.hasPrefix("weekly_all-") || title == "5-hour session" || title == "weekly · all models"
            return global || (family.map { title.contains($0) || key.contains($0) } ?? false)
        }
        return relevant.map { window in
            if let reset = window.resetsAt, reset <= now { return 100.0 }
            return max(0, 100 - window.percent)
        }.min() ?? 50
    }
}

enum BalancedRequest {
    static func details(_ request: LocalHTTPRequest) throws -> (model: String, remoteState: Bool) {
        if request.method == "GET" { return ("", false) }
        guard let root = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let model = root["model"] as? String, !model.isEmpty, model.utf8.count <= 256 else {
            throw MonitorError.unsupported("The request must be a JSON message with a model.")
        }
        func remote(_ value: Any, depth: Int = 0) -> Bool {
            if depth > 64 { return true }
            if let object = value as? [String: Any] {
                if object["file_id"] is String || object["container_id"] is String || object["previous_response_id"] is String { return true }
                if object["container"] is String || (object["container"] as? [String: Any])?["id"] is String { return true }
                return object.values.contains { remote($0, depth: depth + 1) }
            }
            if let array = value as? [Any] { return array.contains { remote($0, depth: depth + 1) } }
            return false
        }
        return (model, remote(root))
    }

    static func cooldown(status: Int, headers: [String: String], now: Date = Date()) -> Date? {
        guard status == 429 || status == 401 else { return nil }
        if status == 401 { return now.addingTimeInterval(300) }
        if let raw = headers["retry-after"], let seconds = Double(raw), seconds.isFinite {
            return now.addingTimeInterval(min(86_400, max(1, seconds)))
        }
        if let raw = headers["retry-after"] {
            let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
            format.timeZone = TimeZone(secondsFromGMT: 0); format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            if let date = format.date(from: raw) { return min(now.addingTimeInterval(86_400), max(now.addingTimeInterval(1), date)) }
        }
        return now.addingTimeInterval(60)
    }
}
