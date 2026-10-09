import Darwin
import Foundation

/// The Console credit ledger, `~/Library/Application Support/Claudock/api-credit.json`: per API-key profile
/// (by registry ID) the balance the user set, when (`asOf`), and the requests and adjustments counted since.
/// Every change takes `.api-credit-lock` exclusively and replaces the file atomically (0600, fsync'd), so
/// parallel launches append safely; reads share the lock. Entries from before `asOf` are pruned on every
/// write. It holds costs, models, session IDs, and times, never keys or prompts.
public enum APICreditStore {
    static let fileName = "api-credit.json"
    private static let maximumBytes = 32 * 1_048_576
    /// How long a read or change waits for another Claudock process.
    private static let lockWait: TimeInterval = 5
    /// A request at most this long before a session's `lastStartTime` still belongs to it.
    private static let startSlack: TimeInterval = 1
    /// A run that captured no event adopts only an entry that started this soon after the launch.
    private static let uncapturedStartWindow: TimeInterval = 10

    struct Ledger: Codable {
        var version = 1
        var profiles: [String: Account] = [:]
    }

    struct Account: Codable {
        var balanceUSD: Double
        var asOf: Date
        var requests: [APICreditRequest] = []
        var adjustments: [APICreditAdjustment] = []
    }

    public static func status(profile: Profile) throws -> APICreditStatus? {
        try status(profileID: profile.id, home: NSHomeDirectory())
    }

    /// Records `amount` as the profile's remaining credit now; spend from before now no longer counts.
    @discardableResult
    public static func setBalance(_ amount: Decimal, profile: Profile, now: Date = Date()) throws -> APICreditStatus {
        guard profile.authKind == .apiKey else { throw APICreditError.subscriptionProfile(profile.name) }
        return try setBalance(amount, profileID: profile.id, home: NSHomeDirectory(), now: now)
    }

    static func status(profileID: String, home: String) throws -> APICreditStatus? {
        try withLedger(home: home, exclusive: false) { ledger, _ in
            ledger.profiles[profileID].map(status)
        }
    }

    @discardableResult
    static func setBalance(_ amount: Decimal, profileID: String, home: String, now: Date) throws -> APICreditStatus {
        guard amount >= 0, amount <= APICreditAmount.maximum else { throw APICreditError.invalidAmount }
        // Millisecond precision, as stored.
        let asOf = Date(timeIntervalSince1970: (now.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
        return try withLedger(home: home, exclusive: true, replaceUnreadable: true) { ledger, changed in
            let account = Account(balanceUSD: double(amount), asOf: asOf)
            ledger.profiles[profileID] = account
            changed = true
            return status(account)
        }
    }

    /// Adds the requests not seen before and not older than the profile's `asOf`; returns how many.
    /// Without a credit set for the profile nothing is stored.
    @discardableResult
    static func record(_ requests: [APICreditRequest], profileID: String, home: String) throws -> Int {
        guard !requests.isEmpty else { return 0 }
        return try withLedger(home: home, exclusive: true, createIfMissing: false) { ledger, changed in
            guard var account = ledger.profiles[profileID] else { return 0 }
            var known = Set(account.requests.map(\.id))
            var added = 0
            for request in requests where request.at >= account.asOf && !known.contains(request.id) {
                account.requests.append(request)
                known.insert(request.id)
                added += 1
            }
            if added > 0 { ledger.profiles[profileID] = account; changed = true }
            return added
        }
    }

    /// Compares Claude Code's own session total in `.claude.json` (`claudeState`) with the requests captured for
    /// that session and records any shortfall as a `session-total` adjustment; never subtracts. An entry
    /// qualifies only when its `lastStartTime` falls inside this launch (`spawn`…`exit`) and after `asOf`:
    /// a resumed session restores its earlier cost and start time, so its total is not this launch's alone.
    /// It must also be a session this launch captured, or, when the launch captured nothing, the one entry
    /// that started within seconds of it. Re-checking the same session replaces its adjustment.
    @discardableResult
    static func reconcile(profileID: String, home: String, claudeState: Data, spawn: Date, exit: Date,
                          capturedSessions: Set<String>, now: Date) throws -> APICreditAdjustment? {
        let entries = sessionTotals(claudeState)
        guard !entries.isEmpty else { return nil }
        return try withLedger(home: home, exclusive: true, createIfMissing: false) { ledger, changed in
            guard var account = ledger.profiles[profileID] else { return nil }
            let started = entries.filter { $0.start >= spawn.addingTimeInterval(-startSlack) && $0.start <= exit && $0.start >= account.asOf }
            let chosen: [SessionTotal]
            if capturedSessions.isEmpty {
                let near = started.filter { $0.start <= spawn.addingTimeInterval(uncapturedStartWindow) }
                chosen = near.count == 1 ? near : []
            } else {
                chosen = started.filter { capturedSessions.contains($0.session) }
            }
            var result: APICreditAdjustment?
            for entry in chosen {
                let captured = account.requests.filter { $0.sessionID == entry.session && $0.at >= entry.start.addingTimeInterval(-startSlack) }
                    .reduce(Decimal(0)) { $0 + decimal($1.costUSD) }
                let missing = decimal(entry.lastCost) - captured
                let before = account.adjustments
                account.adjustments.removeAll { $0.sessionID == entry.session && $0.sessionStart == entry.start }
                // Below a billionth of a dollar is floating-point noise, not lost spend.
                if missing > Decimal(string: "0.000000001")! {
                    let adjustment = APICreditAdjustment(kind: "session-total", sessionID: entry.session, sessionStart: entry.start,
                                                         amountUSD: double(missing), lastCostUSD: entry.lastCost,
                                                         capturedUSD: double(captured), recordedAt: now)
                    account.adjustments.append(adjustment)
                    result = adjustment
                }
                if account.adjustments != before { changed = true }
            }
            if changed { ledger.profiles[profileID] = account }
            return result
        }
    }

    private struct SessionTotal {
        let session: String
        let start: Date
        let lastCost: Double
    }

    /// `projects[*]` entries of a `.claude.json` with a cost, a session, and a start time. The key is
    /// Claude Code's project root (a git root or the directory), so entries are matched by session.
    private static func sessionTotals(_ data: Data) -> [SessionTotal] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [String: Any] else { return [] }
        return projects.values.compactMap { value in
            guard let entry = value as? [String: Any], let session = entry["lastSessionId"] as? String, !session.isEmpty,
                  let cost = (entry["lastCost"] as? NSNumber)?.doubleValue, cost.isFinite, cost >= 0, cost < 1_000_000,
                  let start = (entry["lastStartTime"] as? NSNumber)?.doubleValue, start.isFinite, start > 0 else { return nil }
            // Same millisecond precision as stored ledger dates.
            return SessionTotal(session: session, start: Date(timeIntervalSince1970: start.rounded() / 1000), lastCost: cost)
        }
    }

    private static func status(_ account: Account) -> APICreditStatus {
        let requests = account.requests.filter { $0.at >= account.asOf }.reduce(Decimal(0)) { $0 + decimal($1.costUSD) }
        let adjustments = account.adjustments.filter { $0.sessionStart >= account.asOf }.reduce(Decimal(0)) { $0 + decimal($1.amountUSD) }
        return APICreditStatus(balance: decimal(account.balanceUSD), spent: requests + adjustments, asOf: account.asOf)
    }

    /// A Double's shortest decimal form, so 0.1 counts as exactly 0.1.
    static func decimal(_ value: Double) -> Decimal {
        Decimal(string: "\(value)", locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(value)
    }

    /// The Double nearest to a decimal; NSDecimalNumber's conversion can be off in the last digit.
    static func double(_ value: Decimal) -> Double {
        Double(value.description) ?? NSDecimalNumber(decimal: value).doubleValue
    }

    // MARK: File access

    private static func withLedger<T>(home: String, exclusive: Bool, createIfMissing: Bool = true, replaceUnreadable: Bool = false,
                                      _ operation: (inout Ledger, inout Bool) throws -> T) throws -> T {
        let base = ProfileStore.directory(home: home)
        let file = base.appendingPathComponent(fileName)
        var empty = Ledger(), unchanged = false
        // Nothing to read, and nothing to create for this operation.
        if !exclusive && !pathExists(file.path) { return try operation(&empty, &unchanged) }
        try ensureBase(base, create: exclusive && createIfMissing)
        guard pathExists(base.path) else { return try operation(&empty, &unchanged) }
        let descriptor = open(base.appendingPathComponent(".api-credit-lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw APICreditError.ledgerWriteFailed }
        defer { close(descriptor) }
        try lock(descriptor, exclusive: exclusive)
        defer { flock(descriptor, LOCK_UN) }
        var ledger: Ledger
        do { ledger = try read(file) ?? Ledger() }
        catch APICreditError.ledgerUnreadable where replaceUnreadable {
            moveAside(file, in: base)
            ledger = Ledger()
        }
        let existed = pathExists(file.path)
        var changed = false
        let result = try operation(&ledger, &changed)
        guard exclusive, changed, existed || createIfMissing else { return result }
        for (id, account) in ledger.profiles {
            var pruned = account
            pruned.requests.removeAll { $0.at < account.asOf }
            pruned.adjustments.removeAll { $0.sessionStart < account.asOf }
            ledger.profiles[id] = pruned
        }
        try write(ledger, to: file, in: base)
        return result
    }

    private static func lock(_ descriptor: Int32, exclusive: Bool) throws {
        let deadline = Date().addingTimeInterval(lockWait)
        while flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else { throw APICreditError.ledgerBusy }
            usleep(useconds_t.random(in: 2_000...10_000))
        }
    }

    private static func read(_ file: URL) throws -> Ledger? {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw APICreditError.ledgerUnreadable
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_size <= maximumBytes else { throw APICreditError.ledgerUnreadable }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw APICreditError.ledgerUnreadable }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else { throw APICreditError.ledgerUnreadable }
        }
        guard let ledger = try? decoder.decode(Ledger.self, from: data), ledger.version == 1,
              ledger.profiles.values.allSatisfy(valid) else { throw APICreditError.ledgerUnreadable }
        return ledger
    }

    private static func valid(_ account: Account) -> Bool {
        account.balanceUSD.isFinite && account.balanceUSD >= 0 && account.balanceUSD <= 1_000_000
            && account.requests.allSatisfy { $0.costUSD.isFinite && $0.costUSD >= 0 }
            && account.adjustments.allSatisfy { $0.amountUSD.isFinite && $0.amountUSD >= 0 }
    }

    private static func write(_ ledger: Ledger, to file: URL, in base: URL) throws {
        let data = try encoder.encode(ledger) + Data("\n".utf8)
        guard data.count <= maximumBytes else { throw APICreditError.ledgerFull }
        let temporary = base.appendingPathComponent(".api-credit-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw APICreditError.ledgerWriteFailed }
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
        guard written, fsync(descriptor) == 0, close(descriptor) == 0 else { throw APICreditError.ledgerWriteFailed }
        guard rename(temporary.path, file.path) == 0 else { throw APICreditError.ledgerWriteFailed }
        renamed = true
        let directory = open(base.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if directory >= 0 { fsync(directory); close(directory) }
    }

    /// Keeps an unreadable ledger as `api-credit.unreadable-<UTC time>.json` before starting a new one.
    private static func moveAside(_ file: URL, in base: URL) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        let stamp = formatter.string(from: Date())
        var target = base.appendingPathComponent("api-credit.unreadable-\(stamp).json")
        var attempt = 1
        while pathExists(target.path) {
            attempt += 1
            target = base.appendingPathComponent("api-credit.unreadable-\(stamp)-\(attempt).json")
        }
        rename(file.path, target.path)
    }

    private static func ensureBase(_ base: URL, create: Bool) throws {
        if !pathExists(base.path) {
            guard create else { return }
            try? FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
            if mkdir(base.path, 0o700) != 0, errno != EEXIST { throw APICreditError.ledgerWriteFailed }
        }
        var info = stat()
        guard lstat(base.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else {
            throw APICreditError.ledgerUnreadable
        }
    }

    private static func pathExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
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
            guard let date = timestamps.date(from: try container.decode(String.self)) else {
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
}
