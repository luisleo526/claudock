import Foundation

/// Discovers declared wrappers without starting a shell or evaluating shell code.
public enum ProfileDiscovery {
    public static func discover(home: String = NSHomeDirectory()) -> [Profile] {
        var reader = Reader(home: home)
        // Interactive login zsh startup order. Only literal source targets are followed.
        for name in [".zshenv", ".zprofile", ".zshrc"] {
            reader.read(URL(fileURLWithPath: home).appendingPathComponent(name).path, depth: 0)
        }
        var profiles = reader.functions
        profiles.merge(reader.aliases) { _, alias in alias }
        profiles["claude"] = Profile(command: "claude", configDirectory: reader.defaultIssue == nil ? URL(fileURLWithPath: home).appendingPathComponent(".claude").path : "", discoveryNote: reader.defaultIssue)
        return profiles.values.sorted {
            if $0.command == $1.command { return false }
            if $0.command == "claude" { return true }
            if $1.command == "claude" { return false }
            return $0.command.localizedStandardCompare($1.command) == .orderedAscending
        }
    }

    private struct Reader {
        let home: String
        var functions: [String: Profile] = [:]
        var aliases: [String: Profile] = [:]
        var activeFiles: Set<String> = []
        var readCount = 0
        var totalBytes = 0
        var defaultIssue: String?

        mutating func read(_ path: String, depth: Int) {
            guard depth <= 12, readCount < 64, totalBytes < 2_097_152 else { return }
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard !isSensitiveSource(path), !isSensitiveSource(url.path), !activeFiles.contains(url.path) else { return }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { return }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? handle.close() }
            // A bounded read also protects against unusually large generated shell files.
            guard let data = try? handle.read(upToCount: 524_289), data.count <= 524_288,
                  let source = String(data: data, encoding: .utf8) else { return }
            readCount += 1
            totalBytes += data.count
            activeFiles.insert(url.path)
            defer { activeFiles.remove(url.path) }
            let tokens = tokenize(source)
            var index = 0
            while index < tokens.count {
                let isExportArgument = index > 0 && tokens[index - 1] == "export"
                if isCommandPosition(tokens, at: index) || isExportArgument {
                    if tokens[index].hasPrefix("CLAUDE_CONFIG_DIR=") || tokens[index].hasPrefix("CLAUDE_SECURESTORAGE_CONFIG_DIR=") {
                        defaultIssue = "The shell overrides Claude's default config or credential storage directory. Import this account with its explicit config folder."
                    }
                }
                guard isCommandPosition(tokens, at: index) else { index += 1; continue }
                if let declaration = functionDeclaration(tokens, at: index) {
                    if isProfileCommand(declaration.name) {
                        functions[declaration.name] = profile(declaration.name, body: declaration.body)
                    } else if declaration.name == "claude", declaration.body.contains(where: { $0.hasPrefix("CLAUDE_CONFIG_DIR=") || $0.hasPrefix("CLAUDE_SECURESTORAGE_CONFIG_DIR=") || $0 == "_claude-native" }) {
                        defaultIssue = "The default claude function overrides its config or credential storage directory. Import it with an explicit config folder."
                    }
                    // Never treat declarations or source commands inside function bodies as startup code.
                    index = declaration.end
                    continue
                }
                let token = tokens[index]
                if token == "alias" {
                    var next = index + 1
                    while next < tokens.count, !isSeparator(tokens[next]) {
                        let raw = tokens[next]
                        if let equal = raw.firstIndex(of: "=") {
                            let name = String(raw[..<equal])
                            if isProfileCommand(name), let body = literal(String(raw[raw.index(after: equal)...]), home: home) {
                                aliases[name] = profile(name, body: tokenize(body))
                            } else if isProfileCommand(name) {
                                aliases[name] = unresolved(name)
                            }
                        }
                        next += 1
                    }
                    index = next
                    continue
                }
                if token == "unalias" || token == "unfunction" || token == "unset" {
                    var next = index + 1
                    let removesFunctions = token == "unfunction" || (token == "unset" && next < tokens.count && tokens[next] == "-f")
                    while next < tokens.count, !isSeparator(tokens[next]) {
                        if token == "unalias" { aliases.removeValue(forKey: tokens[next]) }
                        if removesFunctions { functions.removeValue(forKey: tokens[next]) }
                        next += 1
                    }
                    index = next
                    continue
                }
                if (token == "source" || token == "."), index + 1 < tokens.count,
                   let target = literal(tokens[index + 1], home: home), !target.isEmpty {
                    // Relative literal includes are resolved against the containing file.
                    let sourcePath = target.hasPrefix("/") ? target : url.deletingLastPathComponent().appendingPathComponent(target).path
                    read(sourcePath, depth: depth + 1)
                    index += 2
                    continue
                }
                index += 1
            }
        }

        func profile(_ command: String, body: [String]) -> Profile {
            var candidates: Set<String> = []
            var hasDynamicPath = false
            // Keep the legacy serialized isVertex flag as the external-provider
            // marker so older registries remain readable during migration.
            let cloudKeys = ["CLAUDE_CODE_USE_VERTEX=", "CLAUDE_CODE_USE_BEDROCK=", "CLAUDE_CODE_USE_FOUNDRY="]
            let vertex = body.enumerated().contains { index, token in
                guard let key = cloudKeys.first(where: { token.hasPrefix($0) }), isAssignmentPosition(body, at: index),
                      let value = literal(String(token.dropFirst(key.count)), home: home) else { return false }
                return ["1", "true"].contains(value.lowercased())
            }
            if body.contains(where: { $0.hasPrefix("CLAUDE_SECURESTORAGE_CONFIG_DIR=") }) {
                return Profile(command: command, configDirectory: "", isVertex: vertex, discoveryNote: "This wrapper overrides CLAUDE_SECURESTORAGE_CONFIG_DIR, which requires separate credential storage mapping and cannot be resolved safely.")
            }
            for (index, token) in body.enumerated() {
                var pathToken: String?
                if token.hasPrefix("CLAUDE_CONFIG_DIR="), isAssignmentPosition(body, at: index) {
                    pathToken = String(token.dropFirst("CLAUDE_CONFIG_DIR=".count))
                } else if token == "_claude-native", isCommandPosition(body, at: index) {
                    pathToken = index + 1 < body.count ? body[index + 1] : ""
                }
                if let raw = pathToken {
                    if let path = literal(raw, home: home), path.hasPrefix("/") {
                        candidates.insert(path)
                    } else {
                        hasDynamicPath = true
                    }
                }
            }
            guard !hasDynamicPath, candidates.count == 1, let directory = candidates.first else {
                return unresolved(command, vertex: vertex)
            }
            return Profile(command: command, configDirectory: directory, isVertex: vertex)
        }

        func unresolved(_ command: String, vertex: Bool = false) -> Profile {
            Profile(command: command, configDirectory: "", isVertex: vertex,
                    discoveryNote: "Config directory could not be resolved safely from this shell wrapper. Use a literal CLAUDE_CONFIG_DIR or _claude-native path.")
        }
    }

    private static func isProfileCommand(_ name: String) -> Bool {
        guard name.hasPrefix("claude-"), name.count > 7 else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0) }
    }

    private static func isSensitiveSource(_ path: String) -> Bool {
        path.split(separator: "/").contains { part in
            let name = String(part).lowercased()
            return name == ".env" || name.hasPrefix(".env.") || name.contains("private-env") || name.contains("private_env") ||
                name.range(of: #"(^|[-_.])(keys?|secrets?|credentials)([-_.]|$)"#, options: .regularExpression) != nil
        }
    }

    private static func isSeparator(_ token: String) -> Bool {
        ["\n", ";", "&&", "||", "|", "&", "}", ")"].contains(token)
    }

    private static func isCommandPosition(_ tokens: [String], at index: Int) -> Bool {
        index == 0 || isSeparator(tokens[index - 1]) || ["{", "(", "then", "else", "do"].contains(tokens[index - 1])
    }

    private static func isAssignmentPosition(_ tokens: [String], at index: Int) -> Bool {
        var start = index
        while start > 0, !isCommandPosition(tokens, at: start) { start -= 1 }
        if start == index { return true }
        if ["export", "env"].contains(tokens[start]) { return true }
        return tokens[start..<index].allSatisfy { $0.range(of: #"\A[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil }
    }

    private struct Declaration {
        let name: String
        let body: [String]
        let end: Int
    }

    private static func functionDeclaration(_ tokens: [String], at start: Int) -> Declaration? {
        var index = start
        let hasKeyword = tokens[index] == "function"
        if hasKeyword { index += 1 }
        guard index < tokens.count else { return nil }
        let name = tokens[index]
        guard !name.isEmpty, name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_-".unicodeScalars.contains($0) }) else { return nil }
        index += 1
        if index + 1 < tokens.count, tokens[index] == "(", tokens[index + 1] == ")" {
            index += 2
        } else if !hasKeyword { return nil }
        while index < tokens.count, tokens[index] == "\n" { index += 1 }
        guard index < tokens.count, tokens[index] == "{" || tokens[index] == "(" else { return nil }
        let opening = tokens[index]
        let closing = opening == "{" ? "}" : ")"
        let bodyStart = index + 1
        var depth = 1
        index += 1
        while index < tokens.count {
            if tokens[index] == opening { depth += 1 }
            if tokens[index] == closing { depth -= 1 }
            if depth == 0 { return Declaration(name: name, body: Array(tokens[bodyStart..<index]), end: index + 1) }
            index += 1
        }
        // A malformed declaration must not expose its body as top-level startup commands.
        return Declaration(name: name, body: [], end: tokens.count)
    }

    /// Decodes shell quotes and only HOME/tilde expansions; substitutions and globbing are rejected.
    private static func literal(_ raw: String, home: String) -> String? {
        let characters = Array(raw)
        var result = ""
        var quote: Character?
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "'", quote != "\"" {
                quote = quote == "'" ? nil : "'"
                index += 1
                continue
            }
            if character == "\"", quote != "'" {
                quote = quote == "\"" ? nil : "\""
                index += 1
                continue
            }
            if character == "\\", quote != "'" {
                index += 1
                guard index < characters.count else { return nil }
                if quote == "\"", !"$`\"\\\n".contains(characters[index]) { result.append("\\") }
                if characters[index] != "\n" { result.append(characters[index]) }
                index += 1
                continue
            }
            if character == "$", quote != "'" {
                let remainder = String(characters[index...])
                if remainder.hasPrefix("${HOME}") {
                    result += home
                    index += 7
                    continue
                }
                if remainder.hasPrefix("$HOME"), index + 5 == characters.count || !isVariableCharacter(characters[index + 5]) {
                    result += home
                    index += 5
                    continue
                }
                return nil
            }
            if character == "`", quote != "'" { return nil }
            if quote == nil, "*?[]".contains(character) { return nil }
            if character == "~", index == 0, quote == nil {
                guard characters.count == 1 || characters[1] == "/" else { return nil }
                result += home
            } else {
                result.append(character)
            }
            index += 1
        }
        return quote == nil ? result : nil
    }

    private static func isVariableCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// Small lexical scanner: quoted strings/substitutions stay opaque; heredoc contents are skipped.
    private static func tokenize(_ source: String) -> [String] {
        let characters = Array(source)
        var tokens: [String] = []
        var index = 0
        var pendingHeredocs: [(delimiter: String, stripTabs: Bool)] = []
        var expectsHeredoc: Bool?
        while index < characters.count {
            let character = characters[index]
            if character == " " || character == "\t" || character == "\r" { index += 1; continue }
            if character == "\\", index + 1 < characters.count, characters[index + 1] == "\n" { index += 2; continue }
            if character == "#" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if character == "\n" {
                tokens.append("\n")
                index += 1
                for heredoc in pendingHeredocs {
                    while index < characters.count {
                        let start = index
                        while index < characters.count, characters[index] != "\n" { index += 1 }
                        var line = String(characters[start..<index])
                        if heredoc.stripTabs { line = String(line.drop(while: { $0 == "\t" })) }
                        if index < characters.count { index += 1 }
                        if line == heredoc.delimiter { break }
                    }
                }
                pendingHeredocs.removeAll()
                continue
            }
            if "{}();&|<>".contains(character) {
                var symbol = String(character)
                index += 1
                if index < characters.count, characters[index] == character, "&|<>".contains(character) {
                    symbol.append(character)
                    index += 1
                }
                if symbol == "<<", index < characters.count, characters[index] == "<" { symbol = "<<<"; index += 1 }
                if symbol == "<<", index < characters.count, characters[index] == "-" { symbol += "-"; index += 1 }
                if symbol == "<<" || symbol == "<<-" { expectsHeredoc = symbol == "<<-" }
                tokens.append(symbol)
                continue
            }
            let start = index
            var quote: Character?
            var substitutionClosers: [Character] = []
            while index < characters.count {
                let current = characters[index]
                if current == "\\", quote != "'" { index = min(index + 2, characters.count); continue }
                if current == "'", quote != "\"", quote != "`" { quote = quote == "'" ? nil : "'"; index += 1; continue }
                if current == "\"", quote != "'", quote != "`" { quote = quote == "\"" ? nil : "\""; index += 1; continue }
                if current == "`", quote != "'" { quote = quote == "`" ? nil : "`"; index += 1; continue }
                if current == "$", quote != "'", index + 1 < characters.count, "({".contains(characters[index + 1]) {
                    substitutionClosers.append(characters[index + 1] == "(" ? ")" : "}")
                    index += 2
                    continue
                }
                if let last = substitutionClosers.last, current == last { substitutionClosers.removeLast(); index += 1; continue }
                if quote == nil, substitutionClosers.isEmpty, current.isWhitespace || "{}();&|<>".contains(current) { break }
                index += 1
            }
            let token = String(characters[start..<index])
            tokens.append(token)
            if let stripTabs = expectsHeredoc {
                // Heredoc delimiters only undergo quote removal, never variable expansion.
                let delimiter = token.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\\", with: "")
                pendingHeredocs.append((delimiter, stripTabs))
                expectsHeredoc = nil
            }
        }
        return tokens
    }
}
