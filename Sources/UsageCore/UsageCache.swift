import Darwin
import Foundation

/// A subscription profile's quota as last read from the usage endpoint, and the plan its credentials named.
public struct UsageReading: Codable, Equatable, Sendable {
    public let plan: SubscriptionPlan
    public let snapshot: UsageSnapshot

    public init(plan: SubscriptionPlan, snapshot: UsageSnapshot) {
        self.plan = plan; self.snapshot = snapshot
    }

    private enum CodingKeys: String, CodingKey {
        case plan, fetchedAt, windows, extraUsageEnabled, extraUsagePercent
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // A plan that a newer Claudock knows reads as unknown rather than spoiling the reading.
        plan = SubscriptionPlan(rawValue: try values.decode(String.self, forKey: .plan)) ?? .unknown
        snapshot = UsageSnapshot(windows: try values.decode([UsageWindow].self, forKey: .windows),
                                 fetchedAt: try values.decode(Date.self, forKey: .fetchedAt),
                                 extraUsageEnabled: try values.decodeIfPresent(Bool.self, forKey: .extraUsageEnabled) ?? false,
                                 extraUsagePercent: try values.decodeIfPresent(Double.self, forKey: .extraUsagePercent))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(plan.rawValue, forKey: .plan)
        try values.encode(snapshot.fetchedAt, forKey: .fetchedAt)
        try values.encode(snapshot.windows, forKey: .windows)
        try values.encode(snapshot.extraUsageEnabled, forKey: .extraUsageEnabled)
        try values.encodeIfPresent(snapshot.extraUsagePercent, forKey: .extraUsagePercent)
    }
}

/// One profile in the usage cache: its last successful reading and its cooldown after HTTP 429.
public struct UsageCacheEntry: Codable, Equatable, Sendable {
    public var reading: UsageReading?
    /// When the usage endpoint may be asked again for this profile.
    public var retryAt: Date?
    /// HTTP 429s in a row; each doubles the next backoff. A success resets it.
    var rateLimits: Int

    init(reading: UsageReading? = nil, retryAt: Date? = nil, rateLimits: Int = 0) {
        self.reading = reading; self.retryAt = retryAt; self.rateLimits = rateLimits
    }

    private enum CodingKeys: String, CodingKey {
        case reading, retryAt, rateLimits
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        reading = try values.decodeIfPresent(UsageReading.self, forKey: .reading)
        retryAt = try values.decodeIfPresent(Date.self, forKey: .retryAt)
        rateLimits = try values.decodeIfPresent(Int.self, forKey: .rateLimits) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(reading, forKey: .reading)
        try values.encodeIfPresent(retryAt, forKey: .retryAt)
        if rateLimits > 0 { try values.encode(rateLimits, forKey: .rateLimits) }
    }
}

/// `~/Library/Application Support/Claudock/usage-cache.json`, shared by the app and every `claudock usage`: per
/// profile, keyed by its Claude credential service (`CredentialStore.serviceName`), the last successful reading
/// and the cooldown after HTTP 429. It holds plans, percentages, and times, never tokens, emails, or account IDs.
/// Writers hold `.usage-cache-lock` (see `UsageFetcher`), which also records when the last request finished, and
/// replace the file atomically (0600, fsync'd); readers need no lock. A file that is missing, unreadable, too large,
/// or not this version reads as empty and is replaced by the next write: the cache is never fatal.
public enum UsageCache {
    static let fileName = "usage-cache.json"
    static let lockName = ".usage-cache-lock"
    static let maximumBytes = 1_048_576
    static let maximumProfiles = 256
    /// At least this long between two requests to the usage endpoint.
    static let spacing: TimeInterval = 0.5
    /// A week-old reading describes windows that have all reset since; it is dropped.
    static let readingLifetime: TimeInterval = 7 * 86_400
    /// An ended cooldown keeps its count this long, so a 429 soon after it backs off further.
    static let countLifetime: TimeInterval = 86_400
    /// The longest cooldown Claudock sets (`UsageClient.retryDate`); a later `retryAt` is not trusted.
    static let longestCooldown: TimeInterval = 86_400
    /// Another process's clock may be this far ahead and its readings still count.
    static let clockSlack: TimeInterval = 60

    struct Contents: Codable, Equatable {
        var version = 1
        var profiles: [String: UsageCacheEntry] = [:]
    }

    static func key(for profile: Profile) -> String {
        CredentialStore.serviceName(for: profile)
    }

    /// What the dashboard can show before it asks Claude, by profile ID, for the profiles that read subscription usage:
    /// the cached reading unless it is dated implausibly far ahead of `now`, and the cooldown while it runs.
    public static func entries(for profiles: [Profile], home: String = NSHomeDirectory(), now: Date = Date()) -> [String: UsageCacheEntry] {
        let contents = read(home: home)
        var entries: [String: UsageCacheEntry] = [:]
        // Unresolved, Vertex, and Console profiles can share a credential service with a subscription profile that
        // once used the same folder; their rows show no subscription usage.
        for profile in profiles where profile.authKind == .subscription && profile.discoveryNote == nil && !profile.isVertex
            && !profile.configDirectory.isEmpty {
            guard var entry = contents.profiles[key(for: profile)] else { continue }
            if let reading = entry.reading, reading.snapshot.fetchedAt > now.addingTimeInterval(clockSlack) { entry.reading = nil }
            entry.retryAt = cooldown(entry, now: now)
            guard entry.reading != nil || entry.retryAt != nil else { continue }
            entries[profile.id] = entry
        }
        return entries
    }

    // MARK: Rules

    /// A reading fetched after `cutoff` (the start of a pass less its max age), and not implausibly far ahead.
    static func isCurrent(_ reading: UsageReading, since cutoff: Date, now: Date) -> Bool {
        reading.snapshot.fetchedAt > cutoff && reading.snapshot.fetchedAt <= now.addingTimeInterval(clockSlack)
    }

    /// The end of a cooldown that is still running at `now`.
    static func cooldown(_ entry: UsageCacheEntry, now: Date) -> Date? {
        guard let retryAt = entry.retryAt, retryAt > now, retryAt <= now.addingTimeInterval(longestCooldown + clockSlack) else { return nil }
        return retryAt
    }

    /// The cooldown after `rateLimits` HTTP 429s in a row without a usable Retry-After: one minute, doubling each
    /// time up to thirty, plus up to a quarter more at random so profiles limited together do not retry together.
    static func backoff(after rateLimits: Int, random: Double = Double.random(in: 0..<1)) -> TimeInterval {
        let base = min(1800, 60 * pow(2, Double(min(max(rateLimits, 1) - 1, 16))))
        return min(1800, base * (1 + min(max(random, 0), 1) / 4))
    }

    /// How long to wait before the next request so it starts `spacing` after the last one finished.
    static func pause(after lastRequest: Date?, now: Date, spacing: TimeInterval) -> TimeInterval {
        guard let lastRequest else { return 0 }
        // A last request in the future means the clock moved back: wait one spacing, not until then.
        return min(spacing, max(0, lastRequest.addingTimeInterval(spacing).timeIntervalSince(now)))
    }

    // MARK: Format

    static func encode(_ contents: Contents, now: Date) throws -> Data {
        var contents = pruned(contents, now: now)
        let data = try encoder.encode(contents)
        guard data.count > maximumBytes else { return data }
        // Keep the most recently used profiles that fit.
        var budget = maximumBytes - 256
        var kept: [String: UsageCacheEntry] = [:]
        for (key, entry) in contents.profiles.sorted(by: { lastUse($0.value) > lastUse($1.value) }) {
            let size = try encoder.encode([key: entry]).count
            guard size <= budget else { continue }
            budget -= size
            kept[key] = entry
        }
        contents.profiles = kept
        let fitted = try encoder.encode(contents)
        guard fitted.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        return fitted
    }

    /// The contents, or nil when the data is not a cache of this version. Entries with impossible values are dropped.
    static func decode(_ data: Data) -> Contents? {
        guard data.count <= maximumBytes, var contents = try? decoder.decode(Contents.self, from: data), contents.version == 1 else { return nil }
        contents.profiles = contents.profiles.filter { valid(key: $0.key, entry: $0.value) }
        return contents
    }

    static func pruned(_ contents: Contents, now: Date) -> Contents {
        var result = contents
        for (key, entry) in contents.profiles {
            var entry = entry
            if let reading = entry.reading, now.timeIntervalSince(reading.snapshot.fetchedAt) > readingLifetime { entry.reading = nil }
            if !(entry.retryAt.map { now.timeIntervalSince($0) < countLifetime } ?? false) {
                entry.retryAt = nil
                entry.rateLimits = 0
            }
            result.profiles[key] = entry.reading == nil && entry.retryAt == nil ? nil : entry
        }
        if result.profiles.count > maximumProfiles {
            let kept = result.profiles.sorted { lastUse($0.value) > lastUse($1.value) }.prefix(maximumProfiles)
            result.profiles = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        return result
    }

    private static func lastUse(_ entry: UsageCacheEntry) -> Date {
        max(entry.reading?.snapshot.fetchedAt ?? .distantPast, entry.retryAt ?? .distantPast)
    }

    private static func valid(key: String, entry: UsageCacheEntry) -> Bool {
        guard key.range(of: #"\AClaude Code-credentials(?:-[0-9a-f]{8})?\z"#, options: .regularExpression) != nil,
              entry.rateLimits >= 0 else { return false }
        guard let reading = entry.reading else { return true }
        return !reading.snapshot.windows.isEmpty
            && reading.snapshot.windows.allSatisfy { $0.percent.isFinite && $0.percent >= 0 }
            && (reading.snapshot.extraUsagePercent.map { $0.isFinite && $0 >= 0 } ?? true)
    }

    // MARK: Files

    static func file(home: String) -> URL {
        ProfileStore.directory(home: home).appendingPathComponent(fileName)
    }

    /// The cache, or empty contents when there is none or it cannot be used.
    static func read(home: String) -> Contents {
        let descriptor = open(file(home: home).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return Contents() }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_size <= maximumBytes else { return Contents() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return Contents() }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else { return Contents() }
        }
        return decode(data) ?? Contents()
    }

    /// Replaces the cache atomically. The caller holds the fetch lock.
    static func write(_ contents: Contents, home: String, now: Date) throws {
        let base = ProfileStore.directory(home: home)
        try ensureBase(base)
        let data = try encode(contents, now: now)
        let temporary = base.appendingPathComponent(".usage-cache-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        var renamed = false
        defer { if !renamed { unlink(temporary.path) } }
        let written = data.withUnsafeBytes { bytes -> Bool in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        // Close in every case, so a full disk does not leak a descriptor on each write.
        let synced = written && fchmod(descriptor, 0o600) == 0 && fsync(descriptor) == 0
        let closed = close(descriptor) == 0
        guard synced, closed else { throw CocoaError(.fileWriteUnknown) }
        guard rename(temporary.path, file(home: home).path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        renamed = true
        let directory = open(base.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if directory >= 0 { fsync(directory); close(directory) }
    }

    /// When the last request to the usage endpoint finished, in any process, as the lock's holder recorded it. It
    /// lives in the lock file, which only the holder writes, so a lost or unwritable cache does not lose it.
    static func lastRequest(lock descriptor: Int32) -> Date? {
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = pread(descriptor, &buffer, buffer.count, 0)
        guard count > 0, let text = String(bytes: buffer.prefix(count), encoding: .utf8),
              let seconds = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Records in the held lock file when a request finished.
    static func recordRequest(lock descriptor: Int32, at date: Date) {
        let text = String(format: "%.3f\n", locale: Locale(identifier: "en_US_POSIX"), date.timeIntervalSince1970)
        guard ftruncate(descriptor, 0) == 0 else { return }
        _ = Array(text.utf8).withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
    }

    /// The fetch lock beside the cache, opened but not locked; nil when it cannot be opened safely.
    static func openLock(home: String) -> Int32? {
        let base = ProfileStore.directory(home: home)
        guard (try? ensureBase(base)) != nil else { return nil }
        let descriptor = open(base.appendingPathComponent(lockName).path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == geteuid() else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    private static func ensureBase(_ base: URL) throws {
        var info = stat()
        if lstat(base.path, &info) != 0 {
            try? FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
            if mkdir(base.path, 0o700) != 0, errno != EEXIST { throw CocoaError(.fileWriteNoPermission) }
            guard lstat(base.path, &info) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else { throw CocoaError(.fileWriteNoPermission) }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestamps.string(from: date))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = timestamps.date(from: text) ?? wholeSeconds.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO 8601 time.")
            }
            return date
        }
        return decoder
    }()

    private static let timestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeSeconds = ISO8601DateFormatter()
}
