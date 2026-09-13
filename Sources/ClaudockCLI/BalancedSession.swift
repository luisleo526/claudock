import Foundation
import Darwin
import Security
import UsageCore

enum BalancedSession {
    static func run(selectors: Set<String>?, arguments: [String]) async throws -> Int32 {
        guard let executable = ClaudeExecutable.find() else { throw MonitorError.unsupported("Install Claude Code or locate its executable in Claudock.") }
        var commands: Set<String>?
        if let selectors {
            let known = try ProfileStore.load()
            commands = []
            for selector in selectors {
                if let exact = known.first(where: { $0.command == selector }) { commands!.insert(exact.command); continue }
                let matches = known.filter { $0.name == selector }
                guard matches.count == 1 else {
                    throw MonitorError.unsupported("An Auto profile selector is missing or ambiguous. Use exact selectors from claudock profile list.")
                }
                commands!.insert(matches[0].command)
            }
        }
        let gateway = BalancedGateway(selectors: commands)
        try await gateway.prepare()
        // Native --bare deliberately skips OAuth and connectors. Otherwise keep
        // the default Claude login active so its organization connectors load.
        let bare = arguments.prefix(while: { $0 != "--" }).contains("--bare")
        let connectors = bare ? nil : await ConnectorSession.defaultSession()
        let server: LoopbackHTTPServer
        var localToken: String?
        if let connectors {
            server = LoopbackHTTPServer(authorizeBearer: { await connectors.authorize($0) }) {
                request, writer in await gateway.handle(request, writer: writer)
            }
        } else {
            var random = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw MonitorError.invalidResponse }
            let token = Data(random).base64EncodedString()
            localToken = token
            server = LoopbackHTTPServer(token: token) { request, writer in await gateway.handle(request, writer: writer) }
        }
        let port = try await server.start()
        defer { server.stop() }
        let shared = Profile(command: "claude", configDirectory: NSHomeDirectory() + "/.claude")
        var environment = try LaunchCommand.environment(profile: shared)
        environment["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:\(port)"
        if let localToken { environment["ANTHROPIC_AUTH_TOKEN"] = localToken }
        // Send local OAuth-authenticated requests directly to this listener even
        // when a corporate proxy is required for ordinary external connections.
        let proxyExclusions = [environment["NO_PROXY"], environment["no_proxy"], "127.0.0.1", "localhost"]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ",")
        environment["NO_PROXY"] = proxyExclusions; environment["no_proxy"] = proxyExclusions
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        let mode = connectors != nil ? "claude.ai connectors use the default login" :
            (bare ? "inference only (--bare skips connectors)" : "inference only (no usable default connector login)")
        FileHandle.standardError.write(Data("Claudock Auto · quota failover enabled · shared Claude workspace · \(mode)\n".utf8))
        return try await child(executable: executable, arguments: arguments, environment: environment)
    }

    private static func child(executable: String, arguments: [String], environment: [String: String]) async throws -> Int32 {
        let args = [executable] + arguments
        guard args.allSatisfy({ !$0.contains("\0") }), environment.allSatisfy({ !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
            throw MonitorError.unsupported("Invalid launch environment.")
        }
        let argv = args.map { strdup($0) } + [nil]
        let envp = environment.keys.sorted().map { strdup($0 + "=" + environment[$0]!) } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else { throw MonitorError.invalidResponse }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw MonitorError.invalidResponse }
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t(); sigemptyset(&defaults)
        for number in [SIGINT, SIGQUIT, SIGHUP, SIGTERM] { sigaddset(&defaults, number) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var empty = sigset_t(); sigemptyset(&empty)
        posix_spawnattr_setsigmask(&attributes, &empty)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        // Parent and child stay in the Terminal's foreground process group.
        // Claude handles Ctrl-C itself while the gateway continues to serve it.
        let oldINT = signal(SIGINT, SIG_IGN), oldQUIT = signal(SIGQUIT, SIG_IGN)
        let oldHUP = signal(SIGHUP, SIG_IGN), oldTERM = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGINT, oldINT); signal(SIGQUIT, oldQUIT); signal(SIGHUP, oldHUP); signal(SIGTERM, oldTERM) }
        var pid: pid_t = 0
        let code = argv.withUnsafeBufferPointer { args in envp.withUnsafeBufferPointer { env in
            posix_spawn(&pid, executable, nil, &attributes, args.baseAddress!, env.baseAddress!)
        } }
        guard code == 0 else { throw MonitorError.unsupported("Could not start Claude Code (\(code)).") }
        let childPID = pid
        let signals = [SIGHUP, SIGTERM].map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { kill(childPID, number) }; source.resume(); return source
        }
        defer { signals.forEach { $0.cancel() } }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                var status: Int32 = 0, result: pid_t
                repeat { result = waitpid(childPID, &status, 0) } while result < 0 && errno == EINTR
                guard result == childPID else { continuation.resume(throwing: MonitorError.invalidResponse); return }
                let signal = status & 0x7f
                continuation.resume(returning: signal == 0 ? (status >> 8) & 0xff : 128 + signal)
            }
        }
    }
}
