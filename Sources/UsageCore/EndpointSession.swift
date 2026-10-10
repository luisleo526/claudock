import Foundation
import Darwin

public enum EndpointSessionError: Error, LocalizedError, Equatable {
    /// The transcript at this path could not be read to check it.
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path): return "Could not read the session \(path) to check which models replied in it."
        }
    }
}

/// Which saved session a Claude Code command line resumes, so an endpoint profile can refuse one that other models
/// replied in: a long session made with Claude fails on a third-party endpoint once it is compacted.
public enum EndpointSession {
    /// What a command line asks Claude Code to load.
    enum Request: Equatable, Sendable {
        /// `-c` / `--continue`: the latest session of the working directory.
        case latest
        /// `--resume VALUE`: a session ID, a transcript path, or a search term.
        case session(String)
        /// `--resume` without a value: Claude Code's picker.
        case picker
    }

    /// What a launch's arguments would resume.
    public enum Outcome: Equatable, Sendable {
        /// Nothing, or a session that only the pinned model replied in.
        case clear
        /// A session chosen where Claudock cannot see it first: Claude Code's picker, or a remote session.
        case uncheckable
        /// `session` (its ID or file name) holds replies from `models`.
        case otherModels(session: String, models: [String])
    }

    /// Resolves the session that `arguments` make Claude Code 2.1.296 load in `workingDirectory` with `configDirectory`
    /// as `CLAUDE_CONFIG_DIR`, and checks which models replied in it and in the subagent transcripts it can pull in
    /// later. `environment` is the launch's, for `CLAUDE_CODE_PROJECT_DIR_NAME`. A session Claude Code would refuse
    /// to load (unknown, ambiguous, or missing) is clear: Claude Code reports it. Where Claude Code finds a session ID in
    /// several project folders, every copy is checked.
    public static func check(arguments: [String], workingDirectory: String, configDirectory: String, environment: [String: String],
                             pinned: String) -> Outcome {
        let options = ClaudeCommandLine.options(in: arguments)
        let names = Set(options.map(\.name))
        if !names.isDisjoint(with: ["--teleport", "--cloud", "--remote", "--from-pr"]) { return .uncheckable }
        let interactive = names.isDisjoint(with: ["-p", "--print"])
        let context = Context(configDirectory: configDirectory, environment: environment, workingDirectory: workingDirectory)
        let transcripts: [String]
        if !names.isDisjoint(with: ["-c", "--continue"]) {
            // Claude Code continues even when --resume is given too.
            transcripts = context.continued(interactive: interactive, fork: names.contains("--fork-session")).map { [$0] } ?? []
        } else if let resume = options.last(where: { $0.name == "-r" || $0.name == "--resume" }) {
            guard let value = resume.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return interactive ? .uncheckable : .clear
            }
            if UUID(uuidString: value) != nil {
                transcripts = context.resumed(id: value)
            } else if interactive ? value.hasPrefix("/") && value.hasSuffix(".jsonl") : value.lowercased().hasSuffix(".jsonl") {
                transcripts = [value.hasPrefix("/") ? value : workingDirectory + "/" + value].filter { FileManager.default.fileExists(atPath: $0) }
            } else if !interactive, value.range(of: #"\A[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil {
                return .uncheckable
            } else {
                let matches = context.titled(value)
                guard matches.count == 1 else { return interactive ? .uncheckable : .clear }
                transcripts = matches
            }
        } else {
            return .clear
        }
        var models = Set<String>()
        for transcript in transcripts {
            for file in [transcript] + Context.companions(of: transcript) {
                // A file Claude Code could not read either has nothing to load.
                models.formUnion((try? otherModels(inTranscript: URL(fileURLWithPath: file), pinned: pinned)) ?? [])
            }
        }
        guard let first = transcripts.first, !models.isEmpty else { return .clear }
        return .otherModels(session: URL(fileURLWithPath: first).deletingPathExtension().lastPathComponent, models: models.sorted())
    }

    /// The `-c`/`--continue` and `-r`/`--resume` requests in `arguments`, read the way Claude Code reads them.
    static func requests(in arguments: [String]) -> [Request] {
        ClaudeCommandLine.options(in: arguments).compactMap { option in
            switch option.name {
            case "-c", "--continue": return .latest
            case "-r", "--resume": return option.value.map { $0.isEmpty ? .picker : .session($0) } ?? .picker
            default: return nil
            }
        }
    }

    /// The folder under `projects` where Claude Code keeps the sessions of the working directory `path` (already a real
    /// path in NFC), as Claude Code 2.1.296 names it: every UTF-16 unit that is not an ASCII letter or digit becomes
    /// `-`; a name longer than 200 keeps its first 200 units and adds `-` and the base-36 magnitude of the Java-style
    /// 32-bit hash of `path`'s UTF-16 units.
    public static func projectFolderName(_ path: String) -> String {
        let units = Array(path.utf16)
        let isLetterOrDigit: (UInt16) -> Bool = { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
        let sanitized = units.map { isLetterOrDigit($0) ? $0 : 0x2D }
        guard sanitized.count > 200 else { return String(decoding: sanitized, as: UTF16.self) }
        var hash: Int32 = 0
        for unit in units { hash = hash &* 31 &+ Int32(unit) }
        return String(decoding: sanitized.prefix(200), as: UTF16.self) + "-" + String(abs(Int64(hash)), radix: 36)
    }

    /// The models other than `pinned` that replied in a transcript, from its `assistant` entries, sorted. An entry is the
    /// pinned model's when the model that answered (`message.model`) or the one Claude Code asked for (`requestedModel`)
    /// is the pinned id, with or without `[1m]`: Claude Code sends and the endpoint answers the plain id. `<synthetic>`
    /// marks Claude Code's own local messages, not a model's reply. Only those fields of an entry are decoded; lines
    /// that cannot be an assistant entry are skipped unread, and nothing is printed.
    public static func otherModels(inTranscript url: URL, pinned: String) throws -> [String] {
        // A FIFO or device must not block or feed the launch: only a regular file is read.
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw EndpointSessionError.unreadable(url.path) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, let file = fdopen(descriptor, "r") else {
            close(descriptor)
            throw EndpointSessionError.unreadable(url.path)
        }
        defer { fclose(file) }
        var buffer: UnsafeMutablePointer<CChar>?
        var capacity = 0
        defer { free(buffer) }
        let marker = Array("\"assistant\"".utf8)
        let decoder = JSONDecoder()
        func plain(_ model: String) -> String { model.lowercased().hasSuffix("[1m]") ? String(model.dropLast(4)) : model }
        let pinnedModel = plain(pinned)
        var models = Set<String>()
        while case let length = getline(&buffer, &capacity, file), length >= 0 {
            guard let buffer, memmem(buffer, length, marker, marker.count) != nil,
                  let entry = try? decoder.decode(Entry.self, from: Data(bytes: buffer, count: length)), entry.type == "assistant",
                  let model = entry.message?.model ?? entry.requestedModel, model != "<synthetic>",
                  ![entry.message?.model, entry.requestedModel].contains(where: { $0.map(plain) == pinnedModel }) else { continue }
            models.insert(model)
        }
        guard ferror(file) == 0 else { throw EndpointSessionError.unreadable(url.path) }
        return models.sorted()
    }

    /// The fields of a transcript entry the check needs; everything else is left undecoded.
    private struct Entry: Decodable {
        let type: String?
        let requestedModel: String?
        let message: Message?
        struct Message: Decodable { let model: String? }
    }
}

/// Claude Code's command line as its parser (Commander) reads it, with Claude Code 2.1.296's options, hidden ones
/// included, so that a value such as `--append-system-prompt -c` is not mistaken for an option.
enum ClaudeCommandLine {
    enum Arity { case flag, required, optional, variadic }

    /// One option as Claude Code reads it: its name as written, its value, and the indices of the arguments it took.
    struct Option: Equatable {
        let name: String
        let value: String?
        let indices: [Int]
    }

    static let arities: [String: Arity] = {
        var table: [String: Arity] = [:]
        let flags = ["--no-session-persistence", "-h", "--help", "--verbose", "-p", "--print", "--bare", "--safe-mode", "--init", "--init-only",
                     "--maintenance", "--include-hook-events", "--include-partial-messages", "--forward-subagent-text", "--session-mirror",
                     "--await-claim", "--await-initialize", "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions",
                     "--replay-user-messages", "--enable-auth-status", "--restricted", "--exclude-dynamic-system-prompt-sections", "-c",
                     "--continue", "--fork-session", "--deep-link-origin", "--reply-on-resume", "--ide", "--desktop", "--strict-mcp-config",
                     "--disable-slash-commands", "--chrome", "--no-chrome", "--tmux", "--enable-auto-mode", "--bg", "--background", "--brief",
                     "--ax-screen-reader", "--plan-mode-required", "-v", "--version"]
        let optional = ["-d", "--debug", "--prompt-suggestions", "-r", "--resume", "--from-pr", "-w", "--worktree", "--teleport", "--cloud",
                        "--remote", "--remote-control", "--rc"]
        let variadic = ["--allowedTools", "--allowed-tools", "--tools", "--disallowedTools", "--disallowed-tools", "--mcp-config", "--betas",
                        "--add-dir", "--file", "--channels", "--dangerously-load-development-channels"]
        let required = ["--debug-file", "--output-format", "--json-schema", "--input-format", "--thinking", "--thinking-display",
                        "--max-thinking-tokens", "--max-turns", "--max-budget-usd", "--task-budget", "--permission-prompt-tool",
                        "--permission-prompts", "--system-prompt", "--system-prompt-file", "--append-system-prompt", "--append-system-prompt-file",
                        "--system-prompt-snapshot", "--append-subagent-system-prompt", "--append-subagent-system-prompt-file",
                        "--plan-mode-instructions", "--permission-mode", "--inherit-permission-mode", "--watch-artifact",
                        "--watch-artifact-no-autoreact", "--prefill", "--deep-link-repo", "--deep-link-last-fetch", "--prefill-b64",
                        "--deep-link-cwd-b64", "--resume-session-at", "--resume-drops-turn", "--rewind-files", "--model", "--effort", "--agent",
                        "--fallback-model", "--workload", "--settings", "--client-data-url", "--managed-settings", "--project-config-root",
                        "--session-id", "-n", "--name", "--agents", "--setting-sources", "--plugin-dir", "--plugin-dir-no-mcp", "--plugin-url",
                        "--advisor", "--autocompact", "--proactivity", "--messaging-socket-path", "--agent-id", "--agent-name", "--team-name",
                        "--agent-color", "--parent-session-id", "--teammate-mode", "--agent-type", "--sdk-url", "--forward-home-settings",
                        "--attach-serve", "--environment", "--pool", "--correlation-id", "--ref", "--on-branch", "--remote-control-session-name-prefix"]
        for name in flags { table[name] = .flag }
        for name in optional { table[name] = .optional }
        for name in variadic { table[name] = .variadic }
        for name in required { table[name] = .required }
        return table
    }()

    /// The options in `arguments`, in order, read as Commander reads them: `--` ends the options; an option that needs
    /// a value takes the next argument, whatever it is; an optional value (`--resume`) is taken only when the next
    /// argument does not start with `-`; a variadic option also takes the arguments after that up to the next option;
    /// `-rVALUE` and `--name=VALUE` carry their value; and a cluster such as `-pc` is each flag in turn. Operands, such
    /// as the prompt, and options Claude Code does not know are left out.
    static func options(in arguments: [String]) -> [Option] {
        func maybeOption(_ argument: String) -> Bool { argument.count > 1 && argument.hasPrefix("-") }
        var pending = arguments.enumerated().map { (text: $0.element, index: $0.offset) }
        var cursor = 0, variadic = false
        var result: [Option] = []
        func take(_ name: String, at index: Int, onlyIf accepts: (String) -> Bool) {
            if cursor < pending.count, accepts(pending[cursor].text) {
                result.append(Option(name: name, value: pending[cursor].text, indices: [index, pending[cursor].index]))
                cursor += 1
            } else {
                result.append(Option(name: name, value: nil, indices: [index]))
            }
        }
        while cursor < pending.count {
            let (argument, index) = pending[cursor]
            cursor += 1
            if argument == "--" { break }
            if variadic, !maybeOption(argument) { continue }
            variadic = false
            if maybeOption(argument), let arity = arities[argument] {
                switch arity {
                case .flag: result.append(Option(name: argument, value: nil, indices: [index]))
                case .required, .variadic:
                    take(argument, at: index, onlyIf: { _ in true })
                    variadic = arity == .variadic
                case .optional: take(argument, at: index, onlyIf: { !maybeOption($0) })
                }
                continue
            }
            if argument.count > 2, argument.hasPrefix("-"), !argument.hasPrefix("--") {
                let name = "-" + String(argument.dropFirst().prefix(1))
                if let arity = arities[name] {
                    if arity == .flag {
                        result.append(Option(name: name, value: nil, indices: [index]))
                        pending.insert((text: "-" + String(argument.dropFirst(2)), index: index), at: cursor)
                    } else {
                        result.append(Option(name: name, value: String(argument.dropFirst(2)), indices: [index]))
                    }
                    continue
                }
            }
            if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "="), let arity = arities[String(argument[..<equals])], arity != .flag {
                result.append(Option(name: String(argument[..<equals]), value: String(argument[argument.index(after: equals)...]), indices: [index]))
            }
        }
        return result
    }
}

/// Where and how Claude Code 2.1.296 finds a working directory's sessions, from its code and the experiments that confirm
/// it: the folder named after the working directory's real path (or `CLAUDE_CODE_PROJECT_DIR_NAME`), session-ID file
/// names only, newest modification time first, and the sessions `--continue` passes over.
private struct Context {
    let projects: String
    let pin: String?
    let canonical: String
    private static let headBytes = 65_536
    private static let sdkEntrypoints: Set<String> = ["sdk-cli", "sdk-ts", "sdk-py"]

    init(configDirectory: String, environment: [String: String], workingDirectory: String) {
        projects = configDirectory.precomposedStringWithCanonicalMapping + "/projects"
        let pin = environment["CLAUDE_CODE_PROJECT_DIR_NAME"]
        self.pin = pin.flatMap { $0.range(of: #"\A[A-Za-z0-9_-]{1,64}\z"#, options: .regularExpression) == nil
            || $0.range(of: #"\A(?i:con|prn|aux|nul|com[0-9]|lpt[0-9])\z"#, options: .regularExpression) != nil ? nil : $0 }
        canonical = Context.realPath(workingDirectory)
    }

    static func realPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        // realpath(3) also gives each component's letter case on disk, as Claude Code's realpathSync does.
        return (realpath(path, &buffer).map { String(cString: $0) } ?? path).precomposedStringWithCanonicalMapping
    }

    private static func sanitized(_ path: String) -> String {
        String(decoding: path.utf16.map { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ? $0 : 0x2D }, as: UTF16.self)
    }

    private func name(_ path: String) -> String { pin ?? EndpointSession.projectFolderName(path) }

    private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    /// The existing folders that can hold the sessions of `path`.
    private func folders(_ path: String) -> [String] {
        let main = projects + "/" + name(path)
        var result = Context.isDirectory(main) ? [main] : []
        let slug = EndpointSession.projectFolderName(path)
        if pin != nil {
            let alternative = projects + "/" + slug
            if alternative != main, Context.isDirectory(alternative) { result.append(alternative) }
            return result
        }
        guard slug.utf16.count > 201 else { return result }
        // A long name ends in a hash that runtimes compute differently; a folder with the same first 200 characters
        // counts when one of its sessions recorded this working directory.
        let prefix = String(slug.prefix(200)) + "-"
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: projects))?.sorted() ?? [] where entry.hasPrefix(prefix) {
            let folder = projects + "/" + entry
            if folder != main, Context.isDirectory(folder), Context.sessionFiles(folder).contains(where: {
                let (head, tail, _) = Context.headAndTail($0.path)
                return Context.recordedDirectory(head: head, tail: tail).map { Context.sanitized($0.precomposedStringWithCanonicalMapping) } == Context.sanitized(path)
            }) { result.append(folder) }
        }
        return result
    }

    struct Candidate { let path: String; let id: String; let modified: Date; let created: Date; let alias: Bool }

    /// Regular `<session-id>.jsonl` files directly in `folder`.
    static func sessionFiles(_ folder: String, alias: Bool = false) -> [Candidate] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).compactMap { entry in
            guard entry.hasSuffix(".jsonl"), UUID(uuidString: String(entry.dropLast(6))) != nil else { return nil }
            let path = folder + "/" + entry
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path), attributes[.type] as? FileAttributeType == .typeRegular else {
                return nil
            }
            return Candidate(path: path, id: String(entry.dropLast(6)), modified: attributes[.modificationDate] as? Date ?? .distantPast,
                             created: attributes[.creationDate] as? Date ?? .distantPast, alias: alias)
        }
    }

    /// The transcript `--continue` loads, or nil when it would start a new session or stop.
    func continued(interactive: Bool, fork: Bool) -> String? {
        let primary = folders(canonical).first ?? projects + "/" + name(canonical)
        var candidates = Context.sessionFiles(primary)
        // An older layout named folders differently: when the folder holds nothing of this directory's, Claude Code also
        // takes folders whose newest session recorded it.
        if canonical.range(of: #"[^a-zA-Z0-9/\\:-]"#, options: .regularExpression) != nil, candidates.allSatisfy(collides) {
            candidates = []
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: projects))?.sorted() ?? [] {
                let folder = projects + "/" + entry
                guard folder != primary, Context.isDirectory(folder),
                      (try? FileManager.default.destinationOfSymbolicLink(atPath: folder)) == nil else { continue }
                let files = Context.sessionFiles(folder)
                guard let newest = files.max(by: { $0.modified < $1.modified }) else { continue }
                let (head, tail, _) = Context.headAndTail(newest.path)
                if Context.recordedDirectory(head: head, tail: tail) == canonical { candidates += files }
            }
        }
        if let aliases = try? String(contentsOfFile: projects + "/" + name(canonical) + "/.session-aliases", encoding: .utf8) {
            var newest: [String: Candidate] = [:]
            for candidate in candidates + aliases.split(separator: "\n").flatMap({ Context.sessionFiles(String($0), alias: true) })
            where newest[candidate.id].map({ candidate.modified > $0.modified }) ?? true { newest[candidate.id] = candidate }
            candidates = Array(newest.values)
        }
        candidates.sort { $0.modified != $1.modified ? $0.modified > $1.modified : $0.created > $1.created }
        let live = liveSessions()
        for candidate in candidates {
            switch verdict(candidate, interactive: interactive, fork: fork, live: live) {
            case .accept: return candidate.path
            case .stop: return nil
            case .skip: continue
            }
        }
        return nil
    }

    private enum Verdict { case accept, skip, stop }

    private func verdict(_ candidate: Candidate, interactive: Bool, fork: Bool, live: Set<String>) -> Verdict {
        let (head, tail, size) = Context.headAndTail(candidate.path)
        // An empty file is continued as an empty conversation.
        guard !head.isEmpty else { return fork || !live.contains(candidate.id.lowercased()) ? .accept : .skip }
        if !candidate.alias, collides(candidate) { return .skip }
        if head.contains(#""isSidechain":true"#) || head.contains(#""isSidechain": true"#) || Context.firstString(head, "teamName") != nil { return .skip }
        let firstChainLine = head.split(separator: "\n").first(where: { $0.contains(#""parentUuid":"#) }).map(String.init) ?? head
        if let kind = Context.firstString(firstChainLine, "sessionKind"), ["daemon", "daemon-worker"].contains(kind) { return .skip }
        if interactive, let entry = Context.firstString(head, "entrypoint") ?? Context.lastString(tail, "entrypoint"),
           Context.sdkEntrypoints.contains(entry) { return .skip }
        if interactive, head.contains("<command-name>/loop</command-name>") { return .skip }
        if !Context.hasChainRecord(candidate.path, head: head, tail: tail, size: size) { return .skip }
        if let next = Context.continuedIn(tail) {
            if !fork, live.contains(next.lowercased()) { return .stop }
            let target = URL(fileURLWithPath: candidate.path).deletingLastPathComponent().appendingPathComponent(next + ".jsonl").path
            let (targetHead, targetTail, targetSize) = Context.headAndTail(target)
            if !targetHead.isEmpty, Context.hasChainRecord(target, head: targetHead, tail: targetTail, size: targetSize) { return .skip }
        }
        if !fork, live.contains(candidate.id.lowercased()) { return .skip }
        return .accept
    }

    /// A session recorded in another existing directory whose folder name is the same as this one's.
    private func collides(_ candidate: Candidate) -> Bool {
        let (head, tail, _) = Context.headAndTail(candidate.path)
        guard let recorded = Context.recordedDirectory(head: head, tail: tail)?.precomposedStringWithCanonicalMapping,
              Context.sanitized(recorded).lowercased() == Context.sanitized(canonical).lowercased(),
              recorded.lowercased() != canonical.lowercased(), FileManager.default.fileExists(atPath: recorded) else { return false }
        let real = Context.realPath(recorded)
        return Context.sanitized(real).lowercased() == Context.sanitized(canonical).lowercased() && real.lowercased() != canonical.lowercased()
    }

    /// Sessions a running background or daemon Claude Code holds, from its `sessions` records.
    private func liveSessions() -> Set<String> {
        let folder = URL(fileURLWithPath: projects).deletingLastPathComponent().appendingPathComponent("sessions").path
        var result = Set<String>()
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where entry.hasSuffix(".json") {
            guard let data = BoundedFile.read(folder + "/" + entry, limit: 1_048_576),
                  let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pid = (record["pid"] as? NSNumber)?.int32Value ?? (record["pid"] as? String).flatMap(Int32.init), pid > 0,
                  kill(pid, 0) == 0, record["kind"] as? String != "interactive", let id = record["sessionId"] as? String else { continue }
            result.insert(id.lowercased())
        }
        return result
    }

    /// The transcripts `--resume ID` can load: the first copy in this directory's folders that holds messages, else the
    /// copies in every project folder that hold conversation lines (Claude Code takes a single one, preferring its own
    /// git worktrees; all are checked).
    func resumed(id: String) -> [String] {
        if let first = folders(canonical).lazy.map({ $0 + "/" + id + ".jsonl" }).first(where: { FileManager.default.fileExists(atPath: $0) }),
           Context.holdsMessages(first) {
            return [first]
        }
        return ((try? FileManager.default.contentsOfDirectory(atPath: projects))?.sorted() ?? []).compactMap { entry in
            let folder = projects + "/" + entry
            guard Context.isDirectory(folder), (try? FileManager.default.destinationOfSymbolicLink(atPath: folder)) == nil else { return nil }
            let file = folder + "/" + id + ".jsonl"
            return Context.holdsConversation(file) ? file : nil
        }
    }

    /// Sessions of this directory whose title (the one set with /rename, else the generated one) is `title`, in any letter case.
    func titled(_ title: String) -> [String] {
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var matches: [String: Candidate] = [:]
        for folder in Set(folders(canonical).isEmpty ? [projects + "/" + name(canonical)] : folders(canonical)) {
            for candidate in Context.sessionFiles(folder) {
                let (head, tail, _) = Context.headAndTail(candidate.path)
                var custom = Context.lastString(tail, "customTitle")
                if custom == nil, let data = BoundedFile.read(folder + "/" + candidate.id + "/custom-title.json", limit: 65_536),
                   let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    custom = record["customTitle"] as? String
                }
                custom = custom ?? Context.lastString(head, "customTitle")
                let generated = Context.lastString(tail, "aiTitle") ?? Context.lastString(head, "aiTitle")
                let name = ((custom?.isEmpty == false ? custom : generated) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !name.isEmpty, name == wanted, matches[candidate.id].map({ candidate.modified > $0.modified }) ?? true {
                    matches[candidate.id] = candidate
                }
            }
        }
        return matches.values.sorted { $0.modified > $1.modified }.map(\.path)
    }

    /// What a resumed session can load later: its subagents' transcripts, and the sessions they fork their context from.
    static func companions(of transcript: String) -> [String] {
        let url = URL(fileURLWithPath: transcript)
        let folder = url.deletingLastPathComponent(), id = url.deletingPathExtension().lastPathComponent
        let subagents = folder.appendingPathComponent(id).appendingPathComponent("subagents")
        var result: [String] = []
        if let files = FileManager.default.enumerator(at: subagents, includingPropertiesForKeys: nil) {
            for case let file as URL in files where file.pathExtension == "jsonl" { result.append(file.path) }
        }
        for file in result.sorted() {
            _ = anyLine(in: file, containing: [#""type":"fork-context-ref""#]) { line in
                if let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                   let parent = record["parentSessionId"] as? String, UUID(uuidString: parent) != nil {
                    result.append(folder.appendingPathComponent(parent + ".jsonl").path)
                }
                return false
            }
        }
        return result.sorted()
    }

    /// The first and last 64 KiB of a file, as text, and its size.
    static func headAndTail(_ path: String) -> (String, String, Int) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return ("", "", 0) }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        try? handle.seek(toOffset: 0)
        let head = String(decoding: (try? handle.read(upToCount: headBytes)) ?? Data(), as: UTF8.self)
        guard size > headBytes else { return (head, head, size) }
        try? handle.seek(toOffset: UInt64(size - headBytes))
        return (head, String(decoding: (try? handle.read(upToCount: headBytes)) ?? Data(), as: UTF8.self), size)
    }

    /// Whether a session has a conversation record at all: `"parentUuid":` near either end, else within its first 16 MiB.
    private static func hasChainRecord(_ path: String, head: String, tail: String, size: Int) -> Bool {
        let marker = #""parentUuid":"#
        if head.contains(marker) || tail.contains(marker) { return true }
        guard size > headBytes, let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        var seen = 0, carry = Data()
        while seen < 16 * 1_048_576 {
            guard let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty else { return false }
            if (carry + chunk).range(of: Data(marker.utf8)) != nil { return true }
            carry = chunk.suffix(16)
            seen += chunk.count
        }
        return true
    }

    /// The session this one says it continues in, when that note is newer than its last finished exchange.
    private static func continuedIn(_ tail: String) -> String? {
        guard tail.contains(#""type":"continued-in""#) else { return nil }
        for line in tail.split(separator: "\n").reversed() {
            let note = line.contains(#""type":"continued-in""#)
            guard note || line.contains(#""type":"user""#) || line.contains(#""type":"assistant""#),
                  let record = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if note { return (record["continuedInSessionId"] as? String).flatMap { UUID(uuidString: $0) != nil ? $0 : nil } }
            if record["type"] as? String == "assistant", record["isApiErrorMessage"] as? Bool != true,
               (record["message"] as? [String: Any])?["stop_reason"] is String { return nil }
            if record["type"] as? String == "user", record["isMeta"] as? Bool != true { return nil }
        }
        return nil
    }

    /// The directory a session recorded: a later relocation, else its first `cwd`.
    static func recordedDirectory(head: String, tail: String) -> String? {
        for line in tail.split(separator: "\n").reversed() where line.contains(#""relocatedCwd":"#) && line.contains(#""type":"relocated""#) {
            if let record = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
               record["type"] as? String == "relocated", let directory = record["relocatedCwd"] as? String { return directory }
        }
        for line in head.split(separator: "\n") where line.contains(#""cwd":"#) {
            if let record = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let directory = record["cwd"] as? String {
                return directory
            }
        }
        return nil
    }

    /// A line Claude Code would load: a user, assistant, attachment, or system record with an ID, outside a sidechain.
    private static func holdsMessages(_ path: String) -> Bool {
        anyLine(in: path, containing: [#""uuid""#]) { line in
            guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return false }
            return ["user", "assistant", "attachment", "system"].contains(record["type"] as? String ?? "") && record["uuid"] is String
                && record["isSidechain"] as? Bool != true
        }
    }

    private static func holdsConversation(_ path: String) -> Bool {
        var attributes = stat()
        guard lstat(path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else { return false }
        return anyLine(in: path, containing: [#""type":"user""#, #""type":"assistant""#]) { _ in true }
    }

    /// Whether a line of a regular file holds one of `markers` and satisfies `matches`, read a line at a time.
    private static func anyLine(in path: String, containing markers: [String], _ matches: (Data) -> Bool) -> Bool {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, let file = fdopen(descriptor, "r") else {
            close(descriptor)
            return false
        }
        defer { fclose(file) }
        var buffer: UnsafeMutablePointer<CChar>?
        var capacity = 0
        defer { free(buffer) }
        let needles = markers.map { Array($0.utf8) }
        while case let length = getline(&buffer, &capacity, file), length >= 0 {
            guard let buffer, needles.contains(where: { memmem(buffer, length, $0, $0.count) != nil }) else { continue }
            if matches(Data(bytes: buffer, count: length)) { return true }
        }
        return false
    }

    /// The first `"key":"value"` in `text`, decoded, as Claude Code finds it without parsing whole lines.
    static func firstString(_ text: String, _ key: String) -> String? { strings(text, key).first }
    static func lastString(_ text: String, _ key: String) -> String? { strings(text, key).last }

    private static func strings(_ text: String, _ key: String) -> [String] {
        var found: [(String.Index, String)] = []
        for pattern in ["\"\(key)\":\"", "\"\(key)\": \""] {
            var search = text.startIndex
            while let range = text.range(of: pattern, range: search..<text.endIndex) {
                var index = range.upperBound, escaped = false
                while index < text.endIndex {
                    let character = text[index]
                    if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { break }
                    index = text.index(after: index)
                }
                let raw = String(text[range.upperBound..<index])
                found.append((range.lowerBound, (try? JSONDecoder().decode(String.self, from: Data(("\"" + raw + "\"").utf8))) ?? raw))
                search = range.upperBound
            }
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
