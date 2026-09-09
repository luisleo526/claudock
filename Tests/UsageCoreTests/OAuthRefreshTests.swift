import Foundation
import XCTest
@testable import UsageCore

final class OAuthRefreshTests: XCTestCase {
    func testNullableRefreshLifetimePreservesExpiryAndZeroMeansExpiredNow() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldExpiry = now.addingTimeInterval(3600)
        let old = Credentials(accessToken: "fixture-access", expiresAt: now, plan: "max",
                              refreshToken: "fixture-refresh", refreshTokenExpiresAt: oldExpiry,
                              scopes: ["user:profile"])
        let null = Data(#"{"access_token":"fixture-new","expires_in":3600,"refresh_token_expires_in":null}"#.utf8)
        XCTAssertEqual(try OAuthRefreshResult.parse(null, previous: old, now: now).refreshTokenExpiresAt, oldExpiry)
        let zero = Data(#"{"access_token":"fixture-new","expires_in":3600,"refresh_token_expires_in":0}"#.utf8)
        XCTAssertEqual(try OAuthRefreshResult.parse(zero, previous: old, now: now).refreshTokenExpiresAt, now)
    }
    private static let instant = Date(timeIntervalSince1970: 1_800_000_000)

    private func credentialData(access: String = "fixture-old-access", refresh: String? = "fixture-old-refresh",
                                refreshExpiry: Date? = nil, clientID: String? = "fixture-client",
                                scopes: [String] = ["user:profile", "user:inference"]) throws -> Data {
        var oauth: [String: Any] = [
            "accessToken": access, "expiresAt": Self.instant.addingTimeInterval(-60).timeIntervalSince1970 * 1000,
            "scopes": scopes, "subscriptionType": "max", "rateLimitTier": "fixture-tier",
            "futureField": ["preserve": true]
        ]
        if let refresh { oauth["refreshToken"] = refresh }
        if let refreshExpiry { oauth["refreshTokenExpiresAt"] = refreshExpiry.timeIntervalSince1970 * 1000 }
        if let clientID { oauth["clientId"] = clientID }
        return try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": oauth, "mcpOAuth": ["fixture-server": ["token": "unrelated-fixture-secret"]],
            "organizationUuid": "fixture-organization", "unrecognizedRoot": [1, 2, 3]
        ])
    }

    private func result(previous: Credentials) throws -> OAuthRefreshResult {
        try OAuthRefreshResult.parse(Data(#"{"access_token":"fixture-new-access","refresh_token":"fixture-new-refresh","expires_in":3600,"scope":"user:profile user:inference","token_type":"Bearer"}"#.utf8), previous: previous, now: Self.instant)
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claudock-refresh-test-\(UUID().uuidString)")
        let config = root.appendingPathComponent("account", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Fixture(profile: Profile(command: "claude-fixture", configDirectory: config.path), data: try credentialData())
        try await body(fixture)
    }

    private final class Fixture: @unchecked Sendable {
        let profile: Profile
        private let lock = NSLock()
        private var contents: Data?
        private var source: CredentialSource = .keychain(service: "fixture")
        private var clock = OAuthRefreshTests.instant
        private var readCount = 0
        private var writeCount = 0
        private var exchangeCount = 0
        private var failingWrites: Set<Int> = []
        private var cancelledWrites: Set<Int> = []
        private var ignoredWrites: Set<Int> = []

        init(profile: Profile, data: Data) { self.profile = profile; contents = data }

        private func locked<T>(_ operation: () throws -> T) rethrows -> T {
            lock.lock(); defer { lock.unlock() }
            return try operation()
        }

        func read(_ requested: Profile) throws -> StoredCredentials {
            try locked {
                readCount += 1
                guard requested == profile, let contents else { throw MonitorError.noCredentials }
                return StoredCredentials(profile: profile, data: contents, source: source)
            }
        }

        func write(_ data: Data, replacing expected: StoredCredentials) throws {
            try locked {
                writeCount += 1
                if cancelledWrites.contains(writeCount) { throw CancellationError() }
                if failingWrites.contains(writeCount) { throw MonitorError.credentialWriteFailed }
                guard expected.profile == profile, expected.data == contents, expected.source == source else { throw MonitorError.credentialChanged }
                if ignoredWrites.contains(writeCount) { return }
                contents = data
            }
        }

        func dependency(exchange: @escaping (Credentials) async throws -> OAuthRefreshResult) -> RefreshDependencies {
            RefreshDependencies(read: { try self.read($0) }, write: { try self.write($0, replacing: $1) }, exchange: {
                self.locked { self.exchangeCount += 1 }
                return try await exchange($0)
            }, now: { self.locked { self.clock } })
        }

        func replace(_ data: Data?) { locked { contents = data } }
        func changeSource(_ replacement: CredentialSource) { locked { source = replacement } }
        func failWrites(_ calls: Set<Int>) { locked { failingWrites = calls } }
        func cancelWrites(_ calls: Set<Int>) { locked { cancelledWrites = calls } }
        func ignoreWrites(_ calls: Set<Int>) { locked { ignoredWrites = calls } }
        func advance(_ seconds: TimeInterval) { locked { clock = clock.addingTimeInterval(seconds) } }
        var data: Data? { locked { contents } }
        var writes: Int { locked { writeCount } }
        var exchanges: Int { locked { exchangeCount } }
    }

    private func assertAsyncError(_ expected: MonitorError, file: StaticString = #filePath, line: UInt = #line,
                                  operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? MonitorError, expected, file: file, line: line) }
    }

    func testRefreshRequestPreservesClientAndScopesWithoutPuttingSecretsInURLOrHeaders() throws {
        let previous = try Credentials.parse(credentialData(scopes: ["user:profile", "user:inference", "user:fixture"]))
        let request = try OAuthRefreshHTTP.request(credentials: previous)
        XCTAssertEqual(request.url?.absoluteString, "https://platform.claude.com/v1/oauth/token")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.url?.query)
        XCTAssertFalse(String(describing: request.allHTTPHeaderFields).contains("fixture-old-refresh"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["grant_type": "refresh_token", "refresh_token": "fixture-old-refresh",
                              "client_id": "fixture-client", "scope": "user:profile user:inference user:fixture"])
        for absentClient in [nil, ""] as [String?] {
            let defaultClient = try Credentials.parse(credentialData(clientID: absentClient))
            let fallbackBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(OAuthRefreshHTTP.request(credentials: defaultClient).httpBody)) as? [String: String])
            XCTAssertEqual(fallbackBody["client_id"], OAuthRefreshHTTP.clientID)
            XCTAssertNil(fallbackBody["expires_in"])
        }
    }

    func testRotationMergesOnlyOAuthFieldsAndPreservesUnknownAccountData() throws {
        let data = try credentialData()
        let previous = try Credentials.parse(data)
        let response = Data(#"{"access_token":"fixture-new-access","refresh_token":"fixture-rotated-refresh","expires_in":7200,"refresh_token_expires_in":86400,"scope":"user:profile user:inference user:fixture","token_type":"bearer"}"#.utf8)
        let rotated = try OAuthRefreshResult.parse(response, previous: previous, now: Self.instant)
        let merged = try XCTUnwrap(JSONSerialization.jsonObject(with: rotated.merging(into: data)) as? [String: Any])
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(merged["mcpOAuth"] as? NSDictionary, original["mcpOAuth"] as? NSDictionary)
        XCTAssertEqual(merged["organizationUuid"] as? String, "fixture-organization")
        XCTAssertEqual(merged["unrecognizedRoot"] as? [Int], [1, 2, 3])
        let oauth = try XCTUnwrap(merged["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(oauth["accessToken"] as? String, "fixture-new-access")
        XCTAssertEqual(oauth["refreshToken"] as? String, "fixture-rotated-refresh")
        XCTAssertEqual(oauth["clientId"] as? String, "fixture-client")
        XCTAssertEqual(oauth["subscriptionType"] as? String, "max")
        XCTAssertEqual(oauth["rateLimitTier"] as? String, "fixture-tier")
        XCTAssertEqual(oauth["futureField"] as? [String: Bool], ["preserve": true])
        XCTAssertEqual(oauth["scopes"] as? [String], ["user:profile", "user:inference", "user:fixture"])
        XCTAssertEqual(rotated.expiresAt, Self.instant.addingTimeInterval(7200))
        XCTAssertEqual(rotated.refreshTokenExpiresAt, Self.instant.addingTimeInterval(86400))
    }

    func testOmittedRotationAndScopesPreservePreviousValues() throws {
        let expiry = Self.instant.addingTimeInterval(86400)
        let previous = try Credentials.parse(credentialData(refreshExpiry: expiry))
        let parsed = try OAuthRefreshResult.parse(Data(#"{"access_token":"fixture-new-access","expires_in":3600}"#.utf8), previous: previous, now: Self.instant)
        XCTAssertEqual(parsed.refreshToken, previous.refreshToken)
        XCTAssertEqual(parsed.scopes, previous.scopes)
        XCTAssertEqual(parsed.refreshTokenExpiresAt, expiry)
    }

    func testMalformedResponsesAreRejectedWithoutLeakingBody() throws {
        let previous = try Credentials.parse(credentialData())
        let invalid = [
            #"{"access_token":"fixture-body-secret","expires_in":true}"#,
            #"{"access_token":"fixture-body-secret","expires_in":"3600"}"#,
            #"{"access_token":"fixture-body-secret","expires_in":0}"#,
            #"{"access_token":"fixture-body-secret","expires_in":-1}"#,
            #"{"access_token":"fixture-body-secret","expires_in":315360001}"#,
            #"{"access_token":"fixture-body-secret","expires_in":3600,"token_type":"mac"}"#,
            #"{"access_token":"fixture-body-secret","expires_in":3600,"refresh_token":null}"#,
            #"{"access_token":"fixture-body-secret","expires_in":3600,"scope":["user:profile"]}"#,
            #"{"access_token":"fixture-body-secret","expires_in":3600,"refresh_token_expires_in":false}"#,
            #"{"access_token":"fixture\nbody-secret","expires_in":3600}"#,
            #"{"access_token":"","expires_in":3600}"#,
            "not JSON fixture-body-secret"
        ]
        for (index, response) in invalid.enumerated() {
            XCTAssertThrowsError(try OAuthRefreshResult.parse(Data(response.utf8), previous: previous, now: Self.instant), "Malformed fixture case \(index)") { error in
                XCTAssertEqual(error as? MonitorError, .refreshFailed)
                XCTAssertFalse(error.localizedDescription.contains("fixture-body-secret"))
            }
        }
        XCTAssertThrowsError(try OAuthRefreshResult.parse(Data(repeating: 0x20, count: 131_073), previous: previous, now: Self.instant))
    }

    func testInitialCredentialWithoutUsageScopeIsNotExchanged() throws {
        let previous = try Credentials.parse(credentialData(scopes: ["user:inference"]))
        XCTAssertThrowsError(try OAuthRefreshHTTP.request(credentials: previous)) {
            XCTAssertEqual($0 as? MonitorError, .permissionDenied)
        }
    }

    func testHTTPFailuresDifferentiateInvalidGrantPermissionsAndRateLimitWithoutSecrets() throws {
        let previous = try Credentials.parse(credentialData())
        for (status, body, expected) in [
            (400, #"{"error":"invalid_grant","error_description":"fixture-server-secret"}"#, MonitorError.loginRequired),
            (401, #"{"error":{"type":"invalid_grant","message":"fixture-server-secret"}}"#, .loginRequired),
            (403, "fixture-server-secret", .permissionDenied),
            (429, "fixture-server-secret", .rateLimited(Self.instant.addingTimeInterval(600))),
            (500, #"{"error":"invalid_grant","error_description":"fixture-server-secret"}"#, .refreshFailed),
            (400, #"{"error":"invalid_scope","error_description":"fixture-server-secret"}"#, .refreshFailed)
        ] {
            let response = try XCTUnwrap(HTTPURLResponse(url: OAuthRefreshHTTP.endpoint, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "600"]))
            XCTAssertThrowsError(try OAuthRefreshHTTP.interpret(data: Data(body.utf8), response: response, previous: previous, now: Self.instant)) {
                XCTAssertEqual($0 as? MonitorError, expected)
                XCTAssertFalse($0.localizedDescription.contains("fixture-server-secret"))
            }
        }
    }

    func testUsageRenewsExpiredOrUnauthorizedExactlyOnce() async throws {
        let previous = try Credentials.parse(credentialData())
        let renewed = try Credentials.parse(credentialData(access: "fixture-renewed-access", refresh: "fixture-renewed-refresh"))
        let expected = UsageSnapshot(windows: [UsageWindow(id: "five_hour", title: "Session", percent: 42, resetsAt: nil)], fetchedAt: Self.instant)
        for initialError in [MonitorError.expired, .unauthorized] {
            var requests = 0, renewals = 0
            let snapshot = try await UsageClient.fetchRenewing(credentials: previous, request: { credentials in
                requests += 1
                if requests == 1 { throw initialError }
                XCTAssertEqual(credentials.accessToken, renewed.accessToken)
                return expected
            }, renew: { credentials in
                renewals += 1
                XCTAssertTrue(credentials.hasSameTokens(as: previous))
                return renewed
            })
            XCTAssertEqual(snapshot, expected)
            XCTAssertEqual(requests, 2)
            XCTAssertEqual(renewals, 1)
        }
    }

    func testUsageNeverRenewsForPermissionRateLimitNetworkOrServerErrors() async throws {
        let previous = try Credentials.parse(credentialData())
        for expected in [MonitorError.permissionDenied, .rateLimited(Self.instant), .network, .server(500), .server(503), .invalidResponse, .keychainLocked] {
            var renewals = 0, requests = 0
            await assertAsyncError(expected) {
                _ = try await UsageClient.fetchRenewing(credentials: previous, request: { _ in
                    requests += 1; throw expected
                }, renew: { _ in
                    renewals += 1; return previous
                })
            }
            XCTAssertEqual(requests, 1)
            XCTAssertEqual(renewals, 0)
        }
    }

    func testUsageDoesNotLoopWhenRenewedTokenIsRejected() async throws {
        let previous = try Credentials.parse(credentialData())
        var renewals = 0, requests = 0
        await assertAsyncError(.unauthorized) {
            _ = try await UsageClient.fetchRenewing(credentials: previous, request: { _ in
                requests += 1; throw MonitorError.unauthorized
            }, renew: { _ in renewals += 1; return previous })
        }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(renewals, 1)
    }

    func testConcurrentRenewalSharesOneExchangeAndPersistsRotation() async throws {
        try await withFixture { fixture in
            let previous = try Credentials.parse(XCTUnwrap(fixture.data))
            let renewal = try result(previous: previous)
            let refresher = CredentialRefresher(dependencies: fixture.dependency { _ in
                try await Task.sleep(nanoseconds: 50_000_000)
                return renewal
            })
            async let first = refresher.refresh(profile: fixture.profile, previous: previous)
            async let second = refresher.refresh(profile: fixture.profile, previous: previous)
            let values = try await [first, second]
            XCTAssertTrue(values.allSatisfy { $0.accessToken == "fixture-new-access" && $0.refreshToken == "fixture-new-refresh" })
            XCTAssertEqual(fixture.exchanges, 1)
            XCTAssertEqual(fixture.writes, 2)
            let persisted = try Credentials.parse(XCTUnwrap(fixture.data))
            XCTAssertTrue(persisted.hasSameTokens(as: values[0]))
        }
    }

    func testAlreadyRotatedCredentialsAreAdoptedWithoutExchangeOrWrite() async throws {
        try await withFixture { fixture in
            let previous = try Credentials.parse(XCTUnwrap(fixture.data))
            fixture.replace(try credentialData(access: "fixture-sibling-access", refresh: "fixture-sibling-refresh"))
            let refresher = CredentialRefresher(dependencies: fixture.dependency { _ in throw MonitorError.refreshFailed })
            let adopted = try await refresher.refresh(profile: fixture.profile, previous: previous)
            XCTAssertEqual(adopted.accessToken, "fixture-sibling-access")
            XCTAssertEqual(fixture.exchanges, 0)
            XCTAssertEqual(fixture.writes, 0)
        }
    }

    func testIndependentRefreshersCoordinateThroughDirectoryLocks() async throws {
        try await withFixture { fixture in
            let previous = try Credentials.parse(XCTUnwrap(fixture.data))
            let renewal = try result(previous: previous)
            let dependencies = fixture.dependency { _ in
                try await Task.sleep(nanoseconds: 100_000_000)
                return renewal
            }
            let firstRefresher = CredentialRefresher(dependencies: dependencies)
            let secondRefresher = CredentialRefresher(dependencies: dependencies)
            async let first = firstRefresher.refresh(profile: fixture.profile, previous: previous)
            async let second = secondRefresher.refresh(profile: fixture.profile, previous: previous)
            let values = try await [first, second]
            XCTAssertTrue(values.allSatisfy { $0.accessToken == "fixture-new-access" && $0.refreshToken == "fixture-new-refresh" })
            XCTAssertEqual(fixture.exchanges, 1)
            XCTAssertEqual(fixture.writes, 2)
            let base = URL(fileURLWithPath: fixture.profile.configDirectory)
            XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent(".oauth_refresh.lock").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: base.resolvingSymlinksInPath().path + ".lock"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent(".storage-write.lock").path))
        }
    }

    func testRotatedTokensAreSavedEvenWhenServerNarrowsScopes() async throws {
        try await withFixture { fixture in
            let previous = try Credentials.parse(XCTUnwrap(fixture.data))
            let renewal = try OAuthRefreshResult.parse(Data(#"{"access_token":"fixture-new-access","refresh_token":"fixture-new-refresh","expires_in":3600,"scope":"user:inference"}"#.utf8), previous: previous, now: Self.instant)
            let refresher = CredentialRefresher(dependencies: fixture.dependency { _ in renewal })
            let refreshed = try await refresher.refresh(profile: fixture.profile, previous: previous)
            XCTAssertEqual(refreshed.refreshToken, "fixture-new-refresh")
            XCTAssertEqual(refreshed.scopes, ["user:inference"])
            XCTAssertTrue(try Credentials.parse(XCTUnwrap(fixture.data)).hasSameTokens(as: refreshed))
            XCTAssertEqual(fixture.exchanges, 1)
        }
    }

    func testAccountReplacementDuringExchangeIsNeverOverwritten() async throws {
        try await withFixture { fixture in
            let previous = try Credentials.parse(XCTUnwrap(fixture.data))
            let replacement = try credentialData(access: "fixture-other-account", refresh: "fixture-other-refresh")
            let renewal = try result(previous: previous)
            let refresher = CredentialRefresher(dependencies: fixture.dependency { _ in
                fixture.replace(replacement)
                return renewal
            })
            let adopted = try await refresher.refresh(profile: fixture.profile, previous: previous)
            XCTAssertEqual(adopted.accessToken, "fixture-other-account")
            XCTAssertEqual(fixture.data, replacement)
            XCTAssertEqual(fixture.writes, 1, "Only the unchanged preflight write is permitted")
        }
    }

    func testLogoutDuringExchangeDoesNotRecreateCredentials() async throws {
        try await withFixture { fixture in
            let previous = try Credentials.parse(XCTUnwrap(fixture.data))
            let renewal = try result(previous: previous)
            let refresher = CredentialRefresher(dependencies: fixture.dependency { _ in
                fixture.replace(nil)
                return renewal
            })
            await assertAsyncError(.noCredentials) {
                _ = try await refresher.refresh(profile: fixture.profile, previous: previous)
            }
            XCTAssertNil(fixture.data)
            XCTAssertEqual(fixture.exchanges, 1)
            XCTAssertEqual(fixture.writes, 1)
        }
    }

    func testFailedSaveRetainsRotationAndRetryDoesNotReuseConsumedRefreshToken() async throws {
        try await withFixture { fixture in
            let before = try XCTUnwrap(fixture.data)
            let previous = try Credentials.parse(before)
            let renewal = try result(previous: previous)
            fixture.failWrites([2])
            let refresher = CredentialRefresher(dependencies: fixture.dependency { credentials in
                XCTAssertEqual(credentials.refreshToken, "fixture-old-refresh")
                return renewal
            })
            await assertAsyncError(.credentialWriteFailed) {
                _ = try await refresher.refresh(profile: fixture.profile, previous: previous)
            }
            XCTAssertEqual(fixture.data, before)
            XCTAssertEqual(fixture.exchanges, 1)
            await assertAsyncError(.credentialWriteFailed) {
                _ = try await refresher.refresh(profile: fixture.profile, previous: previous)
            }
            XCTAssertEqual(fixture.exchanges, 1)
            fixture.advance(61)
            let retried = try await refresher.refresh(profile: fixture.profile, previous: previous)
            XCTAssertEqual(retried.refreshToken, "fixture-new-refresh")
            XCTAssertEqual(fixture.exchanges, 1)
            XCTAssertEqual(fixture.writes, 3)
        }
    }

    func testWritePermissionFailureStopsBeforeTokenExchange() async throws {
        try await withFixture { fixture in
            let before = try XCTUnwrap(fixture.data)
            let previous = try Credentials.parse(before)
            fixture.failWrites([1])
            let refresher = CredentialRefresher(dependencies: fixture.dependency { _ in throw MonitorError.refreshFailed })
            await assertAsyncError(.credentialWriteFailed) {
                _ = try await refresher.refresh(profile: fixture.profile, previous: previous)
            }
            XCTAssertEqual(fixture.exchanges, 0)
            XCTAssertEqual(fixture.data, before)
        }
    }

    func testPendingRotationSurvivesNewFileInodeAndMergesUnrelatedMetadata() async throws {
        try await withFixture { fixture in
            let before = try XCTUnwrap(fixture.data)
            let previous = try Credentials.parse(before)
            let renewal = try result(previous: previous)
            let path = URL(fileURLWithPath: fixture.profile.configDirectory).appendingPathComponent(".credentials.json").path
            // File snapshots are synthetic here; the production persistence tests
            // cover inode checking against real files. The coordinator must reuse
            // a pending rotation across a valid fresh snapshot of the same path.
            fixture.changeSource(.file(path: path, device: 1, inode: 10))
            fixture.failWrites([2])
            let refresher = CredentialRefresher(dependencies: fixture.dependency { _ in renewal })
            await assertAsyncError(.credentialWriteFailed) {
                _ = try await refresher.refresh(profile: fixture.profile, previous: previous)
            }
            var newer = try XCTUnwrap(JSONSerialization.jsonObject(with: before) as? [String: Any])
            newer["newSiblingField"] = "preserve-after-failed-save"
            fixture.replace(try JSONSerialization.data(withJSONObject: newer))
            fixture.changeSource(.file(path: path, device: 1, inode: 11))
            fixture.advance(61)
            let saved = try await refresher.refresh(profile: fixture.profile, previous: previous)
            XCTAssertEqual(saved.refreshToken, "fixture-new-refresh")
            XCTAssertEqual(fixture.exchanges, 1)
            let merged = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(fixture.data)) as? [String: Any])
            XCTAssertEqual(merged["newSiblingField"] as? String, "preserve-after-failed-save")
        }
    }

    func testBackendChangesDuringExchangePreserveSuccessfulRotation() async throws {
        for fileFirst in [true, false] {
            try await withFixture { fixture in
                let previous = try Credentials.parse(XCTUnwrap(fixture.data))
                let renewal = try result(previous: previous)
                let path = URL(fileURLWithPath: fixture.profile.configDirectory).appendingPathComponent(".credentials.json").path
                let file = CredentialSource.file(path: path, device: 1, inode: 10)
                let keychain = CredentialSource.keychain(service: "fixture")
                fixture.changeSource(fileFirst ? file : keychain)
                let refresher = CredentialRefresher(dependencies: fixture.dependency { _ in
                    fixture.changeSource(fileFirst ? keychain : file)
                    return renewal
                })
                let refreshed = try await refresher.refresh(profile: fixture.profile, previous: previous)
                XCTAssertEqual(refreshed.accessToken, "fixture-new-access")
                XCTAssertEqual(refreshed.refreshToken, "fixture-new-refresh")
                XCTAssertTrue(try Credentials.parse(XCTUnwrap(fixture.data)).hasSameTokens(as: refreshed))
                XCTAssertEqual(fixture.exchanges, 1)
                XCTAssertEqual(fixture.writes, 2)
            }
        }
    }

    func testPendingRotationSurvivesBackendChangeAfterSaveFailure() async throws {
        for fileFirst in [true, false] {
            try await withFixture { fixture in
                let previous = try Credentials.parse(XCTUnwrap(fixture.data))
                let renewal = try result(previous: previous)
                let path = URL(fileURLWithPath: fixture.profile.configDirectory).appendingPathComponent(".credentials.json").path
                let file = CredentialSource.file(path: path, device: 1, inode: 10)
                let keychain = CredentialSource.keychain(service: "fixture")
                fixture.changeSource(fileFirst ? file : keychain)
                fixture.failWrites([2])
                let refresher = CredentialRefresher(dependencies: fixture.dependency { _ in renewal })
                await assertAsyncError(.credentialWriteFailed) {
                    _ = try await refresher.refresh(profile: fixture.profile, previous: previous)
                }
                fixture.changeSource(fileFirst ? keychain : file)
                fixture.advance(61)
                let saved = try await refresher.refresh(profile: fixture.profile, previous: previous)
                XCTAssertEqual(saved.refreshToken, "fixture-new-refresh")
                XCTAssertEqual(fixture.exchanges, 1)
                XCTAssertEqual(fixture.writes, 3)
            }
        }
    }

    func testCancellationBeforeExchangeDoesNotCacheFailure() async throws {
        try await withFixture { fixture in
            let previous = try Credentials.parse(XCTUnwrap(fixture.data))
            let renewal = try result(previous: previous)
            fixture.cancelWrites([1])
            let refresher = CredentialRefresher(dependencies: fixture.dependency { _ in renewal })
            do {
                _ = try await refresher.refresh(profile: fixture.profile, previous: previous)
                XCTFail("Expected cancellation before dispatch")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertEqual(fixture.exchanges, 0)
            // The clock does not advance: a cancelled preflight must not impose
            // a five-minute failure cooldown on this still-valid refresh token.
            let saved = try await refresher.refresh(profile: fixture.profile, previous: previous)
            XCTAssertEqual(saved.refreshToken, "fixture-new-refresh")
            XCTAssertEqual(fixture.exchanges, 1)
        }
    }

    func testInvalidGrantAdoptsSiblingRotationBeforeLatchingLoginFailure() async throws {
        try await withFixture { fixture in
            let previous = try Credentials.parse(XCTUnwrap(fixture.data))
            let replacement = try credentialData(access: "fixture-sibling-access", refresh: "fixture-sibling-refresh")
            let refresher = CredentialRefresher(dependencies: fixture.dependency { _ in
                fixture.replace(replacement)
                throw MonitorError.loginRequired
            })
            let adopted = try await refresher.refresh(profile: fixture.profile, previous: previous)
            XCTAssertEqual(adopted.accessToken, "fixture-sibling-access")
            XCTAssertEqual(fixture.data, replacement)
            XCTAssertEqual(fixture.writes, 1)
            let readAgain = try await refresher.refresh(profile: fixture.profile, previous: previous)
            XCTAssertTrue(readAgain.hasSameTokens(as: adopted))
            XCTAssertEqual(fixture.exchanges, 1)
        }
    }

    func testAmbiguousExchangeNeverRepostsSamePairAfterCooldownOrRestart() async throws {
        for outcome in ["network", "malformed-response", "cancelled-after-dispatch"] {
            try await withFixture { fixture in
                let before = try XCTUnwrap(fixture.data)
                let previous = try Credentials.parse(before)
                let dependencies = fixture.dependency { credentials in
                    switch outcome {
                    case "network": throw MonitorError.network
                    case "cancelled-after-dispatch": throw CancellationError()
                    default:
                        return try OAuthRefreshResult.parse(Data(#"{"access_token":"fixture-hidden-new-token","expires_in":"invalid"}"#.utf8), previous: credentials, now: Self.instant)
                    }
                }
                let refresher = CredentialRefresher(dependencies: dependencies)
                await assertAsyncError(.refreshUncertain) {
                    _ = try await refresher.refresh(profile: fixture.profile, previous: previous)
                }
                fixture.advance(301)
                await assertAsyncError(.refreshUncertain) {
                    _ = try await refresher.refresh(profile: fixture.profile, previous: previous)
                }
                let restarted = CredentialRefresher(dependencies: dependencies)
                await assertAsyncError(.refreshUncertain) {
                    _ = try await restarted.refresh(profile: fixture.profile, previous: previous)
                }
                XCTAssertEqual(fixture.exchanges, 1, outcome)
                XCTAssertEqual(fixture.data, before, outcome)
                // Persistent attempt evidence may contain an opaque fingerprint,
                // but it must never contain credentials or the response token.
                let root = URL(fileURLWithPath: fixture.profile.configDirectory).deletingLastPathComponent()
                let entries = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
                for case let url as URL in entries {
                    guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                    let content = String(decoding: try Data(contentsOf: url), as: UTF8.self)
                    for secret in ["fixture-old-access", "fixture-old-refresh", "fixture-hidden-new-token"] {
                        XCTAssertFalse(content.contains(secret))
                    }
                }
            }
        }
    }

    func testMissingOrExpiredRefreshCredentialNeverExchanges() async throws {
        for data in [try credentialData(refresh: nil), try credentialData(refreshExpiry: Self.instant.addingTimeInterval(-1))] {
            try await withFixture { fixture in
                fixture.replace(data)
                let previous = try Credentials.parse(data)
                let refresher = CredentialRefresher(dependencies: fixture.dependency { _ in throw MonitorError.refreshFailed })
                await assertAsyncError(.loginRequired) {
                    _ = try await refresher.refresh(profile: fixture.profile, previous: previous)
                }
                XCTAssertEqual(fixture.exchanges, 0)
                XCTAssertEqual(fixture.writes, 0)
                XCTAssertEqual(fixture.data, data)
            }
        }
    }

    func testOldTokenReadbackAfterReportedSaveRetainsPendingRotation() async throws {
        try await withFixture { fixture in
            let before = try XCTUnwrap(fixture.data)
            let previous = try Credentials.parse(before)
            let renewal = try result(previous: previous)
            fixture.ignoreWrites([2])
            let refresher = CredentialRefresher(dependencies: fixture.dependency { _ in renewal })
            await assertAsyncError(.credentialWriteFailed) {
                _ = try await refresher.refresh(profile: fixture.profile, previous: previous)
            }
            XCTAssertEqual(fixture.data, before)
            XCTAssertEqual(fixture.exchanges, 1)
            fixture.advance(61)
            let saved = try await refresher.refresh(profile: fixture.profile, previous: previous)
            XCTAssertEqual(saved.accessToken, "fixture-new-access")
            XCTAssertEqual(saved.refreshToken, "fixture-new-refresh")
            XCTAssertEqual(fixture.exchanges, 1)
            XCTAssertEqual(fixture.writes, 3)
        }
    }

    func testUnexpectedExchangeErrorIsSanitizedAndLeavesCredentialsIntact() async throws {
        try await withFixture { fixture in
            let before = try XCTUnwrap(fixture.data)
            let previous = try Credentials.parse(before)
            let refresher = CredentialRefresher(dependencies: fixture.dependency { _ in
                throw NSError(domain: "fixture-private-server", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture-secret-should-never-appear"])
            })
            await assertAsyncError(.refreshUncertain) {
                _ = try await refresher.refresh(profile: fixture.profile, previous: previous)
            }
            XCTAssertEqual(fixture.data, before)
            XCTAssertEqual(fixture.writes, 1)
            XCTAssertEqual(fixture.exchanges, 1)
        }
    }
}
