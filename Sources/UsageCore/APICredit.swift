import CryptoKit
import Darwin
import Foundation

public enum APICreditError: Error, LocalizedError, Equatable {
    case invalidAmount
    case subscriptionProfile(String)
    case ledgerUnreadable
    case ledgerUnavailable
    case ledgerBusy
    case ledgerFull
    case ledgerWriteFailed

    public var errorDescription: String? {
        switch self {
        case .invalidAmount: return "Enter the credit in US dollars, such as 200 or 187.42: from 0 to 1,000,000, with at most two decimals."
        case .subscriptionProfile(let name):
            return "'\(name)' is a Claude subscription profile. Credit applies only to Console API-key profiles added with 'claudock profile add NAME --api-key'."
        case .ledgerUnreadable:
            return "The Console credit ledger (api-credit.json in Claudock's Application Support folder) is unreadable. Set the credit again to start a new one; the unreadable file is kept beside it."
        case .ledgerUnavailable: return "Claudock could not read the Console credit ledger just now. Try again."
        case .ledgerBusy: return "Another Claudock process is updating the Console credit ledger. Try again."
        case .ledgerFull: return "The Console credit ledger is full. Set the credit again from the Console balance to start over."
        case .ledgerWriteFailed: return "Claudock could not save the Console credit ledger."
        }
    }
}

/// A prepaid Console balance typed by the user, in US dollars.
public enum APICreditAmount {
    public static let maximum: Decimal = 1_000_000

    /// Digits with up to two decimals, from 0 to 1,000,000. Signs, exponents, separators, currency
    /// symbols, and surrounding spaces are refused rather than guessed at.
    public static func parse(_ text: String) throws -> Decimal {
        guard text.utf8.count <= 32, text.range(of: #"\A[0-9]+(\.[0-9]{1,2})?\z"#, options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), value <= maximum else {
            throw APICreditError.invalidAmount
        }
        return value
    }
}

/// What is left of a profile's Console credit: the balance the user set at `asOf`, less the cost
/// Claude Code reported for each request since then in sessions Claudock started.
public struct APICreditStatus: Equatable, Sendable {
    public static let plan = "Console API"
    public let balance: Decimal
    public let spent: Decimal
    public let asOf: Date

    public init(balance: Decimal, spent: Decimal, asOf: Date) {
        self.balance = balance
        self.spent = spent
        self.asOf = asOf
    }

    public var left: Decimal { max(0, balance - spent) }
    /// Spent as a share of the balance; a zero balance counts as fully used.
    public var usedPercent: Decimal { balance > 0 ? spent / balance * 100 : 100 }
    /// The fill of a meter, from 0 to 1.
    public var fraction: Double { balance > 0 ? min(1, max(0, NSDecimalNumber(decimal: spent / balance).doubleValue)) : 1 }
    /// Below 10% of the balance or below $5 left.
    public var isLow: Bool {
        let remaining = balance - spent
        return remaining < 5 || remaining * 10 < balance
    }
    public var leftText: String { Self.dollars(left) }
    public var balanceText: String { Self.dollars(balance) }
    public var usedPercentText: String { Self.fixed(usedPercent, grouping: false) }
    /// The WINDOW column of `claudock usage`.
    public var usageWindow: String { "Credit · \(leftText) of \(balanceText) left" }

    static func dollars(_ value: Decimal) -> String { "$" + fixed(value, grouping: true) }

    /// Two decimals, rounded half up.
    static func fixed(_ value: Decimal, grouping: Bool) -> String {
        var input = value, rounded = Decimal()
        NSDecimalRound(&rounded, &input, 2, .plain)
        return (grouping ? groupedFormatter : plainFormatter).string(from: NSDecimalNumber(decimal: rounded)) ?? "\(rounded)"
    }

    private static let plainFormatter = formatter(grouping: false)
    private static let groupedFormatter = formatter(grouping: true)
    private static func formatter(grouping: Bool) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouping
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        formatter.minimumIntegerDigits = 1
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }
}

/// One Claude Code API request as Claude Code reported it. Holds no prompt, response, or credential.
public struct APICreditRequest: Codable, Equatable, Sendable {
    /// See `APICreditEvents`: a hash of the event's session, sequence, timestamp, and request IDs.
    public let id: String
    public let sessionID: String
    public let at: Date
    /// Claude Code's own `cost_usd`, kept exactly as received.
    public let costUSD: Double
    public let model: String?

    init(id: String, sessionID: String, at: Date, costUSD: Double, model: String?) {
        self.id = id
        self.sessionID = sessionID
        self.at = at
        self.costUSD = costUSD
        self.model = model
    }
}

/// Spend that Claude Code reported for a session in `.claude.json` beyond the events Claudock received.
public struct APICreditAdjustment: Codable, Equatable, Sendable {
    /// Always `session-total`: the session's `lastCost` was larger than its captured requests.
    public let kind: String
    public let sessionID: String
    /// The session's `lastStartTime`; with `sessionID`, it identifies the adjustment.
    public let sessionStart: Date
    public let amountUSD: Double
    public let lastCostUSD: Double
    public let capturedUSD: Double
    public let recordedAt: Date
}

/// Reads Claude Code's OpenTelemetry log export (OTLP/HTTP JSON, `claude_code.api_request` events).
///
/// An event's identity is the SHA-256 of its `session.id`, `event.sequence`, `event.timestamp` (or
/// `timeUnixNano`), `request_id`, and `client_request_id`, joined with U+001F, absent fields empty. A
/// batch that an exporter sends again therefore adds nothing. Records of other events, and
/// `api_request` records without a session, a time, or a valid non-negative cost, are ignored.
public enum APICreditEvents {
    public static func requests(fromOTLPJSON data: Data) -> [APICreditRequest] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resources = root["resourceLogs"] as? [[String: Any]] else { return [] }
        var result: [APICreditRequest] = []
        for resource in resources {
            for scope in resource["scopeLogs"] as? [[String: Any]] ?? [] {
                for record in scope["logRecords"] as? [[String: Any]] ?? [] {
                    if let request = request(record) { result.append(request) }
                }
            }
        }
        return result
    }

    private static func request(_ record: [String: Any]) -> APICreditRequest? {
        guard let list = record["attributes"] as? [[String: Any]] else { return nil }
        var attributes: [String: [String: Any]] = [:]
        for item in list {
            if let key = item["key"] as? String, let value = item["value"] as? [String: Any] { attributes[key] = value }
        }
        let body = (record["body"] as? [String: Any])?["stringValue"] as? String
        guard string(attributes["event.name"]) == "api_request" || body == "claude_code.api_request" else { return nil }
        guard let session = string(attributes["session.id"]), !session.isEmpty, let cost = cost(attributes) else { return nil }
        let timestamp = string(attributes["event.timestamp"])
        let nanoseconds = unixNanoseconds(record["timeUnixNano"]) ?? unixNanoseconds(record["observedTimeUnixNano"])
        guard let at = timestamp.flatMap(parseTimestamp) ?? nanoseconds.map({ Date(timeIntervalSince1970: Double($0) / 1e9) }) else { return nil }
        let identity = [session, integer(attributes["event.sequence"]).map(String.init) ?? "",
                        timestamp ?? nanoseconds.map(String.init) ?? "",
                        string(attributes["request_id"]) ?? "", string(attributes["client_request_id"]) ?? ""]
        let id = SHA256.hash(data: Data(identity.joined(separator: "\u{1F}").utf8)).map { String(format: "%02x", $0) }.joined()
        return APICreditRequest(id: id, sessionID: session, at: at, costUSD: cost, model: string(attributes["model"]))
    }

    /// `cost_usd` when present, which must then be valid; otherwise `cost_usd_micros`.
    private static func cost(_ attributes: [String: [String: Any]]) -> Double? {
        let value: Double?
        if let cost = attributes["cost_usd"] { value = number(cost) }
        else { value = integer(attributes["cost_usd_micros"]).map { Double($0) / 1_000_000 } }
        guard let value, value.isFinite, value >= 0, value < 1_000_000 else { return nil }
        return value
    }

    private static func string(_ value: [String: Any]?) -> String? { value?["stringValue"] as? String }

    /// OTLP JSON writes 64-bit integers as numbers or as decimal strings.
    private static func integer(_ value: [String: Any]?) -> Int64? {
        guard let raw = value?["intValue"] else { return nil }
        if let text = raw as? String { return Int64(text) }
        guard let number = raw as? NSNumber, !isBoolean(number), number.doubleValue.rounded() == number.doubleValue,
              abs(number.doubleValue) < 9e15 else { return nil }
        return number.int64Value
    }

    private static func number(_ value: [String: Any]) -> Double? {
        if let raw = value["doubleValue"] {
            guard let number = raw as? NSNumber, !isBoolean(number) else { return nil }
            return number.doubleValue
        }
        return integer(value).map(Double.init)
    }

    private static func unixNanoseconds(_ raw: Any?) -> Int64? {
        let value: Int64?
        if let text = raw as? String { value = Int64(text) }
        else if let number = raw as? NSNumber, !isBoolean(number) { value = number.int64Value }
        else { value = nil }
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func isBoolean(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

    private static let fractionalTimestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let wholeTimestamps = ISO8601DateFormatter()

    private static func parseTimestamp(_ text: String) -> Date? {
        fractionalTimestamps.date(from: text) ?? wholeTimestamps.date(from: text)
    }
}

/// How an API-key launch gets Claude Code to report each request to Claudock.
public enum APICreditCapture {
    /// Short, so a killed Claude Code loses at most about a second of unexported requests.
    public static let exportIntervalMilliseconds = 1000
    public static let managedSettingsFiles = ["/Library/Application Support/ClaudeCode/managed-settings.json"]

    /// The launch environment with every inherited `OTEL_*` variable and `CLAUDE_CODE_ENABLE_TELEMETRY`
    /// replaced by log export to the loopback receiver's `path`. Metrics and traces get no exporter.
    public static func environment(_ base: [String: String], port: UInt16, path: String) -> [String: String] {
        var result = base.filter { !isTelemetryKey($0.key) }
        result["CLAUDE_CODE_ENABLE_TELEMETRY"] = "1"
        result["OTEL_LOGS_EXPORTER"] = "otlp"
        result["OTEL_EXPORTER_OTLP_PROTOCOL"] = "http/json"
        result["OTEL_EXPORTER_OTLP_LOGS_PROTOCOL"] = "http/json"
        result["OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"] = "http://127.0.0.1:\(port)\(path)"
        result["OTEL_LOGS_EXPORT_INTERVAL"] = String(exportIntervalMilliseconds)
        return result
    }

    public struct Override: Equatable, Sendable {
        public let file: String
        public let key: String
    }

    /// Settings `env` entries that Claude Code applies over the launch environment and that could send its
    /// events elsewhere: the profile's own settings, the project's in the working directory, and managed
    /// settings. Unreadable or invalid files are skipped; this only informs a warning.
    public static func overridingSettings(configDirectory: String, workingDirectory: String,
                                          managedSettings: [String] = managedSettingsFiles) -> [Override] {
        let files = [configDirectory + "/settings.json", configDirectory + "/settings.local.json",
                     workingDirectory + "/.claude/settings.json", workingDirectory + "/.claude/settings.local.json"] + managedSettings
        return files.flatMap { file -> [Override] in
            guard let data = BoundedFile.read(file, limit: 1_048_576),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let environment = object["env"] as? [String: Any] else { return [] }
            return environment.keys.filter(isTelemetryKey).sorted().map { Override(file: file, key: $0) }
        }
    }

    static func isTelemetryKey(_ key: String) -> Bool { key.hasPrefix("OTEL_") || key == "CLAUDE_CODE_ENABLE_TELEMETRY" }
}

/// Reads a small regular file without following a FIFO or device, or nil.
enum BoundedFile {
    static func read(_ path: String, limit: Int) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit else { return nil }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { return nil }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= limit else { return nil }
        }
    }
}
