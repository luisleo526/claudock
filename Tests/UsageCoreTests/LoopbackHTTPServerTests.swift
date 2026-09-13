import Foundation
import Darwin
import XCTest
@testable import UsageCore

final class LoopbackHTTPServerTests: XCTestCase {
    private let token = "fixture-local-gateway-token-123456789"

    private actor Recorder {
        var requests: [LocalHTTPRequest] = []
        func append(_ request: LocalHTTPRequest) { requests.append(request) }
    }

    private actor BearerStore {
        var current = "fixture-oauth-before-rotation"
        var candidates: [String] = []
        func rotate(to value: String) { current = value }
        func authorize(_ candidate: String) -> Bool {
            candidates.append(candidate)
            return candidate == current
        }
    }

    private actor AuthorizationGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() { opened = true; continuation?.resume(); continuation = nil }
    }

    private enum SocketFailure: Error { case open, connect, read }

    // Models a synchronous credential backend inside the injected async closure.
    private static func blockingCredentialRead(_ release: DispatchSemaphore) -> Bool {
        release.wait(timeout: .now() + 3) == .success
    }

    private func socket(port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketFailure.open }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { close(fd); throw SocketFailure.connect }
        return fd
    }

    private func raw(port: UInt16, text: String) async throws -> String {
        try await Task.detached { [self] in
            let fd = try socket(port: port)
            defer { close(fd) }
            let data = Data(text.utf8)
            data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                    if count < 0 && errno == EINTR { continue }
                    if count <= 0 { break }
                    offset += count
                }
            }
            var received = Data(), buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = Darwin.recv(fd, &buffer, buffer.count, 0)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                received.append(contentsOf: buffer.prefix(count))
                if received.count > 1_048_576 { throw SocketFailure.read }
            }
            return String(decoding: received, as: UTF8.self)
        }.value
    }

    private func http(port: UInt16, target: String = "/v1/messages", auth: String? = nil,
                      apiKey: String? = nil, method: String = "POST", body: Data = Data("{}".utf8)) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(target)")!)
        request.httpMethod = method
        if method == "POST" { request.httpBody = body }
        if let auth { request.setValue("Bearer " + auth, forHTTPHeaderField: "Authorization") }
        if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 4
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    func testAuthenticatedRequestsReachHandlerAndStreamChunksInOrder() async throws {
        let recorder = Recorder()
        let server = LoopbackHTTPServer(token: token) { request, writer in
            await recorder.append(request)
            do {
                try await writer.writeHead(status: 200, headers: ["Content-Type": "text/event-stream", "Connection": "keep-alive", "Content-Length": "999"])
                try await writer.write(Data("one\n".utf8))
                try await writer.write(Data("two\n".utf8))
                try await writer.write(Data("three\n".utf8))
                try await writer.finish()
                try await writer.finish()
            } catch { await writer.abort() }
        }
        defer { server.stop() }
        let port = try await server.start()
        XCTAssertGreaterThan(port, 0)
        let (data, response) = try await http(port: port, auth: token, body: Data("{\"model\":\"fixture\"}".utf8))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "one\ntwo\nthree\n")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Connection")?.lowercased(), "close")
        XCTAssertNil(response.value(forHTTPHeaderField: "Content-Length"))
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].method, "POST")
        XCTAssertEqual(requests[0].target, "/v1/messages")
        XCTAssertEqual(requests[0].body, Data("{\"model\":\"fixture\"}".utf8))
        XCTAssertEqual(requests[0].headers["host"], "127.0.0.1:\(port)")
    }

    func testResponseWireUsesOrderedChunksAndOneTerminator() async throws {
        let server = LoopbackHTTPServer(token: token) { _, writer in
            do {
                try await writer.writeHead(status: 200, headers: ["Content-Length": "999", "Transfer-Encoding": "identity"])
                try await writer.write(Data("one".utf8))
                try await writer.write(Data("two".utf8))
                try await writer.finish()
                try await writer.finish()
            } catch { await writer.abort() }
        }
        defer { server.stop() }
        let port = try await server.start()
        let response = try await raw(port: port, text: "POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\nContent-Length: 0\r\n\r\n")
        XCTAssertTrue(response.contains("transfer-encoding: chunked\r\n"))
        XCTAssertFalse(response.lowercased().contains("content-length:"))
        XCTAssertTrue(response.hasSuffix("\r\n\r\n3\r\none\r\n3\r\ntwo\r\n0\r\n\r\n"))
    }

    func testAPIKeyAuthAndAllowedCountTokensAndModelsTargets() async throws {
        let recorder = Recorder()
        let server = LoopbackHTTPServer(token: token) { request, writer in
            await recorder.append(request)
            try? await writer.writeHead(status: 200)
            try? await writer.write(Data("ok".utf8))
            try? await writer.finish()
        }
        defer { server.stop() }
        let port = try await server.start()
        for target in ["/v1/messages?beta=true", "/v1/messages/count_tokens", "/v1/messages/count_tokens?beta=true"] {
            let (_, response) = try await http(port: port, target: target, apiKey: token)
            XCTAssertEqual(response.statusCode, 200)
        }
        let (_, models) = try await http(port: port, target: "/v1/models?limit=20&after_id=fixture", auth: token, method: "GET")
        XCTAssertEqual(models.statusCode, 200)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests.last!.body.isEmpty)
    }

    func testMissingWrongOrConflictingAuthNeverReachesHandler() async throws {
        let recorder = Recorder()
        let server = LoopbackHTTPServer(token: token) { request, writer in
            await recorder.append(request)
            await writer.abort()
        }
        defer { server.stop() }
        let port = try await server.start()
        for auth in [nil, "wrong-token", token + "x", String(token.dropLast())] as [String?] {
            let (_, response) = try await http(port: port, auth: auth)
            XCTAssertEqual(response.statusCode, 401)
        }
        let (_, conflicting) = try await http(port: port, auth: token, apiKey: "wrong-token")
        XCTAssertEqual(conflicting.statusCode, 401)
        let requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testProtocolRejectionsDoNotReachHandler() async throws {
        let recorder = Recorder()
        let server = LoopbackHTTPServer(token: token) { request, writer in
            await recorder.append(request)
            await writer.abort()
        }
        defer { server.stop() }
        let port = try await server.start()
        let ordinary = "Host: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\n"
        let variants: [(String, String, Int)] = [
            ("POST /v1/messages HTTP/1.1", ordinary + "Host: 127.0.0.1:\(port)\r\nContent-Length: 0\r\n", 400),
            ("POST /v1/messages HTTP/1.1", ordinary + "Content-Length: 0\r\ncontent-length: 0\r\n", 400),
            ("POST /v1/messages HTTP/1.1", ordinary + "authorization: Bearer \(token)\r\nContent-Length: 0\r\n", 400),
            ("POST /v1/messages HTTP/1.1", ordinary + "Transfer-Encoding: chunked\r\nContent-Length: 0\r\n", 400),
            ("POST /v1/messages HTTP/1.1", ordinary + "Origin: http://example.com\r\nContent-Length: 0\r\n", 403),
            ("POST /v1/messages HTTP/1.1", "Host: localhost:\(port)\r\nAuthorization: Bearer \(token)\r\nContent-Length: 0\r\n", 400),
            ("POST /v1/messages HTTP/1.1", ordinary, 411),
            ("POST /v1/messages HTTP/1.1", ordinary + "Content-Length: -1\r\n", 400),
            ("POST /v1/messages HTTP/1.1", ordinary + "Content-Length: 33554433\r\n", 413),
            ("POST /v1/messages HTTP/1.1", ordinary + "Content-Length: 0\r\nX-Large: " + String(repeating: "a", count: 32768) + "\r\n", 431),
            ("POST /v1/messages HTTP/1.0", ordinary + "Content-Length: 0\r\n", 400),
            ("PUT /v1/messages HTTP/1.1", ordinary + "Content-Length: 0\r\n", 405),
            ("POST http://example.com/v1/messages HTTP/1.1", ordinary + "Content-Length: 0\r\n", 404),
            ("POST /v1/messages?beta=false HTTP/1.1", ordinary + "Content-Length: 0\r\n", 404),
            ("GET /v1/models?url=http://example.com HTTP/1.1", ordinary, 404),
            ("GET /v1/models?limit=20&limit=30 HTTP/1.1", ordinary, 404),
            ("POST /v1/messages HTTP/1.1", ordinary + " folded: header\r\nContent-Length: 0\r\n", 400)
        ]
        for (line, headers, status) in variants {
            let reply = try await raw(port: port, text: line + "\r\n" + headers + "\r\n")
            XCTAssertTrue(reply.hasPrefix("HTTP/1.1 \(status) "), "Expected \(status), got \(reply.prefix(40))")
            XCTAssertFalse(reply.contains(token))
        }
        let requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testIncompleteHeaderOrBodyTimesOutWithoutHandler() async throws {
        let recorder = Recorder()
        let server = LoopbackHTTPServer(token: token, receiveTimeout: 0.1) { request, writer in
            await recorder.append(request); await writer.abort()
        }
        defer { server.stop() }
        let port = try await server.start()
        let incompleteHeader = try await raw(port: port, text: "POST /v1/messages HTTP/1.1\r\nHost:")
        XCTAssertTrue(incompleteHeader.hasPrefix("HTTP/1.1 408 "))
        let incompleteBody = try await raw(port: port, text: "POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\nContent-Length: 10\r\n\r\nx")
        XCTAssertTrue(incompleteBody.hasPrefix("HTTP/1.1 408 "))
        let requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testDisconnectCancelsActiveHandler() async throws {
        let started = expectation(description: "Handler started")
        let cancelled = expectation(description: "Handler cancelled")
        let server = LoopbackHTTPServer(token: token) { _, writer in
            started.fulfill()
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch is CancellationError { cancelled.fulfill() }
            catch {}
            await writer.abort()
        }
        defer { server.stop() }
        let port = try await server.start()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
        request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = Task { try await session.data(for: request) }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        _ = try? await task.value
        await fulfillment(of: [cancelled], timeout: 3)
    }

    func testHandlerWithNoResponseGetsBoundedInternalError() async throws {
        let server = LoopbackHTTPServer(token: token) { _, _ in }
        defer { server.stop() }
        let port = try await server.start()
        let (data, response) = try await http(port: port, auth: token)
        XCTAssertEqual(response.statusCode, 500)
        XCTAssertLessThan(data.count, 100)
    }

    func testConnectionCapRejectsExcessAndReleasesDisconnectedSlots() async throws {
        let recorder = Recorder()
        let server = LoopbackHTTPServer(token: token, receiveTimeout: 2, maximumConnections: 1) { request, writer in
            await recorder.append(request)
            try? await writer.writeHead(status: 200)
            try? await writer.finish()
        }
        defer { server.stop() }
        let port = try await server.start()
        let held = try socket(port: port)
        try await Task.sleep(nanoseconds: 50_000_000)
        let excess = try await raw(port: port, text: "POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\nContent-Length: 0\r\n\r\n")
        XCTAssertFalse(excess.contains("200 OK"))
        close(held)
        try await Task.sleep(nanoseconds: 50_000_000)
        let (_, response) = try await http(port: port, auth: token)
        XCTAssertEqual(response.statusCode, 200)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testStoppedServerCannotRestart() async throws {
        let server = LoopbackHTTPServer(token: token) { _, writer in await writer.abort() }
        _ = try await server.start()
        server.stop()
        do { _ = try await server.start(); XCTFail("Expected stopped server") }
        catch { XCTAssertEqual(error as? LoopbackHTTPError, .stopped) }
    }

    func testDynamicAuthorizationUsesCurrentBearerAndRemovesCredentialHeaders() async throws {
        let store = BearerStore(), recorder = Recorder()
        let server = LoopbackHTTPServer(authorizeBearer: { await store.authorize($0) }) { request, writer in
            await recorder.append(request)
            try? await writer.writeHead(status: 200)
            try? await writer.write(Data("authorized".utf8))
            try? await writer.finish()
        }
        defer { server.stop() }
        let port = try await server.start()
        let old = "fixture-oauth-before-rotation", new = "fixture-oauth-after-rotation"
        let (_, before) = try await http(port: port, auth: old)
        XCTAssertEqual(before.statusCode, 200)
        await store.rotate(to: new)
        let (rejection, stale) = try await http(port: port, auth: old)
        XCTAssertEqual(stale.statusCode, 403)
        XCTAssertEqual(String(decoding: rejection, as: UTF8.self),
                       "Claudock could not verify the default Claude login. Unlock Keychain or restart claude-auto after signing in again.\n")
        XCTAssertFalse(String(decoding: rejection, as: UTF8.self).contains(old))
        let (_, after) = try await http(port: port, auth: new)
        XCTAssertEqual(after.statusCode, 200)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertNil(request.headers["authorization"])
            XCTAssertNil(request.headers["x-api-key"])
            XCTAssertEqual(request.body, Data("{}".utf8))
        }
        let candidates = await store.candidates
        XCTAssertEqual(candidates, [old, old, new])
    }

    func testDynamicMalformedRequestsNeverInvokeAuthorizerOrHandler() async throws {
        let store = BearerStore(), recorder = Recorder()
        let server = LoopbackHTTPServer(authorizeBearer: { await store.authorize($0) }) { request, writer in
            await recorder.append(request); await writer.abort()
        }
        defer { server.stop() }
        let port = try await server.start()
        let bearer = "Authorization: Bearer fixture-oauth-before-rotation\r\n"
        let host = "Host: 127.0.0.1:\(port)\r\n"
        let variants: [(String, String, Int)] = [
            ("/v1/messages", host + "Content-Length: 0\r\n", 401),
            ("/v1/messages", host + "x-api-key: fixture-oauth-before-rotation\r\nContent-Length: 0\r\n", 401),
            ("/v1/messages", host + bearer + "x-api-key: fixture-oauth-before-rotation\r\nContent-Length: 0\r\n", 401),
            ("/v1/messages", host + bearer + "authorization: Bearer another\r\nContent-Length: 0\r\n", 400),
            ("/v1/messages", host + "Authorization: Basic fixture\r\nContent-Length: 0\r\n", 401),
            ("/v1/messages", host + "Authorization: Bearer \r\nContent-Length: 0\r\n", 401),
            ("/v1/messages", host + "Authorization: Bearer has space\r\nContent-Length: 0\r\n", 401),
            ("/v1/messages", host + "Authorization: Bearer has\ttab\r\nContent-Length: 0\r\n", 401),
            ("/v1/messages", host + "Authorization: Bearer " + String(repeating: "a", count: 16385) + "\r\nContent-Length: 0\r\n", 401),
            ("/v1/messages", host + bearer + "Origin: http://example.com\r\nContent-Length: 0\r\n", 403),
            ("/v1/messages", host + bearer + "Content-Length: 33554433\r\n", 413),
            ("/v1/messages", host + bearer + "Transfer-Encoding: chunked\r\nContent-Length: 0\r\n", 400),
            ("/v1/messages", host + bearer + "Content-Length: 0\r\nX-Large: " + String(repeating: "a", count: 32768) + "\r\n", 431),
            ("/not-permitted", host + bearer + "Content-Length: 0\r\n", 404),
            ("/v1/messages", "Host: example.com\r\n" + bearer + "Content-Length: 0\r\n", 400)
        ]
        for (target, headers, status) in variants {
            let reply = try await raw(port: port, text: "POST \(target) HTTP/1.1\r\n" + headers + "\r\n")
            XCTAssertTrue(reply.hasPrefix("HTTP/1.1 \(status) "), "Expected \(status), got \(reply.prefix(40))")
            XCTAssertFalse(reply.contains("fixture-oauth"))
        }
        let candidates = await store.candidates, requests = await recorder.requests
        XCTAssertTrue(candidates.isEmpty)
        XCTAssertTrue(requests.isEmpty)
    }

    func testDynamicBearerLengthBoundary() async throws {
        let store = BearerStore(), recorder = Recorder()
        let maximumBearer = String(repeating: "a", count: 16_384)
        await store.rotate(to: maximumBearer)
        let server = LoopbackHTTPServer(authorizeBearer: { await store.authorize($0) }) { request, writer in
            await recorder.append(request)
            try? await writer.writeHead(status: 200); try? await writer.finish()
        }
        defer { server.stop() }
        let port = try await server.start()
        let (_, accepted) = try await http(port: port, auth: maximumBearer)
        XCTAssertEqual(accepted.statusCode, 200)
        let (_, rejected) = try await http(port: port, auth: maximumBearer + "a")
        XCTAssertEqual(rejected.statusCode, 401)
        let candidates = await store.candidates, requests = await recorder.requests
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.utf8.count, 16_384)
        XCTAssertEqual(requests.count, 1)
    }

    func testBlockingAuthorizerDoesNotBlockNetworkQueueOrRunHandlerBeforeAcceptance() async throws {
        let started = expectation(description: "Authorizer started")
        let release = DispatchSemaphore(value: 0), recorder = Recorder()
        let server = LoopbackHTTPServer(authorizeBearer: { _ in
            started.fulfill()
            return Self.blockingCredentialRead(release)
        }) { request, writer in
            await recorder.append(request)
            try? await writer.writeHead(status: 200); try? await writer.finish()
        }
        defer { release.signal(); server.stop() }
        let port = try await server.start()
        let pending = Task { try await http(port: port, auth: "fixture-held-bearer") }
        await fulfillment(of: [started], timeout: 2)
        let requestsBefore = await recorder.requests
        XCTAssertTrue(requestsBefore.isEmpty)
        // This response requires the Network queue while authorizeBearer is blocked.
        let reply = try await raw(port: port, text: "POST /not-permitted HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 0\r\n\r\n")
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 404 "))
        release.signal()
        let (_, response) = try await pending.value
        XCTAssertEqual(response.statusCode, 200)
        let requestsAfter = await recorder.requests
        XCTAssertEqual(requestsAfter.count, 1)
    }

    func testAuthorizationTimeoutCancelsAuthorizerAndReleasesAdmissionSlot() async throws {
        let cancelled = expectation(description: "Timed out authorizer cancelled")
        let recorder = Recorder()
        let server = LoopbackHTTPServer(authorizeBearer: { candidate in
            if candidate == "fixture-current" { return true }
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch is CancellationError { cancelled.fulfill() }
            catch {}
            return true
        }, authorizationTimeout: 0.1, maximumConnections: 1) { request, writer in
            await recorder.append(request)
            try? await writer.writeHead(status: 200); try? await writer.finish()
        }
        defer { server.stop() }
        let port = try await server.start()
        let (_, timeout) = try await http(port: port, auth: "fixture-stalled")
        XCTAssertEqual(timeout.statusCode, 408)
        await fulfillment(of: [cancelled], timeout: 2)
        let (_, next) = try await http(port: port, auth: "fixture-current")
        XCTAssertEqual(next.statusCode, 200)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testUncooperativeAuthorizerCannotRetainSlotOrDispatchAfterTimeout() async throws {
        let gate = AuthorizationGate(), recorder = Recorder()
        let ended = expectation(description: "Late authorization returned")
        let server = LoopbackHTTPServer(authorizeBearer: { candidate in
            if candidate == "fixture-current" { return true }
            await gate.wait() // Deliberately ignores cancellation.
            ended.fulfill()
            return true
        }, authorizationTimeout: 0.1, maximumConnections: 1) { request, writer in
            await recorder.append(request)
            try? await writer.writeHead(status: 200); try? await writer.finish()
        }
        defer { server.stop() }
        let port = try await server.start()
        let (_, timeout) = try await http(port: port, auth: "fixture-stalled")
        XCTAssertEqual(timeout.statusCode, 408)
        let (_, next) = try await http(port: port, auth: "fixture-current")
        XCTAssertEqual(next.statusCode, 200)
        await gate.open()
        await fulfillment(of: [ended], timeout: 2)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testDisconnectDuringIncompleteBodyCancelsPendingAuthorization() async throws {
        let started = expectation(description: "Pending authorization started")
        let cancelled = expectation(description: "Disconnected authorizer cancelled")
        let recorder = Recorder()
        let server = LoopbackHTTPServer(authorizeBearer: { _ in
            started.fulfill()
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch is CancellationError { cancelled.fulfill() }
            catch {}
            return true
        }) { request, writer in await recorder.append(request); await writer.abort() }
        defer { server.stop() }
        let port = try await server.start(), fd = try socket(port: port)
        let request = Data("POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer fixture-pending\r\nContent-Length: 1048576\r\n\r\nx".utf8)
        let sent = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        XCTAssertEqual(sent, request.count)
        await fulfillment(of: [started], timeout: 2)
        close(fd)
        await fulfillment(of: [cancelled], timeout: 2)
        let requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testServerStopCancelsPendingAuthorizationAfterCompleteBody() async throws {
        let started = expectation(description: "Pending authorization started")
        let cancelled = expectation(description: "Stopped authorizer cancelled")
        let recorder = Recorder()
        let server = LoopbackHTTPServer(authorizeBearer: { _ in
            started.fulfill()
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch is CancellationError { cancelled.fulfill() }
            catch {}
            return true
        }) { request, writer in await recorder.append(request); await writer.abort() }
        defer { server.stop() }
        let port = try await server.start()
        let pending = Task { try await http(port: port, auth: "fixture-pending") }
        await fulfillment(of: [started], timeout: 2)
        server.stop()
        await fulfillment(of: [cancelled], timeout: 2)
        _ = try? await pending.value
        let requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testClientCancellationAfterCompleteBodyCancelsPendingAuthorization() async throws {
        let started = expectation(description: "Pending authorization started")
        let cancelled = expectation(description: "Client cancelled authorizer")
        let recorder = Recorder()
        let server = LoopbackHTTPServer(authorizeBearer: { _ in
            started.fulfill()
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch is CancellationError { cancelled.fulfill() }
            catch {}
            return true
        }) { request, writer in await recorder.append(request); await writer.abort() }
        defer { server.stop() }
        let port = try await server.start()
        let pending = Task { try await http(port: port, auth: "fixture-pending") }
        await fulfillment(of: [started], timeout: 2)
        pending.cancel()
        _ = try? await pending.value
        await fulfillment(of: [cancelled], timeout: 2)
        let requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testBodyReceiveDeadlineRemainsActiveDuringAuthorization() async throws {
        let cancelled = expectation(description: "Body deadline cancels authorizer")
        let recorder = Recorder()
        let server = LoopbackHTTPServer(authorizeBearer: { _ in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch is CancellationError { cancelled.fulfill() }
            catch {}
            return true
        }, receiveTimeout: 0.1, authorizationTimeout: 2) { request, writer in
            await recorder.append(request); await writer.abort()
        }
        defer { server.stop() }
        let port = try await server.start()
        let reply = try await raw(port: port, text: "POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer fixture-pending\r\nContent-Length: 10\r\n\r\nx")
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 408 "))
        await fulfillment(of: [cancelled], timeout: 2)
        let requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
    }
}
