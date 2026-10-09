import Darwin
import Dispatch
import Foundation

public enum APICreditLaunchError: Error, Equatable {
    /// The loopback receiver could not start, so Claude was not launched; the caller may launch it without counting.
    case receiverUnavailable
    case launchFailed(Int32)
}

/// Runs Claude Code for a Console API-key profile as a child process that reports the cost of every request
/// to a loopback receiver, which appends it to the credit ledger as it arrives.
///
/// The child shares this process's group, terminal, working directory, and file descriptors, and gets the
/// prepared environment plus `APICreditCapture.environment`. It starts with no signal blocked, as from a shell:
/// the calling thread may be a dispatch worker, which blocks asynchronous signals. While it runs this process ignores the terminal's
/// SIGINT and SIGQUIT (the child receives them itself), forwards SIGTERM and SIGHUP to it, and stops alongside
/// it, so Ctrl-Z and `fg` work even when Claude Code stops itself from raw mode. Signals the caller ignored
/// (for example SIGHUP under nohup) stay ignored by both.
public enum APICreditLaunch {
    private static let jobControlSignals = [SIGINT, SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU, SIGPIPE]
    private static let forwardedSignals = [SIGTERM, SIGHUP]

    /// Returns the child's exit status, or 128 + the signal that ended it.
    public static func run(profile: Profile, executable: String, arguments: [String], environment: [String: String],
                           workingDirectory: String = FileManager.default.currentDirectoryPath,
                           warn: (String) -> Void) throws -> Int32 {
        let home = NSHomeDirectory()
        for override in APICreditCapture.overridingSettings(configDirectory: profile.configDirectory, workingDirectory: workingDirectory) {
            warn("\(override.file) sets \(override.key) for Claude Code, which can send its usage events elsewhere; "
                 + "this run's spend may be missing from the Console credit estimate.")
        }
        let capture = CaptureSession(profileID: profile.id, home: home)
        let receiver: APICreditReceiver
        do { receiver = try APICreditReceiver { body in capture.enqueue(body) } }
        catch { throw APICreditLaunchError.receiverUnavailable }

        let original = Dispositions()
        let reset = original.takeOver(ignoring: jobControlSignals, forwarding: forwardedSignals)
        let spawned = Date()
        let pid: pid_t
        do {
            pid = try spawn(executable: executable, arguments: arguments,
                            environment: APICreditCapture.environment(environment, port: receiver.port),
                            defaults: reset)
        } catch {
            original.restore()
            receiver.stop()
            throw error
        }
        ChildSignal.pid.pointee = pid
        if ChildSignal.pending.pointee != 0 { kill(pid, ChildSignal.pending.pointee) }
        let status = wait(for: pid, jobControl: original.isDefault(SIGTSTP))
        let exited = Date()
        ChildSignal.pid.pointee = 0
        // Finishing takes a moment; a late interrupt or termination must not lose what was received.
        original.ignoreForwarded(forwardedSignals)

        receiver.stop()
        let result = capture.finish()
        if let state = BoundedFile.read(profile.configDirectory + "/.claude.json", limit: 64 * 1_048_576) {
            do {
                try APICreditStore.reconcile(profileID: profile.id, home: home, claudeState: state, spawn: spawned, exit: exited,
                                             capturedSessions: result.sessions, now: Date())
            } catch { warn("Could not compare Claude Code's session total with the credit ledger: \(error.localizedDescription)") }
        }
        if result.unsaved > 0 {
            warn("\(result.unsaved) usage event\(result.unsaved == 1 ? "" : "s") from this run could not be saved to the Console credit ledger"
                 + (result.failure.map { ": \($0.localizedDescription)" } ?? ".") + " Set the credit again from the Console balance.")
        }
        return status
    }

    private static func spawn(executable: String, arguments: [String], environment: [String: String],
                              defaults: [Int32]) throws -> pid_t {
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.keys.sorted().map { strdup($0 + "=" + environment[$0]!) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else {
            throw APICreditLaunchError.launchFailed(ENOMEM)
        }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw APICreditLaunchError.launchFailed(ENOMEM) }
        defer { posix_spawnattr_destroy(&attributes) }
        var standard = sigset_t(), childMask = sigset_t()
        sigemptyset(&standard)
        sigemptyset(&childMask)
        for signal in defaults { sigaddset(&standard, signal) }
        posix_spawnattr_setsigdefault(&attributes, &standard)
        posix_spawnattr_setsigmask(&attributes, &childMask)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { arguments in
            envp.withUnsafeBufferPointer { variables in
                posix_spawn(&pid, executable, nil, &attributes, arguments.baseAddress!, variables.baseAddress!)
            }
        }
        guard result == 0 else { throw APICreditLaunchError.launchFailed(result) }
        return pid
    }

    private static func wait(for pid: pid_t, jobControl: Bool) -> Int32 {
        while true {
            var status: Int32 = 0
            if waitpid(pid, &status, WUNTRACED) < 0 {
                if errno == EINTR { continue }
                return 1
            }
            let low = status & 0o177
            if low == 0o177 {
                // Stopped. Stop this process too, so the shell sees the job stopped; `fg` continues both.
                if jobControl { stopAlongside(pid, signal: (status >> 8) & 0xFF) }
                continue
            }
            return low == 0 ? (status >> 8) & 0xFF : 128 + low
        }
    }

    private static func stopAlongside(_ child: pid_t, signal stop: Int32) {
        // A continue that arrived already (the shell's SIGCONT) must not stop the job a second time.
        guard isStopped(child) else { return }
        guard [SIGTSTP, SIGTTIN, SIGTTOU].contains(stop) else { kill(getpid(), SIGSTOP); return }
        var standard = sigaction(), previous = sigaction()
        standard.__sigaction_u.__sa_handler = SIG_DFL
        sigemptyset(&standard.sa_mask)
        sigaction(stop, &standard, &previous)
        var set = sigset_t(), saved = sigset_t()
        sigemptyset(&set)
        sigaddset(&set, stop)
        pthread_sigmask(SIG_UNBLOCK, &set, &saved)
        raise(stop)
        pthread_sigmask(SIG_SETMASK, &saved, nil)
        sigaction(stop, &previous, nil)
    }

    private static func isStopped(_ pid: pid_t) -> Bool {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_proc.p_stat == 4 // SSTOP
    }
}

/// This process's signal dispositions on entry, and the changes made while a child runs.
private struct Dispositions {
    let actions: [Int32: sigaction]

    init() {
        var actions: [Int32: sigaction] = [:]
        for signal in [SIGINT, SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU, SIGPIPE, SIGTERM, SIGHUP] {
            var current = sigaction()
            sigaction(signal, nil, &current)
            actions[signal] = current
        }
        self.actions = actions
    }

    func isDefault(_ signal: Int32) -> Bool { actions[signal].map { handler($0) == 0 } ?? false }
    private func isIgnored(_ signal: Int32) -> Bool { actions[signal].map { handler($0) == 1 } ?? false }

    /// SIG_DFL is 0 and SIG_IGN is 1 on Darwin.
    private func handler(_ action: sigaction) -> Int { unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self) }

    /// Ignores or forwards each signal the caller did not ignore, and returns them: the child gets their defaults.
    func takeOver(ignoring ignored: [Int32], forwarding forwarded: [Int32]) -> [Int32] {
        ChildSignal.pid.pointee = 0
        ChildSignal.pending.pointee = 0
        var changed: [Int32] = []
        for signal in ignored where !isIgnored(signal) {
            set(signal, handler: SIG_IGN)
            changed.append(signal)
        }
        for signal in forwarded where !isIgnored(signal) {
            set(signal, handler: forwardToChild)
            changed.append(signal)
        }
        return changed
    }

    func ignoreForwarded(_ forwarded: [Int32]) {
        for signal in forwarded where !isIgnored(signal) { set(signal, handler: SIG_IGN) }
    }

    func restore() {
        for (signal, action) in actions {
            var previous = action
            sigaction(signal, &previous, nil)
        }
    }

    private func set(_ signal: Int32, handler: @escaping @convention(c) (Int32) -> Void) {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = handler
        sigemptyset(&action.sa_mask)
        action.sa_flags = SA_RESTART
        sigaction(signal, &action, nil)
    }
}

/// Plain memory, not Swift globals: the signal handler must not trigger exclusivity checks.
private enum ChildSignal {
    nonisolated(unsafe) static let pid: UnsafeMutablePointer<pid_t> = {
        let pointer = UnsafeMutablePointer<pid_t>.allocate(capacity: 1)
        pointer.initialize(to: 0)
        return pointer
    }()
    /// A signal that arrived before the child existed, delivered right after it starts.
    nonisolated(unsafe) static let pending: UnsafeMutablePointer<Int32> = {
        let pointer = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        pointer.initialize(to: 0)
        return pointer
    }()
}

/// Async-signal-safe.
private let forwardToChild: @convention(c) (Int32) -> Void = { signal in
    let child = ChildSignal.pid.pointee
    if child > 0 { kill(child, signal) } else { ChildSignal.pending.pointee = signal }
}

/// Turns received bodies into ledger writes on one serial queue, so the receiver never waits for the
/// ledger. Requests that could not be saved are retried with the next batch and once more at the end.
private final class CaptureSession: @unchecked Sendable {
    private let profileID: String
    private let home: String
    private let queue = DispatchQueue(label: "Claudock.APICreditCapture")
    private var pending: [APICreditRequest] = []
    private var sessions: Set<String> = []
    private var failure: Error?

    init(profileID: String, home: String) {
        self.profileID = profileID
        self.home = home
    }

    func enqueue(_ body: Data) {
        queue.async { [self] in
            let requests = APICreditEvents.requests(fromOTLPJSON: body)
            guard !requests.isEmpty else { return }
            sessions.formUnion(requests.map(\.sessionID))
            pending += requests
            save()
        }
    }

    func finish() -> (sessions: Set<String>, unsaved: Int, failure: Error?) {
        queue.sync {
            save()
            return (sessions, pending.count, failure)
        }
    }

    private func save() {
        guard !pending.isEmpty else { return }
        do {
            try APICreditStore.record(pending, profileID: profileID, home: home)
            pending.removeAll()
            failure = nil
        } catch { failure = error }
    }
}

/// A loopback-only HTTP/1.1 server for OTLP/HTTP JSON log exports on an ephemeral port. A complete request
/// body of at most `maximumBody` bytes reaches `onBody` before the response; a larger one is read and dropped.
/// Every POST gets HTTP 200, so an exporter never retries input that was refused, and keep-alive connections
/// are served until the peer closes them or the receiver stops.
final class APICreditReceiver: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let maximumBody: Int
    /// Bodies beyond this are not even read; the connection is closed.
    private let discardLimit = 64 * 1_048_576
    private let onBody: (Data) -> Void
    private let state = NSLock()
    private var stopping = false
    private var connections: Set<Int32> = []
    private let group = DispatchGroup()
    private let handlers = DispatchQueue(label: "Claudock.APICreditReceiver.connections", attributes: .concurrent)
    private var source: DispatchSourceRead?

    init(maximumBody: Int = 4 * 1_048_576, onBody: @escaping (Data) -> Void) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw APICreditLaunchError.receiverUnavailable }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
        }
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard Self.prepare(descriptor), bound == 0, named == 0, listen(descriptor, 16) == 0,
              fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else {
            close(descriptor)
            throw APICreditLaunchError.receiverUnavailable
        }
        listener = descriptor
        port = UInt16(bigEndian: address.sin_port)
        self.maximumBody = maximumBody
        self.onBody = onBody
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "Claudock.APICreditReceiver.accept"))
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    deinit { stop() }

    /// Stops accepting, lets requests in progress finish, and closes idle connections.
    func stop() {
        state.lock()
        let first = !stopping
        stopping = true
        state.unlock()
        guard first else { return }
        source?.cancel()
        if group.wait(timeout: .now() + 3) == .timedOut {
            state.lock()
            let open = connections
            state.unlock()
            for connection in open { shutdown(connection, SHUT_RDWR) }
            _ = group.wait(timeout: .now() + 1)
        }
    }

    private var isStopping: Bool {
        state.lock()
        defer { state.unlock() }
        return stopping
    }

    /// Close-on-exec, so the child never inherits a receiver socket, and no SIGPIPE on a closed peer.
    private static func prepare(_ descriptor: Int32) -> Bool {
        var one: Int32 = 1
        return fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0
            && setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    private func acceptPending() {
        while true {
            let connection = accept(listener, nil, nil)
            if connection < 0 {
                if errno == EINTR { continue }
                return
            }
            guard Self.prepare(connection), fcntl(connection, F_SETFL, fcntl(connection, F_GETFL) & ~O_NONBLOCK) == 0 else {
                close(connection)
                continue
            }
            state.lock()
            let accepted = !stopping
            if accepted { connections.insert(connection) }
            state.unlock()
            guard accepted else { close(connection); continue }
            handlers.async(group: group) { [self] in
                serve(connection)
                state.lock()
                connections.remove(connection)
                state.unlock()
                close(connection)
            }
        }
    }

    private func serve(_ connection: Int32) {
        var reader = Reader(descriptor: connection)
        while true {
            // Between requests: wait for the next one until the peer closes, the receiver stops, or a minute passes.
            if reader.buffer.isEmpty, !reader.fill(timeout: 60, stopping: { self.isStopping }) { return }
            guard let head = reader.head(limit: 16_384), let request = Request(head) else {
                respond(connection, status: "400 Bad Request", close: true)
                return
            }
            guard request.method == "POST" else {
                respond(connection, status: "405 Method Not Allowed", close: true)
                return
            }
            if request.expectsContinue { send(connection, Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)) }
            let body: Reader.Body?
            if request.chunked {
                body = reader.chunkedBody(keepUpTo: maximumBody, limit: discardLimit)
            } else if let length = request.contentLength, length <= discardLimit {
                body = reader.body(length: length, keepUpTo: maximumBody)
            } else {
                body = nil
            }
            guard let body else {
                respond(connection, status: "413 Content Too Large", close: true)
                return
            }
            if let data = body.data, request.path == "/v1/logs", request.identityEncoding { onBody(data) }
            respond(connection, status: "200 OK", close: request.closes)
            if request.closes { return }
        }
    }

    private func respond(_ connection: Int32, status: String, close: Bool) {
        let body = status.hasPrefix("200") ? "{}" : ""
        send(connection, Data(("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
                               + (close ? "Connection: close\r\n" : "") + "\r\n" + body).utf8))
    }

    private func send(_ connection: Int32, _ data: Data) {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(connection, bytes.baseAddress! + offset, bytes.count - offset, 0)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                offset += count
            }
        }
    }

    private struct Request {
        let method: String
        let path: String
        let contentLength: Int?
        let chunked: Bool
        let closes: Bool
        let expectsContinue: Bool
        let identityEncoding: Bool

        init?(_ head: Data) {
            guard let text = String(data: head, encoding: .utf8) else { return nil }
            let lines = text.components(separatedBy: "\r\n")
            let parts = lines[0].split(separator: " ")
            guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() where !line.isEmpty {
                guard let colon = line.firstIndex(of: ":") else { return nil }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            method = String(parts[0])
            path = String(parts[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
            chunked = headers["transfer-encoding"]?.lowercased().contains("chunked") ?? false
            if let value = headers["content-length"] {
                guard let length = Int(value), length >= 0 else { return nil }
                contentLength = length
            } else {
                contentLength = chunked ? nil : 0
            }
            let connection = headers["connection"]?.lowercased() ?? ""
            closes = connection.contains("close") || (parts[2] == "HTTP/1.0" && !connection.contains("keep-alive"))
            expectsContinue = headers["expect"]?.lowercased() == "100-continue"
            identityEncoding = ["", "identity"].contains(headers["content-encoding"]?.lowercased() ?? "")
        }
    }

    /// Buffered reads from one connection. Within a request a stall of ten seconds ends it.
    private struct Reader {
        struct Body { let data: Data? }
        let descriptor: Int32
        var buffer = Data()

        init(descriptor: Int32) { self.descriptor = descriptor }

        mutating func fill(timeout: TimeInterval = 10, stopping: (() -> Bool)? = nil) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while true {
                var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&waiting, 1, 100)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if ready == 0 {
                    if stopping?() == true || Date() >= deadline { return false }
                    continue
                }
                let count = recv(descriptor, &chunk, chunk.count, 0)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard count > 0 else { return false }
                buffer.append(contentsOf: chunk[0..<count])
                return true
            }
        }

        /// The request line and headers, without the blank line that ends them.
        mutating func head(limit: Int) -> Data? {
            let end = Data("\r\n\r\n".utf8)
            while true {
                if let range = buffer.range(of: end) {
                    let head = buffer[buffer.startIndex..<range.lowerBound]
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    return Data(head)
                }
                guard buffer.count <= limit, fill() else { return nil }
            }
        }

        mutating func line(limit: Int) -> String? {
            let end = Data("\r\n".utf8)
            while true {
                if let range = buffer.range(of: end) {
                    let line = String(data: buffer[buffer.startIndex..<range.lowerBound], encoding: .utf8)
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    return line
                }
                guard buffer.count <= limit, fill() else { return nil }
            }
        }

        /// Reads `length` bytes, keeping them only when there are at most `keepUpTo`; nil if the peer stops early.
        mutating func body(length: Int, keepUpTo: Int) -> Body? {
            let keep = length <= keepUpTo
            var data = Data()
            var remaining = length
            while remaining > 0 {
                if buffer.isEmpty, !fill() { return nil }
                let take = min(remaining, buffer.count)
                if keep { data.append(buffer.prefix(take)) }
                buffer.removeFirst(take)
                remaining -= take
            }
            return Body(data: keep ? data : nil)
        }

        mutating func chunkedBody(keepUpTo: Int, limit: Int) -> Body? {
            var data = Data(), total = 0, keep = true
            while true {
                guard let line = line(limit: 1024),
                      let size = Int(line.split(separator: ";", maxSplits: 1)[0].trimmingCharacters(in: .whitespaces), radix: 16),
                      size >= 0 else { return nil }
                if size == 0 {
                    while true {
                        guard let trailer = self.line(limit: 16_384) else { return nil }
                        if trailer.isEmpty { return Body(data: keep ? data : nil) }
                    }
                }
                total += size
                guard total <= limit else { return nil }
                if total > keepUpTo { keep = false; data = Data() }
                guard let chunk = body(length: size, keepUpTo: keep ? size : -1), self.line(limit: 2) == "" else { return nil }
                if keep, let bytes = chunk.data { data.append(bytes) }
            }
        }
    }
}
