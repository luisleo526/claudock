import Foundation
import XCTest
@testable import UsageCore

final class MintTokenTests: XCTestCase {
    private let profile = Profile(command: "claude-fixture", configDirectory: "/synthetic/claudock-profile")
    private let instant = Date(timeIntervalSince1970: 1_790_000_000)
    private var identity: MintAccountIdentity {
        try! MintAccountIdentity(accountUUID: "11111111-1111-4111-8111-111111111111", organizationUUID: "22222222-2222-4222-8222-222222222222")
    }
    private var otherIdentity: MintAccountIdentity {
        try! MintAccountIdentity(accountUUID: "33333333-3333-4333-8333-333333333333", organizationUUID: "22222222-2222-4222-8222-222222222222")
    }
    private var flow: MintTokenFlow {
        MintTokenFlow(profile: profile, expectedIdentity: identity,
                      verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "fixture-state")
    }
    private var token: MintToken {
        MintToken(accessToken: "fixture-inference-token", expiresAt: instant.addingTimeInterval(3600), identity: identity)
    }
    private var pastedValue: String { "sk-ant-oat01-" + "fixture_imported_token_0123456789" }

    private func response(overrides: [String: Any] = [:], omitting: [String] = []) throws -> Data {
        var body: [String: Any] = ["access_token": "fixture-inference-token", "expires_in": 3600,
            "token_type": "bearer", "scope": "user:inference", "account": ["uuid": identity.accountUUID],
            "organization": ["uuid": identity.organizationUUID]]
        body.merge(overrides) { _, replacement in replacement }
        omitting.forEach { body.removeValue(forKey: $0) }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func http(_ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://platform.claude.com/v1/oauth/token")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func testAuthorizationURLUsesOfficialPKCEAndInferenceOnlyScope() throws {
        let url = flow.authorizationURL
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "claude.com")
        XCTAssertEqual(url.path, "/cai/oauth/authorize")
        let query = Dictionary(uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["scope"], "user:inference")
        XCTAssertEqual(query["code"], "true")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["client_id"], "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        // RFC 7636's published verifier/challenge test vector.
        XCTAssertEqual(query["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(query["redirect_uri"], "https://platform.claude.com/oauth/code/callback")
        XCTAssertEqual(query["state"], "fixture-state")
        XCTAssertNil(query["code_verifier"])
    }

    func testExchangeBodyIncludesServerBoundStateAndRequestedDuration() throws {
        let request = try flow.request(pastedCode: " fixture-code#fixture-state\n")
        XCTAssertEqual(request.url?.absoluteString, "https://platform.claude.com/v1/oauth/token")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["grant_type"] as? String, "authorization_code")
        XCTAssertEqual(body["code"] as? String, "fixture-code")
        XCTAssertEqual(body["state"] as? String, "fixture-state")
        XCTAssertEqual(body["code_verifier"] as? String, flow.verifier)
        XCTAssertEqual(body["expires_in"] as? Int, 31_536_000)
        XCTAssertNil(body["refresh_token"])
    }

    func testIncompleteOrMismatchedCodeIsRejectedBeforeExchange() async throws {
        for code in ["", "code-only", "#fixture-state", "code#wrong-state", "code#fixture-state#extra", "code with spaces#fixture-state"] {
            var requests = 0, saves = 0
            do {
                _ = try await flow.finish(pastedCode: code, currentIdentity: { _ in self.identity },
                    transport: { _ in requests += 1; return (try self.response(), self.http()) },
                    save: { _, _ in saves += 1 }, now: instant)
                XCTFail("Invalid code was accepted")
            } catch { XCTAssertTrue(error is MintTokenError) }
            XCTAssertEqual(requests, 0)
            XCTAssertEqual(saves, 0)
        }
    }

    func testReturnedExpirationControlsStoredExpiry() throws {
        let token = try MintToken.parseResponse(response(), now: instant, expected: identity)
        XCTAssertEqual(token.expiresAt, instant.addingTimeInterval(3600))
        XCTAssertNotEqual(token.expiresAt, instant.addingTimeInterval(31_536_000))
    }

    func testMalformedExpiryOrScopeIsNeverInvented() throws {
        for value: Any in [NSNull(), true, 0, -1, "3600", 315_360_001] {
            XCTAssertThrowsError(try MintToken.parseResponse(response(overrides: ["expires_in": value]), now: instant, expected: identity))
        }
        for key in ["expires_in", "access_token", "scope"] {
            XCTAssertThrowsError(try MintToken.parseResponse(response(omitting: [key]), now: instant, expected: identity))
        }
        XCTAssertThrowsError(try MintToken.parseResponse(response(overrides: ["scope": "user:inference user:profile"]), now: instant, expected: identity))
    }

    func testAccountAndOrganizationMustBothBePresentAndMatch() throws {
        for key in ["account", "organization"] {
            XCTAssertThrowsError(try MintToken.parseResponse(response(omitting: [key]), now: instant, expected: identity)) {
                XCTAssertEqual($0 as? MintTokenError, .identityUnavailable)
            }
            XCTAssertThrowsError(try MintToken.parseResponse(response(overrides: [key: ["uuid": "44444444-4444-4444-8444-444444444444"]]), now: instant, expected: identity)) {
                XCTAssertEqual($0 as? MintTokenError, .accountMismatch)
            }
        }
    }

    func testProfileIdentityChangeStopsExchangeOrSave() async throws {
        for changeBeforeRequest in [true, false] {
            var reads = 0, requests = 0, saves = 0
            do {
                _ = try await flow.finish(pastedCode: "fixture-code#fixture-state", currentIdentity: { _ in
                    reads += 1
                    return changeBeforeRequest || reads > 1 ? self.otherIdentity : self.identity
                }, transport: { _ in requests += 1; return (try self.response(), self.http()) },
                   save: { _, _ in saves += 1 }, now: instant)
                XCTFail("Changed account was accepted")
            } catch { XCTAssertEqual(error as? MintTokenError, .accountChanged) }
            XCTAssertEqual(requests, changeBeforeRequest ? 0 : 1)
            XCTAssertEqual(saves, 0)
        }
    }

    func testSuccessfulFlowSavesOneIndependentToken() async throws {
        var saves = 0
        let result = try await flow.finish(pastedCode: "fixture-code#fixture-state", currentIdentity: { _ in self.identity },
            transport: { _ in (try self.response(), self.http()) }, save: { token, profile in
                saves += 1
                XCTAssertEqual(profile, self.profile)
                XCTAssertEqual(token.identity, self.identity)
                XCTAssertEqual(token.expiresAt, self.instant.addingTimeInterval(3600))
            }, now: instant)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(result.expiresAt, instant.addingTimeInterval(3600))
    }

    func testHTTPFailureNeverSavesOrExposesResponseBody() async throws {
        for status in [302, 400, 401, 403, 429, 500] {
            var saves = 0
            do {
                _ = try await flow.finish(pastedCode: "fixture-code#fixture-state", currentIdentity: { _ in self.identity },
                    transport: { _ in (Data("fixture-sensitive-server-text".utf8), self.http(status)) },
                    save: { _, _ in saves += 1 }, now: instant)
                XCTFail("HTTP failure succeeded")
            } catch {
                XCTAssertEqual(error as? MintTokenError, .exchangeFailed)
                XCTAssertFalse(error.localizedDescription.contains("fixture-sensitive"))
            }
            XCTAssertEqual(saves, 0)
        }
    }

    func testKeychainServiceIsDistinctAndStableAcrossProfileRename() {
        let renamed = Profile(command: "claude-renamed", configDirectory: profile.configDirectory)
        let service = MintTokenStore.serviceName(for: profile)
        XCTAssertEqual(service, MintTokenStore.serviceName(for: renamed))
        XCTAssertNotEqual(service, CredentialStore.serviceName(for: profile))
        XCTAssertNotNil(service.range(of: #"\AClaudock-inference-[a-f0-9]{64}\z"#, options: .regularExpression))
    }

    func testKeychainPayloadRoundTripsWithoutUsageRefreshMetadata() throws {
        let data = try MintTokenStore.encode(token)
        let decoded = try MintTokenStore.decode(data)
        XCTAssertEqual(decoded.expiresAt, token.expiresAt)
        XCTAssertEqual(decoded.identity, identity)
        let hex = Data((data.map { String(format: "%02x", $0) }.joined() + "\n").utf8)
        XCTAssertEqual(try MintTokenStore.decode(hex).accessToken, token.accessToken)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(root["refreshToken"])
        XCTAssertNil(root["claudeAiOauth"])
    }

    func testSecureStdinCommandIsHexEncodedAndBounded() throws {
        let data = try MintTokenStore.encode(token)
        let service = MintTokenStore.serviceName(for: profile)
        let command = try MintTokenStore.securityWriteCommand(data, account: "fixture-user", service: service)
        XCTAssertLessThanOrEqual(command.count, 4032)
        let text = String(decoding: command, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("add-generic-password -U "))
        XCTAssertFalse(text.contains(token.accessToken))
        XCTAssertTrue(text.hasSuffix("\"\n"))
        XCTAssertThrowsError(try MintTokenStore.securityWriteCommand(Data(repeating: 1, count: 2016), account: "fixture-user", service: service))
        XCTAssertThrowsError(try MintTokenStore.securityWriteCommand(data, account: "bad\naccount", service: service))
        XCTAssertThrowsError(try MintTokenStore.securityWriteCommand(data, account: "fixture-user", service: CredentialStore.serviceName(for: profile)))
    }

    func testMissingMintIsOptionalButReadErrorsNeverFallBack() throws {
        XCTAssertNil(try MintTokenStore.read(profile: profile, securityRead: { _ in (Data(), 44) }, identity: { _ in
            XCTFail("Missing item should not read account metadata")
            return self.identity
        }))
        XCTAssertThrowsError(try MintTokenStore.read(profile: profile, securityRead: { _ in (Data(), 36) }, identity: { _ in self.identity })) {
            XCTAssertEqual($0 as? MintTokenError, .keychainUnavailable)
        }
        let data = try MintTokenStore.encode(token)
        XCTAssertThrowsError(try MintTokenStore.read(profile: profile, securityRead: { _ in (data, 0) }, identity: { _ in self.otherIdentity })) {
            XCTAssertEqual($0 as? MintTokenError, .accountMismatch)
        }
    }

    func testActiveMintIsPreferredWithoutReadingOrRefreshingUsageOAuth() async throws {
        let credentials = try await InferenceCredential.read(profile: profile, mint: { _ in self.token }, oauth: { _ in
            XCTFail("Active mint must not read usage OAuth")
            throw MintTokenError.exchangeFailed
        }, now: instant)
        XCTAssertEqual(credentials.accessToken, token.accessToken)
        XCTAssertEqual(credentials.expiresAt, token.expiresAt)
        XCTAssertEqual(credentials.scopes, ["user:inference"])
        XCTAssertNil(credentials.refreshToken)
        XCTAssertEqual(try InferenceCredential.environmentToken(profile: profile, mint: { _ in self.token }, now: instant), token.accessToken)
    }

    func testExpiredMintAndOAuthRequireResidentAppRenewalWithoutRotation() async throws {
        let expired = MintToken(accessToken: "fixture-old-mint", expiresAt: instant, identity: identity)
        let oauth = Credentials(accessToken: "fixture-old-oauth", expiresAt: instant, plan: "max", refreshToken: "fixture-refresh")
        var reads = 0
        do {
            _ = try await InferenceCredential.read(profile: profile, mint: { _ in expired }, oauth: { _ in reads += 1; return oauth }, now: instant)
            XCTFail("Expired OAuth should be handed back to the resident app")
        } catch { XCTAssertEqual(error as? MonitorError, .expired) }
        XCTAssertEqual(reads, 1)
        XCTAssertNil(try InferenceCredential.environmentToken(profile: profile, mint: { _ in expired }, now: instant))
    }

    func testAbsentMintCanUseUnexpiredExistingOAuthWithoutChangingTokens() async throws {
        let oauth = Credentials(accessToken: "fixture-existing-oauth", expiresAt: instant.addingTimeInterval(120), plan: "max", refreshToken: "fixture-existing-refresh")
        let result = try await InferenceCredential.read(profile: profile, mint: { _ in nil }, oauth: { _ in oauth }, now: instant)
        XCTAssertEqual(result.accessToken, oauth.accessToken)
        XCTAssertEqual(result.refreshToken, oauth.refreshToken)
        XCTAssertEqual(result.expiresAt, oauth.expiresAt)
    }

    func testRejectedMintReadNeverSilentlySelectsUsageOAuth() async throws {
        do {
            _ = try await InferenceCredential.read(profile: profile, mint: { _ in throw MintTokenError.accountMismatch }, oauth: { _ in
                XCTFail("Mint error must not select another credential")
                throw MintTokenError.exchangeFailed
            }, now: instant)
            XCTFail("Mint error was ignored")
        } catch { XCTAssertEqual(error as? MintTokenError, .accountMismatch) }
        let unsupported = Profile(command: "claude-vertex", configDirectory: "/synthetic/vertex", isVertex: true)
        XCTAssertThrowsError(try InferenceCredential.environmentToken(profile: unsupported, mint: { _ in
            XCTFail("Unsupported profile reached mint storage")
            return nil
        }))
    }

    func testRawAndExactExportImportsNeedNoExistingLoginAndNeverInventExpiry() throws {
        for raw in [pastedValue, " \n" + pastedValue + "\r\n",
                    "export CLAUDE_CODE_OAUTH_TOKEN=" + pastedValue,
                    "export  \tCLAUDE_CODE_OAUTH_TOKEN='" + pastedValue + "'",
                    "export CLAUDE_CODE_OAUTH_TOKEN=\"" + pastedValue + "\"\n"] {
            var saves = 0
            let imported = try MintTokenStore.importToken(raw: raw, profile: profile,
                identity: { _ in throw MintTokenError.loginRequired }, save: { token, selected in
                    saves += 1
                    XCTAssertEqual(selected, self.profile)
                    XCTAssertEqual(token.accessToken, self.pastedValue)
                    XCTAssertNil(token.identity)
                })
            XCTAssertEqual(saves, 1)
            XCTAssertNil(imported.expiresAt)
            XCTAssertEqual(imported.provenance, .pasted)
            XCTAssertFalse(imported.identityVerified)
            XCTAssertEqual(MintTokenStore.status(imported, now: instant), .imported(expiresAt: nil))
        }
    }

    func testUnsafeOrMalformedClipboardInputFailsBeforeMetadataOrSave() throws {
        let invalid = ["", "not-a-token", "sk-ant-oat01-", "sk-ant-api03-" + "fixture_wrong_kind",
                       "CLAUDE_CODE_OAUTH_TOKEN=" + pastedValue,
                       "export OTHER_TOKEN=" + pastedValue,
                       "export CLAUDE_CODE_OAUTH_TOKEN =" + pastedValue,
                       "export CLAUDE_CODE_OAUTH_TOKEN= '" + pastedValue + "'",
                       "export CLAUDE_CODE_OAUTH_TOKEN='" + pastedValue,
                       "export CLAUDE_CODE_OAUTH_TOKEN='" + pastedValue + "\"",
                       "export CLAUDE_CODE_OAUTH_TOKEN='" + pastedValue + "'; touch never-run",
                       "export CLAUDE_CODE_OAUTH_TOKEN=\"$(touch never-run)\"",
                       pastedValue + "\ncommand second-line", pastedValue + "`whoami`", pastedValue + "$USER",
                       pastedValue + "\0", pastedValue + "漢字"]
        for raw in invalid {
            XCTAssertThrowsError(try MintTokenStore.importToken(raw: raw, profile: profile, identity: { _ in
                XCTFail("Malformed clipboard data must not read profile metadata")
                return self.identity
            }, save: { _, _ in XCTFail("Malformed clipboard data must not write Keychain") })) { error in
                XCTAssertEqual(error as? MintTokenError, .invalidToken)
                XCTAssertFalse(error.localizedDescription.contains(self.pastedValue))
                XCTAssertFalse(error.localizedDescription.contains("never-run"))
            }
        }
        XCTAssertThrowsError(try MintTokenStore.importToken(raw: String(repeating: "a", count: 32_769), profile: profile,
            identity: { _ in XCTFail(); return self.identity }, save: { _, _ in XCTFail() })) {
            XCTAssertEqual($0 as? MintTokenError, .tokenTooLarge)
        }
    }

    func testImportedExpiryAndCachedIdentityAreOnlyUserLocalMetadata() throws {
        let expiry = instant.addingTimeInterval(1800)
        let imported = try MintTokenStore.importToken(raw: pastedValue, profile: profile, expiresAt: expiry,
            identity: { _ in self.identity }, save: { _, _ in })
        XCTAssertEqual(imported.expiresAt, expiry)
        XCTAssertEqual(imported.identity, identity)
        XCTAssertFalse(imported.identityVerified)
        XCTAssertEqual(MintTokenStore.status(imported, now: instant), .imported(expiresAt: expiry))
        XCTAssertEqual(MintTokenStore.status(imported, now: expiry), .expired(expiresAt: expiry))
        for invalid in [Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: -.infinity), Date(timeIntervalSince1970: 0)] {
            XCTAssertThrowsError(try MintToken.imported(raw: pastedValue, expiresAt: invalid, identity: nil)) {
                XCTAssertEqual($0 as? MintTokenError, .invalidExpiry)
            }
        }
    }

    func testImportedStorageHasExplicitProvenanceAndOptionalExpiryAndIdentity() throws {
        let imported = try MintToken.imported(raw: pastedValue, expiresAt: nil, identity: nil)
        let data = try MintTokenStore.encode(imported)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 2)
        XCTAssertEqual(object["provenance"] as? String, "pasted")
        XCTAssertNil(object["expiresAt"])
        XCTAssertNil(object["identity"])
        XCTAssertNil(object["refreshToken"])
        XCTAssertNil(object["claudeAiOauth"])
        let restored = try MintTokenStore.decode(data)
        XCTAssertEqual(restored.accessToken, pastedValue)
        XCTAssertEqual(restored.provenance, .pasted)
        XCTAssertNil(restored.expiresAt)
        XCTAssertFalse(restored.identityVerified)
        let hex = Data(data.map { String(format: "%02x", $0) }.joined().utf8)
        XCTAssertEqual(try MintTokenStore.decode(hex).provenance, .pasted)
    }

    func testLegacyVersionOneBrowserItemKeepsStrictIdentityAndExpiration() throws {
        let legacy = try JSONSerialization.data(withJSONObject: [
            "version": 1, "accessToken": "fixture-browser-legacy", "expiresAt": instant.addingTimeInterval(3600).timeIntervalSince1970,
            "identity": ["accountUUID": identity.accountUUID, "organizationUUID": identity.organizationUUID]
        ])
        let restored = try MintTokenStore.decode(legacy)
        XCTAssertEqual(restored.provenance, .browser)
        XCTAssertTrue(restored.identityVerified)
        XCTAssertEqual(restored.expiresAt, instant.addingTimeInterval(3600))
        XCTAssertThrowsError(try MintTokenStore.read(profile: profile, securityRead: { _ in (legacy, 0) }, identity: { _ in self.otherIdentity })) {
            XCTAssertEqual($0 as? MintTokenError, .accountMismatch)
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        object["provenance"] = "pasted"
        XCTAssertThrowsError(try MintTokenStore.decode(JSONSerialization.data(withJSONObject: object)))
        object.removeValue(forKey: "provenance")
        object.removeValue(forKey: "identity")
        XCTAssertThrowsError(try MintTokenStore.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try MintTokenStore.encode(MintToken(accessToken: "fixture-browser", expiresAt: nil, identity: identity)))
    }

    func testUnboundImportedReadDoesNotRequireOrPretendToVerifyAnAccount() throws {
        let imported = try MintToken.imported(raw: pastedValue, expiresAt: nil, identity: nil)
        let data = try MintTokenStore.encode(imported)
        let restored = try XCTUnwrap(MintTokenStore.read(profile: profile, securityRead: { service in
            XCTAssertEqual(service, MintTokenStore.serviceName(for: self.profile))
            return (data, 0)
        }, identity: { _ in XCTFail("An unbound pasted token needs no existing OAuth metadata"); throw MintTokenError.loginRequired }))
        XCTAssertEqual(restored.accessToken, pastedValue)
        XCTAssertFalse(restored.identityVerified)
    }

    func testCachedBindingCannotSilentlyRetargetImportedTokenToChangedLocalAccount() throws {
        let imported = try MintToken.imported(raw: pastedValue, expiresAt: nil, identity: identity)
        let data = try MintTokenStore.encode(imported)
        XCTAssertThrowsError(try MintTokenStore.read(profile: profile, securityRead: { _ in (data, 0) }, identity: { _ in self.otherIdentity })) {
            XCTAssertEqual($0 as? MintTokenError, .accountMismatch)
        }
        let noLogin = try XCTUnwrap(MintTokenStore.read(profile: profile, securityRead: { _ in (data, 0) }, identity: { _ in throw MintTokenError.loginRequired }))
        XCTAssertFalse(noLogin.identityVerified)
        XCTAssertEqual(noLogin.accessToken, pastedValue)
    }

    func testImportedSaveUsesBoundedSeparateKeychainStdinAndVerifiesReadback() throws {
        let imported = try MintToken.imported(raw: pastedValue, expiresAt: nil, identity: nil)
        let encoded = try MintTokenStore.encode(imported)
        var writes = 0, reads = 0
        try MintTokenStore.save(imported, profile: profile, identity: { _ in
            XCTFail("No preexisting browser login is required")
            throw MintTokenError.loginRequired
        }, securityWrite: { command in
            writes += 1
            XCTAssertLessThanOrEqual(command.count, 4032)
            let text = String(decoding: command, as: UTF8.self)
            XCTAssertFalse(text.contains(self.pastedValue))
            XCTAssertTrue(text.contains(MintTokenStore.serviceName(for: self.profile)))
            XCTAssertFalse(text.contains("Claude Code-credentials"))
        }, securityRead: { service in
            reads += 1
            XCTAssertEqual(service, MintTokenStore.serviceName(for: self.profile))
            return (encoded, 0)
        })
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(reads, 1)
    }

    func testSaveRefusesChangedIdentityBeforeWritingAndMismatchedReadback() throws {
        let imported = try MintToken.imported(raw: pastedValue, expiresAt: nil, identity: identity)
        var reads = 0, writes = 0
        XCTAssertThrowsError(try MintTokenStore.save(imported, profile: profile, identity: { _ in
            reads += 1; return reads == 1 ? self.identity : self.otherIdentity
        }, securityWrite: { _ in writes += 1 }, securityRead: { _ in (try MintTokenStore.encode(imported), 0) })) {
            XCTAssertEqual($0 as? MintTokenError, .accountChanged)
        }
        XCTAssertEqual(writes, 0)
        let unbound = try MintToken.imported(raw: pastedValue, expiresAt: nil, identity: nil)
        XCTAssertThrowsError(try MintTokenStore.save(unbound, profile: profile, identity: { _ in self.identity },
            securityWrite: { _ in }, securityRead: { _ in (try MintTokenStore.encode(self.token), 0) })) {
            XCTAssertEqual($0 as? MintTokenError, .keychainWriteFailed)
        }
    }

    func testOversizedImportedSaveFailsBeforeKeychainWrite() throws {
        let imported = try MintToken.imported(raw: "sk-ant-oat01-" + String(repeating: "a", count: 3000), expiresAt: nil, identity: nil)
        XCTAssertThrowsError(try MintTokenStore.save(imported, profile: profile, identity: { _ in throw MintTokenError.loginRequired },
            securityWrite: { _ in XCTFail("Oversized token must not reach security stdin") },
            securityRead: { _ in XCTFail("Oversized token must not read Keychain"); return (Data(), 44) })) {
            XCTAssertEqual($0 as? MintTokenError, .tokenTooLarge)
        }
    }

    func testUnknownExpiryImportedTokenIsPreferredWithoutOAuthReadOrRenewal() async throws {
        let imported = try MintToken.imported(raw: pastedValue, expiresAt: nil, identity: nil)
        let credential = try await InferenceCredential.read(profile: profile, mint: { _ in imported }, oauth: { _ in
            XCTFail("Pasted token requires no existing OAuth login")
            throw MintTokenError.loginRequired
        }, now: instant)
        XCTAssertEqual(credential.accessToken, pastedValue)
        XCTAssertNil(credential.expiresAt)
        XCTAssertNil(credential.refreshToken)
        XCTAssertEqual(credential.scopes, ["user:inference"])
        XCTAssertEqual(try InferenceCredential.environmentToken(profile: profile, mint: { _ in imported }, now: instant), pastedValue)
    }

    func testKnownExpiredImportedTokenDoesNotSelectAnotherOAuthIdentity() async throws {
        let imported = try MintToken.imported(raw: pastedValue, expiresAt: instant, identity: nil)
        do {
            _ = try await InferenceCredential.read(profile: profile, mint: { _ in imported }, oauth: { _ in
                XCTFail("An expired unverified token must not silently change provider accounts")
                throw MintTokenError.exchangeFailed
            }, now: instant)
            XCTFail("Expired imported token was accepted")
        } catch { XCTAssertEqual(error as? MintTokenError, .tokenExpired) }
        XCTAssertThrowsError(try InferenceCredential.environmentToken(profile: profile, mint: { _ in imported }, now: instant)) {
            XCTAssertEqual($0 as? MintTokenError, .tokenExpired)
        }
    }
}
