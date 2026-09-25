import Foundation
import Darwin

/// Per-file results of earlier session-log scans, so a scan reads only bytes appended since
/// the last one. It stores token counters, timestamps, message identifiers, and the working
/// directory each log reports; never message content. An unknown version or unreadable file
/// is ignored and rebuilt. Use one scan at a time per cache.
public final class SessionAnalyticsCache: @unchecked Sendable {
    static let version = 1
    /// Larger caches are kept in memory only; the next launch rebuilds them.
    static let maximumStoredBytes = 256 * 1_048_576

    /// Everything a scan needs from one complete log line to rebuild its period totals.
    struct Record: Equatable {
        static let invalidTimestamp: UInt8 = 1, invalidCounter: UInt8 = 2, missingCounter: UInt8 = 4, foundCounter: UInt8 = 8
        var flags: UInt8 = 0
        var time: Double = 0
        var tokens = TokenTotals()
        var identity: String?
    }

    /// One log file, parsed through its last complete line.
    struct Entry: Codable {
        var device: Int64
        var inode: UInt64
        var size: Int64
        var modified: Double
        /// Offset just past the last newline; later bytes are re-read on every scan.
        var offset: Int64
        /// Up to 64 bytes before `offset`, to detect a file rewritten in place.
        var fingerprint: Data
        var project: String?
        var parseFailure: Bool
        var longLine: Bool
        var records: Data
    }

    private struct Stored: Codable {
        let version: Int
        let entries: [String: Entry]
    }

    public let url: URL?
    private let lock = NSLock()
    private var entries: [String: Entry]?
    /// Bytes read from disk by the most recent scan (the snapshot's `scannedBytes` counts
    /// every byte the results cover, whether read now or earlier).
    public private(set) var lastReadBytes: Int64 = 0

    /// `url: nil` keeps the cache in memory for this process only.
    public init(url: URL?) { self.url = url }

    /// ~/Library/Caches/<bundle identifier or Claudock>/analytics-v1.bin
    public static var defaultURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches", isDirectory: true)
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Claudock", isDirectory: true)
            .appendingPathComponent("analytics-v\(version).bin")
    }

    func takeEntries() -> [String: Entry] {
        lock.lock(); defer { lock.unlock() }
        if let entries { return entries }
        guard let url, let data = try? Data(contentsOf: url),
              let stored = try? PropertyListDecoder().decode(Stored.self, from: data), stored.version == Self.version else { return [:] }
        return stored.entries
    }

    func store(_ updated: [String: Entry], changed: Bool, readBytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        let loadedFromDisk = entries == nil
        entries = updated
        lastReadBytes = readBytes
        guard let url, changed || loadedFromDisk && !FileManager.default.fileExists(atPath: url.path) else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(Stored(version: Self.version, entries: updated)),
              data.count <= Self.maximumStoredBytes else { return }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Written beside the target and renamed over it, never exposed with broader permissions.
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary.path, url.path) != 0 { try? FileManager.default.removeItem(at: temporary) }
    }

    static func pack(_ records: [Record]) -> Data {
        var data = Data()
        data.reserveCapacity(records.count * 64)
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        for record in records {
            append(record.flags)
            append(record.time.bitPattern.littleEndian)
            for value in [record.tokens.input, record.tokens.output, record.tokens.cacheRead, record.tokens.cacheWrite] { append(value.littleEndian) }
            let identity = Array((record.identity ?? "").utf8)
            append(record.identity == nil ? UInt16.max : UInt16(identity.count).littleEndian)
            data.append(contentsOf: identity)
        }
        return data
    }

    static func unpack(_ data: Data) -> [Record]? {
        var records: [Record] = []
        let ok: Bool = data.withUnsafeBytes { raw in
            var position = 0
            func read<T: FixedWidthInteger>(_: T.Type) -> T? {
                guard position + MemoryLayout<T>.size <= raw.count else { return nil }
                var value = T.zero
                withUnsafeMutableBytes(of: &value) { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[position..<(position + MemoryLayout<T>.size)])) }
                position += MemoryLayout<T>.size
                return T(littleEndian: value)
            }
            while position < raw.count {
                guard let flags = read(UInt8.self), let time = read(UInt64.self), let input = read(Int64.self), let output = read(Int64.self),
                      let cacheRead = read(Int64.self), let cacheWrite = read(Int64.self), let length = read(UInt16.self) else { return false }
                var identity: String?
                if length != UInt16.max {
                    guard position + Int(length) <= raw.count else { return false }
                    identity = String(decoding: UnsafeRawBufferPointer(rebasing: raw[position..<(position + Int(length))]), as: UTF8.self)
                    position += Int(length)
                }
                records.append(Record(flags: flags, time: Double(bitPattern: time),
                                      tokens: TokenTotals(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite), identity: identity))
            }
            return true
        }
        return ok ? records : nil
    }
}
