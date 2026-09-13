import Foundation
import Network

public struct LocalHTTPRequest: Sendable {
    public let method: String
    public let target: String
    /// Header names are lowercase. Authentication has already been checked.
    public let headers: [String: String]
    public let body: Data

    public init(method: String, target: String, headers: [String: String], body: Data) {
        self.method = method; self.target = target; self.headers = headers; self.body = body
    }
}

public enum LoopbackHTTPError: Error, Equatable, Sendable {
    case stopped, alreadyStarting, disconnected, invalidResponse, responseAlreadyStarted, responseFinished
}

/// HTTP/1.1 for a local Claude client, with one request per connection. It binds
/// only 127.0.0.1 and never accepts browser-origin or unauthenticated requests.
public final class LoopbackHTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (LocalHTTPRequest, LocalHTTPResponseWriter) async -> Void
    public typealias BearerAuthorizer = @Sendable (String) async -> Bool
    private let state: LocalHTTPServerState

    public init(token: String, handler: @escaping Handler) {
        state = LocalHTTPServerState(authorization: .fixed(token), handler: handler, receiveTimeout: 30,
                                     authorizationTimeout: 5, maximumConnections: 32)
    }

    /// Keeps the client's normal OAuth authentication intact. The authorizer runs
    /// away from the Network queue and must cooperate with task cancellation.
    /// A request is closed after five seconds even if the authorizer does not return.
    public init(authorizeBearer: @escaping BearerAuthorizer, handler: @escaping Handler) {
        state = LocalHTTPServerState(authorization: .dynamic(authorizeBearer), handler: handler,
                                     receiveTimeout: 30, authorizationTimeout: 5, maximumConnections: 32)
    }

    // Test deadlines and admission without weakening the public defaults.
    init(token: String, receiveTimeout: TimeInterval, maximumConnections: Int = 32, handler: @escaping Handler) {
        state = LocalHTTPServerState(authorization: .fixed(token), handler: handler, receiveTimeout: receiveTimeout,
                                     authorizationTimeout: 5,
                                     maximumConnections: maximumConnections)
    }

    init(authorizeBearer: @escaping BearerAuthorizer, receiveTimeout: TimeInterval = 30,
         authorizationTimeout: TimeInterval, maximumConnections: Int = 32, handler: @escaping Handler) {
        state = LocalHTTPServerState(authorization: .dynamic(authorizeBearer), handler: handler,
                                     receiveTimeout: receiveTimeout, authorizationTimeout: authorizationTimeout,
                                     maximumConnections: maximumConnections)
    }

    deinit { state.stop() }
    public func start() async throws -> UInt16 { try await state.start() }
    public func stop() { state.stop() }
}

private enum LocalHTTPAuthorization: Sendable {
    case token([UInt8])
    case dynamic(LoopbackHTTPServer.BearerAuthorizer)

    static func fixed(_ token: String) -> Self {
        precondition(!token.isEmpty && token.utf8.count <= 4096 && token.utf8.allSatisfy { $0 > 32 && $0 < 127 })
        return .token(Array(token.utf8))
    }
}

/// Sends ordered chunks, awaiting Network.framework backpressure for every write.
/// Callers may write concurrently; operations retain their actor-admission order.
public actor LocalHTTPResponseWriter {
    private enum Phase { case initial, streaming, finished, aborted }
    private let connection: NWConnection
    private let closed: @Sendable () -> Void
    private var phase = Phase.initial
    private var bodyPermitted = true
    private var tail: Task<Void, Error>?

    fileprivate init(connection: NWConnection, closed: @escaping @Sendable () -> Void) {
        self.connection = connection; self.closed = closed
    }

    public func writeHead(status: Int, headers: [String: String] = [:]) async throws {
        guard phase == .initial else { throw LoopbackHTTPError.responseAlreadyStarted }
        guard (200...599).contains(status) else { throw LoopbackHTTPError.invalidResponse }
        var fields: [String: String] = [:]
        let controlled: Set<String> = ["content-length", "transfer-encoding", "connection", "keep-alive", "trailer", "upgrade"]
        for (name, value) in headers {
            let key = name.lowercased()
            guard validHeaderName(key), validHeaderValue(value), fields[key] == nil else { throw LoopbackHTTPError.invalidResponse }
            if !controlled.contains(key) { fields[key] = value }
        }
        bodyPermitted = status != 204 && status != 304
        fields["connection"] = "close"
        if bodyPermitted { fields["transfer-encoding"] = "chunked" }
        else { fields["content-length"] = "0" }
        let head = "HTTP/1.1 \(status) \(statusReason(status))\r\n" +
            fields.keys.sorted().map { "\($0): \(fields[$0]!)\r\n" }.joined() + "\r\n"
        guard head.utf8.count <= 32_768 else { throw LoopbackHTTPError.invalidResponse }
        phase = .streaming
        try await enqueue(Data(head.utf8))
    }

    public func write(_ data: Data) async throws {
        guard phase == .streaming else { throw LoopbackHTTPError.responseFinished }
        guard !data.isEmpty else { return }
        guard bodyPermitted else { throw LoopbackHTTPError.invalidResponse }
        var frame = Data((String(data.count, radix: 16) + "\r\n").utf8)
        frame.append(data); frame.append(Data("\r\n".utf8))
        try await enqueue(frame)
    }

    public func finish() async throws {
        if phase == .finished { if let tail { try await tail.value }; return }
        guard phase == .streaming else { throw LoopbackHTTPError.responseFinished }
        phase = .finished
        do {
            try await enqueue(bodyPermitted ? Data("0\r\n\r\n".utf8) : Data(), final: true)
            closed()
        } catch {
            connection.cancel(); closed(); throw error
        }
    }

    public func abort() async {
        guard phase != .aborted else { return }
        phase = .aborted; tail?.cancel(); connection.cancel(); closed()
    }

    fileprivate func completeHandler() async {
        do {
            if phase == .initial {
                try await writeHead(status: 500, headers: ["content-type": "text/plain; charset=utf-8"])
                try await write(Data("Local request handler did not send a response.\n".utf8))
            }
            if phase == .streaming { try await finish() }
        } catch { await abort() }
    }

    private func enqueue(_ data: Data, final: Bool = false) async throws {
        let previous = tail
        let connection = self.connection
        let task = Task<Void, Error> {
            if let previous { try await previous.value }
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, contentContext: .defaultMessage, isComplete: final,
                                completion: .contentProcessed { error in
                    if error != nil { continuation.resume(throwing: LoopbackHTTPError.disconnected) }
                    else { continuation.resume() }
                })
            }
        }
        tail = task
        do { try await task.value }
        catch { connection.cancel(); closed(); throw error }
    }
}

private final class LocalHTTPServerState: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Claudock.loopback-http")
    private let authorization: LocalHTTPAuthorization
    private let handler: LoopbackHTTPServer.Handler
    private let receiveTimeout: TimeInterval
    private let authorizationTimeout: TimeInterval
    private let maximumConnections: Int
    private var listener: NWListener?
    private var port: UInt16?
    private var stopped = false
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var connections: [UUID: LocalHTTPConnection] = [:]

    init(authorization: LocalHTTPAuthorization, handler: @escaping LoopbackHTTPServer.Handler,
         receiveTimeout: TimeInterval, authorizationTimeout: TimeInterval, maximumConnections: Int) {
        self.authorization = authorization; self.handler = handler
        self.receiveTimeout = receiveTimeout; self.authorizationTimeout = authorizationTimeout
        self.maximumConnections = maximumConnections
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if self.stopped { continuation.resume(throwing: LoopbackHTTPError.stopped); return }
                if let port = self.port { continuation.resume(returning: port); return }
                guard self.listener == nil else { continuation.resume(throwing: LoopbackHTTPError.alreadyStarting); return }
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener; self.startContinuation = continuation
                    listener.stateUpdateHandler = { [weak self, weak listener] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            guard let port = listener?.port?.rawValue else { return }
                            self.port = port
                            self.startContinuation?.resume(returning: port); self.startContinuation = nil
                        case .failed(let error):
                            self.startContinuation?.resume(throwing: error); self.startContinuation = nil
                            self.stopOnQueue()
                        case .cancelled:
                            self.startContinuation?.resume(throwing: LoopbackHTTPError.stopped); self.startContinuation = nil
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        guard let self, !self.stopped, let port = self.port,
                              self.connections.count < self.maximumConnections else { connection.cancel(); return }
                        let id = UUID()
                        let context = LocalHTTPConnection(connection: connection, queue: self.queue, port: port,
                                                          authorization: self.authorization, receiveTimeout: self.receiveTimeout,
                                                          authorizationTimeout: self.authorizationTimeout,
                                                          handler: self.handler, closed: { [weak self] in self?.connections[id] = nil })
                        self.connections[id] = context
                        context.start()
                    }
                    listener.start(queue: self.queue)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stop() { queue.async { self.stopOnQueue() } }

    private func stopOnQueue() {
        guard !stopped else { return }
        stopped = true
        startContinuation?.resume(throwing: LoopbackHTTPError.stopped); startContinuation = nil
        listener?.cancel(); listener = nil; port = nil
        for connection in Array(connections.values) { connection.close(cancelHandler: true) }
        connections.removeAll()
    }
}

private final class LocalHTTPConnection: @unchecked Sendable {
    private static let headerLimit = 32_768
    private static let bodyLimit = 32 * 1024 * 1024
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let port: UInt16
    private let authorization: LocalHTTPAuthorization
    private let receiveTimeout: TimeInterval
    private let authorizationTimeout: TimeInterval
    private let handler: LoopbackHTTPServer.Handler
    private let closed: () -> Void
    private var buffer = Data()
    private var parsed: (method: String, target: String, headers: [String: String], length: Int)?
    private var deadline: DispatchWorkItem?
    private var authorizationDeadline: DispatchWorkItem?
    private var authorizationTask: Task<Void, Never>?
    private var authorizationStarted = false
    private var authorized = false
    private var receivePending = false
    private var handlerTask: Task<Void, Never>?
    private var dispatched = false
    private var closing = false
    private var rejecting = false

    init(connection: NWConnection, queue: DispatchQueue, port: UInt16, authorization: LocalHTTPAuthorization,
         receiveTimeout: TimeInterval, authorizationTimeout: TimeInterval,
         handler: @escaping LoopbackHTTPServer.Handler, closed: @escaping () -> Void) {
        self.connection = connection; self.queue = queue; self.port = port; self.authorization = authorization
        self.receiveTimeout = receiveTimeout; self.authorizationTimeout = authorizationTimeout
        self.handler = handler; self.closed = closed
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close(cancelHandler: true)
            default: break
            }
        }
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, !self.dispatched, !self.closing else { return }
            self.reject(408)
        }
        self.deadline = deadline
        queue.asyncAfter(deadline: .now() + receiveTimeout, execute: deadline)
        connection.start(queue: queue)
        receive()
    }

    func close(cancelHandler: Bool) {
        guard !closing else { return }
        closing = true; deadline?.cancel(); deadline = nil
        authorizationDeadline?.cancel(); authorizationDeadline = nil
        authorizationTask?.cancel(); authorizationTask = nil
        if cancelHandler { handlerTask?.cancel() }
        connection.stateUpdateHandler = nil
        connection.cancel(); closed()
    }

    private func receive() {
        guard !closing, !rejecting, !receivePending else { return }
        receivePending = true
        // Once the declared body is complete, read only one byte to detect EOF
        // or forbidden pipelining while authorization/the handler is pending.
        let maximumLength = dispatched ? 1 : min(65_536, parsed.map { max(1, $0.length - buffer.count + 1) } ?? 65_536)
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { [weak self] data, _, complete, error in
            guard let self else { return }
            self.receivePending = false
            guard !self.closing, !self.rejecting else { return }
            if error != nil || complete { self.close(cancelHandler: true); return }
            if self.dispatched {
                if !(data?.isEmpty ?? true) { self.close(cancelHandler: true) }
                else { self.receive() }
                return
            }
            if let data, !data.isEmpty { self.buffer.append(data) }
            if self.consume() { return }
            self.receive()
        }
    }

    /// Returns true when this connection dispatched or rejected its single request.
    private func consume() -> Bool {
        guard !closing, !rejecting, !dispatched else { return true }
        if parsed == nil {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > Self.headerLimit { reject(431); return true }
                return false
            }
            let length = end.upperBound
            guard length <= Self.headerLimit else { reject(431); return true }
            do { parsed = try parseHead(Data(buffer[..<end.lowerBound])) }
            catch let error as HTTPRejection { reject(error.status); return true }
            catch { reject(400); return true }
            buffer.removeSubrange(..<length)
        }
        guard let parsed else { return false }
        guard buffer.count <= parsed.length else { reject(400); return true }
        if !authorizationStarted { beginAuthorization(headers: parsed.headers) }
        guard authorized else { return false }
        guard buffer.count == parsed.length else { return false }
        dispatched = true; deadline?.cancel(); deadline = nil
        var headers = parsed.headers
        if case .dynamic = authorization {
            headers["authorization"] = nil; headers["x-api-key"] = nil
        }
        let request = LocalHTTPRequest(method: parsed.method, target: parsed.target, headers: headers, body: buffer)
        buffer = Data()
        let writer = LocalHTTPResponseWriter(connection: connection, closed: { [weak self] in
            guard let self else { return }
            self.queue.async { self.close(cancelHandler: false) }
        })
        let handler = self.handler
        handlerTask = Task {
            await handler(request, writer)
            await writer.completeHandler()
        }
        receive()
        return true
    }

    private func beginAuthorization(headers: [String: String]) {
        authorizationStarted = true
        guard case .dynamic(let authorize) = authorization else { authorized = true; return }
        // parseHead has already validated the single, bounded Bearer value.
        let bearer = String(headers["authorization"]!.dropFirst(7))
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, !self.authorized, !self.closing, !self.rejecting else { return }
            self.reject(408)
        }
        authorizationDeadline = deadline
        queue.asyncAfter(deadline: .now() + authorizationTimeout, execute: deadline)
        let queue = self.queue
        authorizationTask = Task.detached { [weak self] in
            guard !Task.isCancelled else { return }
            let accepted = await authorize(bearer)
            guard !Task.isCancelled else { return }
            queue.async { [weak self] in
                guard let self, !self.closing, !self.rejecting else { return }
                self.authorizationDeadline?.cancel(); self.authorizationDeadline = nil
                self.authorizationTask = nil
                guard accepted else {
                    self.reject(403, detail: "Claudock could not verify the default Claude login. Unlock Keychain or restart claude-auto after signing in again.")
                    return
                }
                self.authorized = true
                if !self.consume() { self.receive() }
            }
        }
    }

    private func reject(_ status: Int, detail: String? = nil) {
        guard !closing, !rejecting else { return }
        rejecting = true
        deadline?.cancel(); deadline = nil
        authorizationDeadline?.cancel(); authorizationDeadline = nil
        authorizationTask?.cancel(); authorizationTask = nil
        // A stalled reader must not keep an admission slot after rejection.
        let closeDeadline = DispatchWorkItem { [weak self] in self?.close(cancelHandler: true) }
        deadline = closeDeadline
        queue.asyncAfter(deadline: .now() + 1, execute: closeDeadline)
        let body = Data(((detail ?? statusReason(status)) + "\n").utf8)
        var response = Data("HTTP/1.1 \(status) \(statusReason(status))\r\nConnection: close\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        response.append(body)
        // No request handler is invoked for protocol or authorization errors.
        connection.send(content: response, contentContext: .defaultMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.close(cancelHandler: true) })
    }

    private func parseHead(_ data: Data) throws -> (method: String, target: String, headers: [String: String], length: Int) {
        guard let text = String(data: data, encoding: .ascii) else { throw HTTPRejection(400) }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2] == "HTTP/1.1" else { throw HTTPRejection(400) }
        let method = String(requestLine[0]), target = String(requestLine[1])
        guard method == "POST" || method == "GET" else { throw HTTPRejection(405) }
        guard allowedTarget(method: method, target: target) else { throw HTTPRejection(404) }
        var headers: [String: String] = [:]
        let unique: Set<String> = ["host", "content-length", "transfer-encoding", "authorization", "x-api-key", "origin"]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPRejection(400) }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard validHeaderName(name), validHeaderValue(value) else { throw HTTPRejection(400) }
            if let previous = headers[name] {
                guard !unique.contains(name) else { throw HTTPRejection(400) }
                headers[name] = previous + ", " + value
            } else { headers[name] = value }
        }
        guard headers["host"] == "127.0.0.1:\(port)" else { throw HTTPRejection(400) }
        guard headers["origin"] == nil else { throw HTTPRejection(403) }
        guard headers["transfer-encoding"] == nil else { throw HTTPRejection(400) }
        guard headers["expect"] == nil else { throw HTTPRejection(417) }
        let bearer = headers["authorization"].flatMap { value -> String? in
            guard value.count >= 7, value.prefix(7).lowercased() == "bearer " else { return nil }
            return String(value.dropFirst(7))
        }
        let apiKey = headers["x-api-key"]
        switch authorization {
        case .token(let token):
            let bearerOK = constantTimeEqual(bearer ?? "", token)
            let apiKeyOK = constantTimeEqual(apiKey ?? "", token)
            // If a client sends both credential forms, both must match this server.
            guard (bearerOK || apiKeyOK), headers["authorization"] == nil || bearerOK,
                  apiKey == nil || apiKeyOK else { throw HTTPRejection(401) }
        case .dynamic:
            guard apiKey == nil, let bearer, !bearer.isEmpty, bearer.utf8.count <= 16_384,
                  bearer.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw HTTPRejection(401) }
        }
        let length: Int
        if let value = headers["content-length"] {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let parsed = Int(value) else { throw HTTPRejection(400) }
            guard parsed <= Self.bodyLimit else { throw HTTPRejection(413) }
            length = parsed
        } else {
            guard method == "GET" else { throw HTTPRejection(411) }
            length = 0
        }
        guard method != "GET" || length == 0 else { throw HTTPRejection(400) }
        return (method, target, headers, length)
    }
}

private struct HTTPRejection: Error {
    let status: Int
    init(_ status: Int) { self.status = status }
}

private func validHeaderName(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ||
            "!#$%&'*+-.^_`|~".utf8.contains($0)
    }
}

private func validHeaderValue(_ value: String) -> Bool {
    value.utf8.allSatisfy { $0 == 9 || ($0 >= 32 && $0 != 127) }
}

private func constantTimeEqual(_ candidate: String, _ expected: [UInt8]) -> Bool {
    let bytes = Array(candidate.utf8)
    var difference = bytes.count ^ expected.count
    for index in expected.indices { difference |= Int(expected[index] ^ (index < bytes.count ? bytes[index] : 0)) }
    return difference == 0
}

private func allowedTarget(method: String, target: String) -> Bool {
    guard target.hasPrefix("/"), !target.contains("#"),
          target.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { return false }
    if method == "POST" {
        return ["/v1/messages", "/v1/messages?beta=true", "/v1/messages/count_tokens", "/v1/messages/count_tokens?beta=true"].contains(target)
    }
    guard let parts = URLComponents(string: target), parts.percentEncodedPath == "/v1/models",
          parts.scheme == nil, parts.host == nil else { return false }
    let items = parts.queryItems ?? []
    guard Set(items.map(\.name)).count == items.count else { return false }
    return items.allSatisfy {
        guard let value = $0.value, !value.isEmpty else { return false }
        if $0.name == "limit" { return value.utf8.allSatisfy({ (48...57).contains($0) }) && Int(value).map { (1...1000).contains($0) } == true }
        return ($0.name == "before_id" || $0.name == "after_id") && value.utf8.count <= 1024
    }
}

private func statusReason(_ status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 201: return "Created"
    case 204: return "No Content"
    case 304: return "Not Modified"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 408: return "Request Timeout"
    case 411: return "Length Required"
    case 413: return "Content Too Large"
    case 417: return "Expectation Failed"
    case 431: return "Request Header Fields Too Large"
    case 500: return "Internal Server Error"
    case 502: return "Bad Gateway"
    case 503: return "Service Unavailable"
    default: return "Response"
    }
}
