import XCTest
@testable import UsageCore

private actor GatewayCalls {
    var values: [String] = []
    func add(_ value: String) { values.append(value) }
}

final class BalancedGatewayTests: XCTestCase {
    private let profiles = [Profile(command: "claude-a", configDirectory: "/tmp/a"), Profile(command: "claude-b", configDirectory: "/tmp/b")]

    private func dependencies(_ handler: @escaping (LocalHTTPRequest, Credentials) async throws -> GatewayUpstreamResponse) -> GatewayDependencies {
        GatewayDependencies(profiles: { self.profiles }, usage: { _ in throw MonitorError.permissionDenied },
                            credential: { profile in Credentials(accessToken: profile.command, expiresAt: nil, plan: "max") }, request: handler)
    }

    private func request(_ port: UInt16, session: String = "one") -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages?beta=true")!)
        request.httpMethod = "POST"; request.timeoutInterval = 5
        request.setValue("Bearer fixture-local", forHTTPHeaderField: "Authorization")
        request.setValue(session, forHTTPHeaderField: "x-claude-code-session-id")
        request.httpBody = Data(#"{"model":"claude-fable-5","messages":[{"role":"user","content":"hello"}]}"#.utf8)
        return request
    }

    func testQuotaFailoverIsTransparentAndKeepsSessionAffinity() async throws {
        let calls = GatewayCalls()
        let gateway = BalancedGateway(dependencies: dependencies { incoming, credential in
            await calls.add(credential.accessToken)
            XCTAssertEqual(incoming.headers["x-claude-code-session-id"], "one")
            if credential.accessToken == "claude-a" {
                return GatewayUpstreamResponse(status: 429, headers: ["retry-after": "3600"], forward: { _ in XCTFail("Rejected response must not be sent before failover") }, cancel: {})
            }
            return GatewayUpstreamResponse(status: 200, headers: ["content-type": "text/event-stream"], forward: { write in
                try await write(Data("event: message_start\ndata: {\"type\":\"message_start\"}\n\n".utf8))
                try await write(Data("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n".utf8))
            }, cancel: {})
        })
        let server = LoopbackHTTPServer(token: "fixture-local") { await gateway.handle($0, writer: $1) }
        let port = try await server.start(); defer { server.stop() }
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        for _ in 0..<2 {
            let (data, response) = try await session.data(for: request(port))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("message_stop"))
        }
        let recorded = await calls.values, failures = await gateway.failoverCount
        XCTAssertEqual(recorded, ["claude-a", "claude-b", "claude-b"])
        XCTAssertEqual(failures, 1)
    }

    func testPartialOutputIsNeverReplayedToAnotherAccount() async throws {
        let calls = GatewayCalls()
        let gateway = BalancedGateway(dependencies: dependencies { _, credential in
            await calls.add(credential.accessToken)
            return GatewayUpstreamResponse(status: 200, headers: ["content-type": "text/event-stream"], forward: { write in
                try await write(Data("event: content_block_delta\ndata: {\"text\":\"started\"}\n\n".utf8))
                throw MonitorError.network
            }, cancel: {})
        })
        let server = LoopbackHTTPServer(token: "fixture-local") { await gateway.handle($0, writer: $1) }
        let port = try await server.start(); defer { server.stop() }
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        do { _ = try await session.data(for: request(port)) } catch { /* A truncated stream closes the connection. */ }
        let recorded = await calls.values, failures = await gateway.failoverCount
        XCTAssertEqual(recorded, ["claude-a"])
        XCTAssertEqual(failures, 0)
    }

    func testDispatchedNetworkFailureIsNotReplayed() async throws {
        let calls = GatewayCalls()
        let gateway = BalancedGateway(dependencies: dependencies { _, credential in
            await calls.add(credential.accessToken); throw MonitorError.network
        })
        let server = LoopbackHTTPServer(token: "fixture-local") { await gateway.handle($0, writer: $1) }
        let port = try await server.start(); defer { server.stop() }
        let (data, response) = try await URLSession.shared.data(for: request(port))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 502)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("claude-a"))
        let recorded = await calls.values
        XCTAssertEqual(recorded, ["claude-a"])
    }

    func testFirstSSEQuotaFrameSwitchesBeforeOutput() async throws {
        let calls = GatewayCalls()
        let gateway = BalancedGateway(dependencies: dependencies { _, credential in
            await calls.add(credential.accessToken)
            let body = credential.accessToken == "claude-a"
                ? "event: error\r\ndata: {\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\"}}\r\n\r\n"
                : "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
            return GatewayUpstreamResponse(status: 200, headers: ["content-type": "text/event-stream"], forward: { write in
                // Deliberately split the event across network chunks.
                for chunk in body.utf8 { try await write(Data([chunk])) }
            }, cancel: {})
        })
        let server = LoopbackHTTPServer(token: "fixture-local") { await gateway.handle($0, writer: $1) }
        let port = try await server.start(); defer { server.stop() }
        let (data, response) = try await URLSession.shared.data(for: request(port))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
        let recorded = await calls.values
        XCTAssertEqual(recorded, ["claude-a", "claude-b"])
    }

    func testMidstreamQuotaIsPreservedButNextRequestChangesAccount() async throws {
        let calls = GatewayCalls()
        let body = "event: message_start\ndata: {\"type\":\"message_start\"}\n\nevent: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\"}}\n\n"
        let gateway = BalancedGateway(dependencies: dependencies { _, credential in
            await calls.add(credential.accessToken)
            return GatewayUpstreamResponse(status: 200, headers: ["content-type": "text/event-stream"], forward: { write in
                try await write(Data(body.utf8))
            }, cancel: {})
        })
        let server = LoopbackHTTPServer(token: "fixture-local") { await gateway.handle($0, writer: $1) }
        let port = try await server.start(); defer { server.stop() }
        for _ in 0..<2 {
            let (data, _) = try await URLSession.shared.data(for: request(port))
            XCTAssertEqual(String(decoding: data, as: UTF8.self), body)
        }
        let recorded = await calls.values
        XCTAssertEqual(recorded, ["claude-a", "claude-b"])
    }
}
