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

    private enum SocketFailure: Error { case open, connect, read }

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
}
