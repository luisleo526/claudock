import Foundation
import CoreFoundation
import Darwin

public struct TokenTotals: Equatable, Sendable {
    public var input: Int64
    public var output: Int64
    public var cacheRead: Int64
    public var cacheWrite: Int64
    public init(input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }
    public var total: Int64 { Self.sum(Self.sum(input, output), Self.sum(cacheRead, cacheWrite)) }
    static func sum(_ a: Int64, _ b: Int64) -> Int64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int64.max : value
    }
    mutating func add(_ other: TokenTotals) {
        input = Self.sum(input, other.input); output = Self.sum(output, other.output)
        cacheRead = Self.sum(cacheRead, other.cacheRead); cacheWrite = Self.sum(cacheWrite, other.cacheWrite)
    }
    mutating func mergeMaximum(_ other: TokenTotals) {
        input = max(input, other.input); output = max(output, other.output)
        cacheRead = max(cacheRead, other.cacheRead); cacheWrite = max(cacheWrite, other.cacheWrite)
    }
}

public struct SessionRecord: Identifiable, Equatable, Sendable {
    public var id: String { profileCommand + "\u{0}" + filePath }
    public let sessionUUID: String
    public let profileCommand: String
    public let filePath: String
    public let projectPath: String?
    public let title: String
    public let modifiedAt: Date
    /// Tokens contributed after deduplication against copied/forked sessions.
    public let tokens: TokenTotals
    public let hasUsage: Bool
}

public struct DailyTokens: Identifiable, Equatable, Sendable {
    public var id: Date { day }
    public let day: Date
    public let tokens: Int64
}

public struct ProfileTokens: Identifiable, Equatable, Sendable {
    public var id: String { command }
    public let command: String
    public let tokens: TokenTotals
    public let sessions: Int
}

public struct AnalyticsSnapshot: Equatable, Sendable {
    public let sessions: [SessionRecord]
    public let daily: [DailyTokens]
    public let profiles: [ProfileTokens]
    public let totals: TokenTotals
    /// At least one eligible file/line was unreadable, invalid, or beyond scan limits.
    public let truncated: Bool
    public let scannedFiles: Int
    public let eligibleFiles: Int
    public let scannedBytes: Int64
    public let subagentTokens: TokenTotals
    public init(sessions: [SessionRecord], daily: [DailyTokens], profiles: [ProfileTokens], totals: TokenTotals,
                truncated: Bool, scannedFiles: Int? = nil, eligibleFiles: Int? = nil, scannedBytes: Int64 = 0,
                subagentTokens: TokenTotals = TokenTotals()) {
        self.sessions = sessions; self.daily = daily; self.profiles = profiles; self.totals = totals
        self.truncated = truncated; self.scannedFiles = scannedFiles ?? sessions.count
        self.eligibleFiles = eligibleFiles ?? sessions.count; self.scannedBytes = scannedBytes
        self.subagentTokens = subagentTokens
    }
    public var hasSharedHistory: Bool {
        profiles.contains { $0.command == SessionAnalytics.sharedProfileCommand }
            || sessions.contains { $0.profileCommand == SessionAnalytics.sharedProfileCommand }
    }
}

public enum SessionAnalytics {
    public static let sharedProfileCommand = "shared-history"
    // Bounds apply to local metadata only. No credentials, API calls, or transcript contents leave this scanner.
    static let maximumFiles = 50_000
    static let maximumDirectoryEntries = 400_000
    static let maximumLineBytes = 32 * 1_048_576
    static let maximumFileBytes = 512 * 1_048_576
    static let maximumTotalBytes = 8 * 1_073_741_824
    static let maximumMessages = 250_000
    static let maximumSeconds: TimeInterval = 120

    private struct File {
        let url: URL
        let profile: String
        let root: String
        let modified: Date
        let created: Date
        let parentSessionPath: String?
        var isSubagent: Bool { parentSessionPath != nil }
        var project: String?
        var hasUsage = false
        var sessionID: String { url.deletingPathExtension().lastPathComponent }
    }
    private struct Message {
        var tokens: TokenTotals
        var date: Date
        var owner: Int
        var isSubagent: Bool
    }
    private final class RootCursor {
        let root: URL
        let command: String
        let directories: [URL]
        var nextDirectory = 0
        var enumerator: FileManager.DirectoryEnumerator?
        var currentParentSessionPath: String?
        var subagentDirectories: [(url: URL, parentPath: String)] = []
        var exhausted = false
        init(root: URL, command: String, directories: [URL]) {
            self.root = root; self.command = command; self.directories = directories
        }
    }

    public static func scan(profiles: [Profile], since: Date) -> AnalyticsSnapshot {
        scan(profiles: profiles, since: since, now: Date())
    }

    // A frozen upper bound supports reproducible audits while active sessions keep writing.
    // With a cache, unchanged log prefixes are not read again; results are the same as a full scan.
    public static func scan(profiles: [Profile], since: Date, now: Date, cache: SessionAnalyticsCache? = nil) -> AnalyticsSnapshot {
        let started = ProcessInfo.processInfo.systemUptime
        var truncated = false
        var files: [File] = []
        var seenPaths = Set<String>()
        var entries = 0
        let manager = FileManager.default
        func timedOut() -> Bool { ProcessInfo.processInfo.systemUptime - started >= maximumSeconds }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .creationDateKey]
        func list(_ url: URL) -> [URL] {
            // Enumerator is lazy and limited to one directory level, unlike contentsOfDirectory's unbounded array.
            guard let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                      options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles],
                                                      errorHandler: { _, _ in truncated = true; return false }) else { return [] }
            var result: [URL] = []
            while let entry = enumerator.nextObject() as? URL {
                entries += 1
                if entries > maximumDirectoryEntries || timedOut() { truncated = true; break }
                result.append(entry)
            }
            return result.sorted { $0.path < $1.path }
        }
        var rootProfiles: [String: Set<String>] = [:]
        for profile in profiles where !profile.configDirectory.isEmpty {
            // Claude profiles often deliberately link projects to one common history directory.
            // Resolve the explicitly selected projects root, preserving credential path identity.
            let selected = URL(fileURLWithPath: profile.configDirectory).appendingPathComponent("projects", isDirectory: true)
            guard let resolved = realpath(selected.path, nil) else { continue }
            let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            free(resolved)
            guard safeDirectory(root) else { continue }
            rootProfiles[root.path, default: []].insert(profile.command)
        }
        let cursors = rootProfiles.keys.sorted().map { path in
            let root = URL(fileURLWithPath: path, isDirectory: true)
            let commands = rootProfiles[path]!
            let command = commands.count > 1 ? sharedProfileCommand : commands.first!
            return RootCursor(root: root, command: command, directories: list(root))
        }
        func nextFile(_ cursor: RootCursor) -> File? {
            while !timedOut() && entries <= maximumDirectoryEntries {
                if let enumerator = cursor.enumerator {
                    guard let file = enumerator.nextObject() as? URL else { cursor.enumerator = nil; continue }
                    entries += 1
                    if entries > maximumDirectoryEntries { truncated = true; return nil }
                    guard let info = try? file.resourceValues(forKeys: keys), info.isSymbolicLink != true else { continue }
                    if let parentPath = cursor.currentParentSessionPath, info.isDirectory == true,
                       file.lastPathComponent == "workflows", file.deletingLastPathComponent().lastPathComponent == "subagents",
                       safeDirectory(file) {
                        for workflow in list(file) where workflow.lastPathComponent.range(of: "^wf_[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil {
                            if safeDirectory(workflow) { cursor.subagentDirectories.append((workflow, parentPath)) }
                        }
                        continue
                    }
                    if cursor.currentParentSessionPath == nil, info.isDirectory == true,
                       UUID(uuidString: file.lastPathComponent) != nil {
                        let subagents = file.appendingPathComponent("subagents", isDirectory: true)
                        if safeDirectory(subagents) {
                            let parentPath = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".jsonl").path
                            cursor.subagentDirectories.append((subagents, parentPath))
                        }
                        continue
                    }
                    guard file.pathExtension == "jsonl", info.isRegularFile == true,
                          let modified = info.contentModificationDate,
                          seenPaths.insert(file.path).inserted else { continue }
                    return File(url: file, profile: cursor.command, root: cursor.root.path,
                                modified: modified, created: info.creationDate ?? modified,
                                parentSessionPath: cursor.currentParentSessionPath)
                }
                let directory: URL
                if let nested = cursor.subagentDirectories.popLast() {
                    directory = nested.url
                    cursor.currentParentSessionPath = nested.parentPath
                } else {
                    guard cursor.nextDirectory < cursor.directories.count else { cursor.exhausted = true; return nil }
                    directory = cursor.directories[cursor.nextDirectory]
                    cursor.nextDirectory += 1
                    cursor.currentParentSessionPath = nil
                }
                guard safeDirectory(directory) else { continue }
                cursor.enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
                                                       options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles],
                                                       errorHandler: { _, _ in truncated = true; return false })
                if cursor.enumerator == nil { truncated = true }
            }
            truncated = true
            return nil
        }
        // Collect one file per root per round so one large account does not exhaust the file cap.
        collection: while cursors.contains(where: { !$0.exhausted }) {
            for cursor in cursors where !cursor.exhausted {
                if files.count >= maximumFiles || entries > maximumDirectoryEntries || timedOut() {
                    truncated = true; break collection
                }
                if let file = autoreleasepool(invoking: { nextFile(cursor) }) { files.append(file) }
            }
        }
        // Also interleave reads, prioritizing recent sessions within each independent root.
        let groupedFiles = Dictionary(grouping: files, by: \.root).mapValues { group in
            group.sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.url.path < $1.url.path }
        }
        files.removeAll(keepingCapacity: true)
        let roots = groupedFiles.keys.sorted()
        for offset in 0..<(groupedFiles.values.map(\.count).max() ?? 0) {
            for root in roots {
                if let group = groupedFiles[root], offset < group.count { files.append(group[offset]) }
            }
        }
        let preciseDate = ISO8601DateFormatter(); preciseDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wholeDate = ISO8601DateFormatter(); wholeDate.formatOptions = [.withInternetDateTime]
        func date(_ value: Any?) -> Date? {
            guard let text = value as? String else { return nil }
            return preciseDate.date(from: text) ?? wholeDate.date(from: text)
        }
        func olderOwner(_ lhs: Int, _ rhs: Int) -> Bool {
            if files[lhs].created != files[rhs].created { return files[lhs].created < files[rhs].created }
            return files[lhs].url.path < files[rhs].url.path
        }
        var messages: [String: Message] = [:]
        var scannedCommands = Set<String>()
        var scannedFiles = 0
        var totalBytes = 0
        var readBytes: Int64 = 0
        let cached = cache?.takeEntries() ?? [:]
        var kept: [String: SessionAnalyticsCache.Entry] = [:]
        var cacheChanged = false
        let usageKey = Data("\"usage\"".utf8)
        let unicodeEscape = Data("\\u".utf8)
        typealias Record = SessionAnalyticsCache.Record
        struct FileState {
            var project: String?
            var parseFailure = false
            var longLine = false
            var records: [Record] = []
        }
        // Parsing depends only on the file's bytes, so its result can be cached; the period
        // and the current time are applied when records are replayed below.
        func parse(_ data: Data, isTail: Bool, into state: inout FileState) {
            guard !data.isEmpty else { return }
            // Large progress/tool/content-only records dominate the real history's bytes.
            // An assistant usage object must contain this key; Unicode-escaped keys fall
            // back to JSON parsing, as do small records and initial project metadata.
            if state.project != nil, data.count > 4_096,
               data.range(of: usageKey) == nil, data.range(of: unicodeEscape) == nil { return }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // A live writer may leave an unfinished final line at the frozen boundary.
                // It has no complete usage record yet and must not become a fabricated total.
                if !isTail { state.parseFailure = true }
                return
            }
            if state.project == nil, let cwd = object["cwd"] as? String,
               cwd.hasPrefix("/"), cwd.utf8.count <= 4_096,
               cwd.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                state.project = cwd
            }
            guard object["type"] as? String == "assistant", let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return }
            var record = Record()
            defer { state.records.append(record) }
            guard let timestamp = date(object["timestamp"]) else { record.flags |= Record.invalidTimestamp; return }
            record.time = timestamp.timeIntervalSinceReferenceDate
            var counters = [Int64]()
            for name in ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"] {
                guard let value = usage[name] else { counters.append(0); record.flags |= Record.missingCounter; continue }
                guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                      n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue.rounded(.down) == n.doubleValue,
                      n.decimalValue <= Decimal(Int64.max) else { record.flags |= Record.invalidCounter; return }
                record.flags |= Record.foundCounter; counters.append(n.int64Value)
            }
            record.tokens = TokenTotals(input: counters[0], output: counters[1], cacheRead: counters[2], cacheWrite: counters[3])
            if let id = nonempty(message["id"]) { record.identity = "message:" + id }
            else if let id = nonempty(object["requestId"]) { record.identity = "request:" + id }
            else if let id = nonempty(object["uuid"]) { record.identity = "record:" + id }
        }
        func replay(_ record: Record, file index: Int) {
            guard record.flags & Record.invalidTimestamp == 0 else { truncated = true; return }
            let timestamp = Date(timeIntervalSinceReferenceDate: record.time)
            guard timestamp <= now else {
                // Entries after an audit's frozen upper bound are simply outside its period.
                if timestamp > Date() { truncated = true }
                return
            }
            guard timestamp >= since else { return }
            guard record.flags & Record.invalidCounter == 0 else { truncated = true; return }
            guard record.flags & Record.foundCounter != 0 else { return }
            // Available counters remain useful, but absent fields are not proof of zero use.
            if record.flags & Record.missingCounter != 0 { truncated = true }
            guard let identity = record.identity else { truncated = true; return }
            files[index].hasUsage = true
            if var existing = messages[identity] {
                existing.tokens.mergeMaximum(record.tokens)
                existing.date = min(existing.date, timestamp)
                if olderOwner(index, existing.owner) { existing.owner = index }
                existing.isSubagent = existing.isSubagent || files[index].isSubagent
                messages[identity] = existing
            } else if messages.count < maximumMessages {
                messages[identity] = Message(tokens: record.tokens, date: timestamp, owner: index, isSubagent: files[index].isSubagent)
            } else { truncated = true }
        }
        for index in files.indices {
            if timedOut() || totalBytes >= maximumTotalBytes { truncated = true; break }
            // O_NOFOLLOW plus fstat excludes symlink replacements, devices, directories, and FIFOs.
            let fd = open(files[index].url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { truncated = true; continue }
            var stat = Darwin.stat()
            guard fstat(fd, &stat) == 0, stat.st_mode & S_IFMT == S_IFREG else { close(fd); truncated = true; continue }
            // Freeze each file's byte boundary. Never chase an actively growing transcript,
            // and skip an oversized file rather than treating its prefix as its full total.
            guard stat.st_size >= 0, stat.st_size <= Int64(maximumFileBytes) else { close(fd); truncated = true; continue }
            let initialSize = Int(stat.st_size)
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            let path = files[index].url.path
            let modified = Double(stat.st_mtimespec.tv_sec) + Double(stat.st_mtimespec.tv_nsec) / 1_000_000_000
            func bytes(before offset: Int) -> Data {
                let count = min(64, offset)
                guard count > 0 else { return Data() }
                var buffer = [UInt8](repeating: 0, count: count)
                let read = pread(fd, &buffer, count, off_t(offset - count))
                readBytes += Int64(max(0, read))
                return read == count ? Data(buffer) : Data()
            }
            var state = FileState()
            var fileBytes = 0
            var resumed: SessionAnalyticsCache.Entry?
            // Resume after the last complete line of an earlier scan when the file is the
            // same inode, was not rewritten in place, and the budget covers all of it.
            if let entry = cached[path], entry.device == Int64(stat.st_dev), entry.inode == UInt64(stat.st_ino),
               entry.offset <= Int64(initialSize), !(entry.size == Int64(initialSize) && entry.modified != modified),
               totalBytes + initialSize <= maximumTotalBytes, bytes(before: Int(entry.offset)) == entry.fingerprint,
               let records = SessionAnalyticsCache.unpack(entry.records) {
                state = FileState(project: entry.project, parseFailure: entry.parseFailure, longLine: entry.longLine, records: records)
                resumed = entry
                fileBytes = Int(entry.offset)
                totalBytes += fileBytes
            }
            var completeOffset = fileBytes
            var line = Data()
            var skippingLongLine = false
            do {
                if fileBytes > 0 { try handle.seek(toOffset: UInt64(fileBytes)) }
                // Each chunk and its parsed records are autoreleased Foundation objects. This runs
                // on a thread whose pool drains only when the whole scan ends, so drain per chunk;
                // otherwise a multi-gigabyte history leaves hundreds of megabytes of dirty memory.
                while fileBytes < initialSize && totalBytes < maximumTotalBytes && !timedOut() {
                    let more = try autoreleasepool { () throws -> Bool in
                        let capacity = min(262_144, initialSize - fileBytes, maximumTotalBytes - totalBytes)
                        let chunk = try handle.read(upToCount: capacity) ?? Data()
                        scannedCommands.insert(files[index].profile)
                        guard !chunk.isEmpty else { return false }
                        let chunkOffset = fileBytes
                        fileBytes += chunk.count; totalBytes += chunk.count; readBytes += Int64(chunk.count)
                        // libc scans bytes in bulk; generic Data collection iteration is expensive
                        // when real histories contain several gigabytes of progress/tool records.
                        chunk.withUnsafeBytes { raw in
                            guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                            var start = 0
                            while start < raw.count {
                                let newline = memchr(bytes.advanced(by: start), 10, raw.count - start)
                                let end = newline.map { Int(bitPattern: $0) - Int(bitPattern: bytes) } ?? raw.count
                                if !skippingLongLine {
                                    if line.count + end - start <= maximumLineBytes {
                                        line.append(bytes.advanced(by: start), count: end - start)
                                    } else { truncated = true; line.removeAll(keepingCapacity: true); skippingLongLine = true }
                                }
                                if newline != nil {
                                    if skippingLongLine { state.longLine = true } else { parse(line, isTail: false, into: &state) }
                                    line.removeAll(keepingCapacity: true); skippingLongLine = false
                                    start = end + 1
                                    completeOffset = chunkOffset + start
                                } else { break }
                            }
                        }
                        return true
                    }
                    if !more { break }
                }
                if fileBytes < initialSize { truncated = true }
                else {
                    scannedFiles += 1
                    scannedCommands.insert(files[index].profile)
                    if var entry = resumed, entry.offset == Int64(completeOffset) {
                        // No new complete line: keep the stored records as they are.
                        cacheChanged = cacheChanged || entry.size != Int64(initialSize) || entry.modified != modified
                        entry.size = Int64(initialSize); entry.modified = modified
                        kept[path] = entry
                    } else {
                        cacheChanged = true
                        kept[path] = SessionAnalyticsCache.Entry(device: Int64(stat.st_dev), inode: UInt64(stat.st_ino), size: Int64(initialSize),
                                                                 modified: modified, offset: Int64(completeOffset), fingerprint: bytes(before: completeOffset),
                                                                 project: state.project, parseFailure: state.parseFailure, longLine: state.longLine,
                                                                 records: SessionAnalyticsCache.pack(state.records))
                    }
                    // The unfinished tail is parsed on every scan and never cached.
                    if !skippingLongLine { autoreleasepool { parse(line, isTail: true, into: &state) } }
                }
            } catch { truncated = true }
            if state.parseFailure || state.longLine { truncated = true }
            files[index].project = state.project
            for record in state.records { replay(record, file: index) }
        }
        var byFile = Array(repeating: TokenTotals(), count: files.count)
        var totals = TokenTotals()
        var subagentTokens = TokenTotals()
        var byProfile: [String: TokenTotals] = [:]
        let parentIndices = Dictionary(uniqueKeysWithValues: files.enumerated().filter { !$0.element.isSubagent }.map { ($0.element.url.path, $0.offset) })
        var daily: [Date: Int64] = [:]
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var day = calendar.startOfDay(for: since)
        while day <= today {
            daily[day] = 0
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else {
                truncated = true; break
            }
            day = next
        }
        for message in messages.values {
            totals.add(message.tokens)
            if message.isSubagent { subagentTokens.add(message.tokens) }
            let profile = files[message.owner].profile
            byProfile[profile, default: TokenTotals()].add(message.tokens)
            let sessionOwner = files[message.owner].parentSessionPath.flatMap { parentIndices[$0] } ?? message.owner
            byFile[sessionOwner].add(message.tokens)
            files[sessionOwner].hasUsage = true
            let day = calendar.startOfDay(for: message.date)
            daily[day] = TokenTotals.sum(daily[day, default: 0], message.tokens.total)
        }
        let titleDate = DateFormatter(); titleDate.dateStyle = .medium; titleDate.timeStyle = .short
        let sessions = files.enumerated().filter { !$0.element.isSubagent && ($0.element.modified >= since || $0.element.hasUsage) }.map { index, file in
            let folder = file.project.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? "Session"
            return SessionRecord(sessionUUID: file.sessionID, profileCommand: file.profile, filePath: file.url.path,
                                 projectPath: file.project, title: String(folder.prefix(80)) + " · " + titleDate.string(from: file.modified),
                                 modifiedAt: file.modified, tokens: byFile[index], hasUsage: file.hasUsage)
        }
        let profileTotals = Dictionary(grouping: sessions, by: \.profileCommand)
        // A root skipped by the global budget or a failed read has unknown usage, not zero usage.
        let profileRows = scannedCommands.sorted().map { command in
            return ProfileTokens(command: command, tokens: byProfile[command, default: TokenTotals()], sessions: profileTotals[command, default: []].count)
        }
        cache?.store(kept, changed: cacheChanged || kept.count != cached.count, readBytes: readBytes)
        return AnalyticsSnapshot(sessions: sessions,
                                 daily: daily.keys.sorted().map { DailyTokens(day: $0, tokens: daily[$0]!) },
                                 profiles: profileRows, totals: totals, truncated: truncated,
                                 scannedFiles: scannedFiles, eligibleFiles: files.count, scannedBytes: Int64(totalBytes),
                                 subagentTokens: subagentTokens)
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty, string.utf8.count <= 512 else { return nil }
        return string
    }
    private static func safeDirectory(_ url: URL) -> Bool {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        // Foundation standardization rewrites /private/var to the /var symlink on macOS.
        // Inspect the literal path instead, and reject traversal components.
        for component in url.pathComponents where component != "/" {
            guard component != "..", component != "." else { return false }
            current.appendPathComponent(component, isDirectory: true)
            var info = Darwin.stat()
            guard lstat(current.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        }
        return true
    }
}
