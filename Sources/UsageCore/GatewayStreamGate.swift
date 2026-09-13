import Foundation

struct StreamRejection: Error { let status: Int }

/// Inspects complete SSE frames without delaying accepted stream output. Only
/// the first frame is buffered (64 KiB maximum) to detect pre-output rejections.
actor GatewayStreamGate {
    private let writer: LocalHTTPResponseWriter
    private let status: Int
    private let headers: [String: String]
    private let blocked: @Sendable (Int) async -> Void
    private let isSSE: Bool
    private var prelude = Data()
    private var scanner = SSERejectionScanner()
    private var pendingFirst: Bool
    private(set) var committed = false

    init(writer: LocalHTTPResponseWriter, status: Int, headers: [String: String],
         blocked: @escaping @Sendable (Int) async -> Void) {
        self.writer = writer; self.status = status; self.headers = headers; self.blocked = blocked
        isSSE = status == 200 && (headers["content-type"]?.lowercased().contains("text/event-stream") ?? false)
        pendingFirst = isSSE
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        if pendingFirst {
            prelude.append(data)
            let events = scanner.append(data)
            if let first = events.first {
                if let status = first { throw StreamRejection(status: status) }
                pendingFirst = false
                for status in events.dropFirst().compactMap({ $0 }) { await blocked(status) }
            } else if prelude.count > 65_536 { pendingFirst = false }
            else { return }
            try await start()
            try await writer.write(prelude); prelude.removeAll()
            return
        }
        try await start()
        try await writer.write(data)
        if isSSE { for status in scanner.append(data).compactMap({ $0 }) { await blocked(status) } }
    }

    func finish() async throws {
        try await start()
        if !prelude.isEmpty { try await writer.write(prelude); prelude.removeAll() }
        try await writer.finish()
    }

    private func start() async throws {
        if !committed {
            committed = true
            try await writer.writeHead(status: status, headers: headers)
        }
    }
}

struct SSERejectionScanner {
    private var line = Data()
    private var frame = Data()
    private var oversized = false

    /// nil marks a non-rejection frame, preserving first-frame ordering.
    mutating func append(_ chunk: Data) -> [Int?] {
        var result: [Int?] = []
        for byte in chunk {
            if byte == 10 {
                if line.last == 13 { line.removeLast() }
                if line.isEmpty {
                    result.append(oversized ? nil : Self.rejection(frame))
                    frame.removeAll(keepingCapacity: true); oversized = false
                } else if !oversized {
                    if frame.count + line.count > 65_536 { oversized = true; frame.removeAll(keepingCapacity: true) }
                    else { frame.append(line); frame.append(10) }
                }
                line.removeAll(keepingCapacity: true)
            } else if line.count < 65_537 { line.append(byte) }
            else { oversized = true }
        }
        return result
    }

    private static func rejection(_ frame: Data) -> Int? {
        guard let text = String(data: frame, encoding: .utf8) else { return nil }
        let data = text.split(separator: "\n").filter { $0.hasPrefix("data:") }
            .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
              object["type"] as? String == "error", let error = object["error"] as? [String: Any] else { return nil }
        switch error["type"] as? String {
        case "rate_limit_error": return 429
        case "authentication_error": return 401
        default: return nil
        }
    }
}
