import Foundation
import CryptoKit
import XCTest
@testable import UsageCore

final class EndpointTests: XCTestCase {
    private let deepseek = "https://api.deepseek.com/anthropic"
    private var configuration: EndpointConfiguration { try! EndpointConfiguration(baseURL: deepseek, model: "deepseek-flash") }
    private var profile: Profile {
        Profile(command: "claude-deepseek", configDirectory: "/synthetic/claudock-endpoint", registryID: "11111111-2222-4333-8444-555555555555",
                managed: true, authKind: .endpoint, endpoint: configuration)
    }
    private let key = "sk-" + "fixture0123456789abcdef0123456789"
    private let otherKey = "sk-" + "fixtureOTHER9876543210fedcba98765"

    // MARK: Base URL and model

    func testBaseURLMustBeHTTPSWithAHostAndLosesItsTrailingSlash() throws {
        let accepted: [(String, String)] = [
            (deepseek, deepseek), (deepseek + "/", deepseek), (deepseek + "//", deepseek),
            ("HTTPS://API.DeepSeek.com/anthropic", deepseek), ("https://api.deepseek.com", "https://api.deepseek.com"),
            ("https://api.deepseek.com/", "https://api.deepseek.com"),
            ("https://gateway.example.test:8443/v1/anthropic", "https://gateway.example.test:8443/v1/anthropic"),
            ("https://gateway.example.test/a%20b", "https://gateway.example.test/a%20b")]
        for (raw, normalised) in accepted {
            XCTAssertEqual(try EndpointConfiguration(baseURL: raw, model: "deepseek-flash").baseURL, normalised, raw)
        }
        let refused = ["http://api.deepseek.com/anthropic", "HTTP://api.deepseek.com", "ftp://api.deepseek.com", "api.deepseek.com/anthropic",
                       "//api.deepseek.com", "https://", "https:///anthropic", "https://user@api.deepseek.com", "https://user:secret@api.deepseek.com",
                       "https://api.deepseek.com/anthropic?key=x", "https://api.deepseek.com/anthropic?", "https://api.deepseek.com/#part",
                       "https://api.deepseek.com/anthropic#", "https://api deepseek.com", "https://api.deepseek.com/ anthropic",
                       " https://api.deepseek.com", "https://api.deepseek.com\n", "https://api.deepseek.com/\u{7}", "https://api.déepseek.com",
                       "https://api.deepseek.com:0", "https://api.deepseek.com:99999", "", "https://" + String(repeating: "a", count: 2050) + ".test"]
        for raw in refused {
            XCTAssertThrowsError(try EndpointConfiguration(baseURL: raw, model: "deepseek-flash"), raw.debugDescription) { error in
                XCTAssertEqual(error as? EndpointError, .invalidBaseURL, raw.debugDescription)
                XCTAssertFalse(error.localizedDescription.contains("secret"))
            }
        }
    }

    func testTheShownHostLeavesOutThePathAndKeepsAPort() throws {
        XCTAssertEqual(configuration.host, "api.deepseek.com")
        XCTAssertEqual(try EndpointConfiguration(baseURL: "https://gateway.example.test:8443/v1", model: "m").host, "gateway.example.test:8443")
    }

    func testModelIsOneIDWithAnOptionalOneMillionTokenSuffix() throws {
        let accepted = ["deepseek-flash", "deepseek-flash[1m]", "org/model:v1.2", "a", "A_b.c-d:e/f",
                        String(repeating: "m", count: 128), String(repeating: "m", count: 124) + "[1m]"]
        for model in accepted {
            XCTAssertEqual(try EndpointConfiguration(baseURL: deepseek, model: model).model, model)
        }
        let refused = ["", "deepseek flash", "deepseek-flash[2m]", "[1m]", "deepseek-flash[1M]", "deepseek-flash[1m][1m]", "deepseek-flash\n",
                       "modèle", String(repeating: "m", count: 129), String(repeating: "m", count: 125) + "[1m]", "model;touch-x", "$(model)",
                       "deepseek-flash,deepseek-v4-pro", "deepseek-flash[1m]x"]
        for model in refused {
            XCTAssertThrowsError(try EndpointConfiguration(baseURL: deepseek, model: model), model.debugDescription) {
                XCTAssertEqual($0 as? EndpointError, .invalidModel, model.debugDescription)
            }
        }
    }

    func testBehavesAsIsAnOptionalFullCatalogID() throws {
        XCTAssertNil(configuration.behavesAs)
        for target in ["claude-sonnet-4-6", "claude-opus-4-8", "claude-3-5-haiku", "claude-fable-5-1"] {
            XCTAssertEqual(try EndpointConfiguration(baseURL: deepseek, model: "deepseek-flash", behavesAs: target).behavesAs, target)
        }
        // Claude Code 2.1.296 maps only a full catalog id; an alias such as "sonnet" is ignored, so it is refused here.
        for target in ["sonnet", "opus", "Claude-Sonnet-4-6", "claude sonnet", "claude-", "gpt-5", "claude-sonnet-4-6[1m]",
                       "claude-" + String(repeating: "a", count: 122), ""] {
            XCTAssertThrowsError(try EndpointConfiguration(baseURL: deepseek, model: "deepseek-flash", behavesAs: target), target) {
                XCTAssertEqual($0 as? EndpointError, .invalidBehavesAs, target)
            }
        }
        let mapped = try EndpointConfiguration(baseURL: deepseek, model: "deepseek-flash", behavesAs: "claude-sonnet-4-6")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(mapped)) as? [String: Any])
        XCTAssertEqual(object as NSDictionary, ["baseURL": deepseek, "model": "deepseek-flash", "behavesAs": "claude-sonnet-4-6"] as NSDictionary)
        XCTAssertEqual(try JSONDecoder().decode(EndpointConfiguration.self, from: JSONEncoder().encode(mapped)), mapped)
        XCTAssertThrowsError(try JSONDecoder().decode(EndpointConfiguration.self, from: Data(
            #"{"baseURL":"https://api.deepseek.com/anthropic","model":"deepseek-flash","behavesAs":"sonnet"}"#.utf8)))
    }

    func testStoredConfigurationsDecodeOnlyWhenValidAndNormalised() throws {
        let decoded = try JSONDecoder().decode(EndpointConfiguration.self, from: Data(#"{"baseURL":"https://api.deepseek.com/anthropic","model":"deepseek-flash"}"#.utf8))
        XCTAssertEqual(decoded, configuration)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        XCTAssertEqual(object as NSDictionary, ["baseURL": deepseek, "model": "deepseek-flash"] as NSDictionary)
        for stored in [#"{"baseURL":"http://api.deepseek.com/anthropic","model":"deepseek-flash"}"#,
                       #"{"baseURL":"https://api.deepseek.com/anthropic/","model":"deepseek-flash"}"#,
                       #"{"baseURL":"https://api.deepseek.com/anthropic","model":"deepseek flash"}"#,
                       #"{"baseURL":"https://api.deepseek.com/anthropic"}"#, #"{"model":"deepseek-flash"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(EndpointConfiguration.self, from: Data(stored.utf8)), stored)
        }
    }

    // MARK: Key input

    func testRawKeysAndOneAssignmentLineAreAccepted() throws {
        for raw in [key, key + "\n", " \n" + key + "\r\n", "export DEEPSEEK_API_KEY=" + key, "export DEEPSEEK_API_KEY=" + key + "\n",
                    "export \tDEEPSEEK_API_KEY=\"" + key + "\"", "DEEPSEEK_API_KEY='" + key + "'", "deepseek_key=" + key, "_K1=" + key] {
            XCTAssertEqual(try EndpointAPIKey(parsing: raw).value, key, raw.debugDescription)
        }
        // Anything printable without white space is a key; text after the first "=" of an assignment is its value.
        for value in ["abc=def==", "x", "!#$%&()*+,-./:;<=>?@[]^_`{|}~", String(repeating: "k", count: 512)] {
            XCTAssertEqual(try EndpointAPIKey(parsing: "export PROVIDER_KEY='" + value + "'").value, value)
        }
        XCTAssertEqual(try EndpointAPIKey(parsing: "TOKEN=abc=def").value, "abc=def")
        // A raw key with base64 padding is not an assignment of "=".
        XCTAssertEqual(try EndpointAPIKey(parsing: "AbC123xyz==").value, "AbC123xyz==")
        XCTAssertEqual(try EndpointAPIKey(parsing: "exportAbC123==").value, "exportAbC123==")
        XCTAssertEqual(try EndpointAPIKey(parsing: "export PROVIDER_KEY==abc").value, "=abc")
    }

    func testMalformedKeysAreRefusedWithoutEchoingThem() {
        let invalid = ["", " \n ", "fixture key", "fixture\tkey", "fixture-one\nfixture-two", "export A=fixture-one\nexport B=fixture-two",
                       "NAME=", "export NAME=", "NAME=\"fixture-unbalanced", "NAME='fixture-mixed\"", "NAME=\"\"", "NAME='fixture with space'",
                       "export =fixture", "fixtureé", "fixture\u{7f}", "fixture\0", "fixture\u{1b}[31m", String(repeating: "k", count: 513),
                       "export NAME=" + String(repeating: "k", count: 513), String(repeating: " ", count: 4090) + "fixture-long",
                       "\"fixture-quoted\"", "'fixture-quoted'", "NAME=\"'fixture-quoted'\""]
        for raw in invalid {
            XCTAssertThrowsError(try EndpointAPIKey(parsing: raw), String(raw.prefix(40)).debugDescription) { error in
                XCTAssertEqual(error as? EndpointKeyError, .invalidKey, String(raw.prefix(40)).debugDescription)
                XCTAssertFalse(error.localizedDescription.contains("fixture"))
            }
        }
    }

    func testAnthropicKeysAreRefusedBecauseTheyWouldReachAThirdParty() {
        for raw in ["sk-ant-api03-fixture_anthropic", "export DEEPSEEK_API_KEY=sk-ant-api03-fixture_anthropic",
                    "ANTHROPIC_API_KEY='sk-ant-oat01-fixture_token'", "SK-ANT-api03-fixture_upper", "sk-ant-"] {
            XCTAssertThrowsError(try EndpointAPIKey(parsing: raw), raw) { error in
                XCTAssertEqual(error as? EndpointKeyError, .anthropicKey, raw)
                XCTAssertTrue(error.localizedDescription.contains("third-party endpoint"))
                XCTAssertFalse(error.localizedDescription.contains("fixture"))
            }
        }
    }

    func testDescriptionNeverRevealsTheKey() throws {
        let parsed = try EndpointAPIKey(parsing: key)
        XCTAssertFalse(String(describing: parsed).contains("fixture"))
        XCTAssertFalse(String(reflecting: parsed).contains("fixture"))
        var dumped = ""
        dump(parsed, to: &dumped)
        XCTAssertFalse(dumped.contains("fixture"))
    }

    // MARK: Keychain

    func testKeychainServiceHasItsOwnNamespaceFollowingTheConfigFolder() {
        let service = EndpointKeyStore.serviceName(for: profile)
        let expected = SHA256.hash(data: Data(CredentialStore.serviceName(for: profile).utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(service, "Claudock-endpointkey-" + expected)
        let renamed = Profile(command: "claude-renamed", configDirectory: profile.configDirectory, managed: true, authKind: .endpoint,
                              endpoint: configuration)
        XCTAssertEqual(EndpointKeyStore.serviceName(for: renamed), service)
        XCTAssertFalse([APIKeyStore.serviceName(for: profile), MintTokenStore.serviceName(for: profile),
                        CredentialStore.serviceName(for: profile), ConsoleLogin.keychainService(for: profile)].contains(service))
    }

    func testSecureStdinCommandIsHexEncodedAndOnlyForTheEndpointNamespace() throws {
        let service = EndpointKeyStore.serviceName(for: profile)
        let command = try EndpointKeyStore.securityWriteCommand(Data(key.utf8), account: "fixture-user", service: service)
        let text = String(decoding: command, as: UTF8.self)
        XCTAssertEqual(text, "add-generic-password -U -a \"fixture-user\" -s \"\(service)\" -X \""
                       + Data(key.utf8).map { String(format: "%02x", $0) }.joined() + "\"\n")
        XCTAssertFalse(text.contains(key))
        XCTAssertThrowsError(try EndpointKeyStore.securityWriteCommand(Data(repeating: 97, count: 2017), account: "fixture-user", service: service))
        XCTAssertThrowsError(try EndpointKeyStore.securityWriteCommand(Data(key.utf8), account: "bad\"account", service: service))
        for foreign in [APIKeyStore.serviceName(for: profile), MintTokenStore.serviceName(for: profile), CredentialStore.serviceName(for: profile),
                        service + "\n"] {
            XCTAssertThrowsError(try EndpointKeyStore.securityWriteCommand(Data(key.utf8), account: "fixture-user", service: foreign))
        }
    }

    func testSaveWritesOnceAndVerifiesTheReadback() throws {
        var writes: [Data] = [], reads: [String] = []
        try EndpointKeyStore.save(EndpointAPIKey(parsing: key), profile: profile, securityWrite: { writes.append($0) }, securityRead: { service in
            reads.append(service)
            return (Data((self.key + "\n").utf8), 0)
        })
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(reads, [EndpointKeyStore.serviceName(for: profile)])
        XCTAssertFalse(String(decoding: try XCTUnwrap(writes.first), as: UTF8.self).contains(key))
        let parsed = try EndpointAPIKey(parsing: key)
        for readback in [(Data((otherKey + "\n").utf8), Int32(0)), (Data(), Int32(44)), (Data(), Int32(36))] {
            XCTAssertThrowsError(try EndpointKeyStore.save(parsed, profile: profile, securityWrite: { _ in }, securityRead: { _ in readback })) {
                XCTAssertEqual($0 as? EndpointKeyError, .keychainWriteFailed)
            }
        }
    }

    func testReadsTellAMissingKeyFromAnUnavailableOrInvalidOne() throws {
        XCTAssertNil(try EndpointKeyStore.read(profile: profile, securityRead: { _ in (Data(), 44) }))
        XCTAssertEqual(try EndpointKeyStore.read(profile: profile, securityRead: { _ in (Data((self.key + "\n").utf8), 0) })?.value, key)
        XCTAssertThrowsError(try EndpointKeyStore.read(profile: profile, securityRead: { _ in (Data(), 36) })) {
            XCTAssertEqual($0 as? EndpointKeyError, .keychainUnavailable)
        }
        for stored in ["", "\n", "two words\n", "sk-ant-api03-fixture\n", "export DEEPSEEK_API_KEY=" + key + "\n"] {
            XCTAssertThrowsError(try EndpointKeyStore.read(profile: profile, securityRead: { _ in (Data(stored.utf8), 0) }), stored) {
                XCTAssertEqual($0 as? EndpointKeyError, .invalidStoredKey)
            }
        }
    }

    func testStatusLooksUpAttributesOnlyAndUndoDeletesOnlyThisItem() throws {
        var commands: [[String]] = []
        XCTAssertTrue(try EndpointKeyStore.isSaved(profile: profile, security: { commands.append($0); return 0 }))
        XCTAssertFalse(try EndpointKeyStore.isSaved(profile: profile, security: { _ in 44 }))
        XCTAssertThrowsError(try EndpointKeyStore.isSaved(profile: profile, security: { _ in 36 })) {
            XCTAssertEqual($0 as? EndpointKeyError, .keychainUnavailable)
        }
        XCTAssertEqual(commands, [["find-generic-password", "-a", NSUserName(), "-s", EndpointKeyStore.serviceName(for: profile)]])
        commands = []
        EndpointKeyStore.delete(profile: profile, security: { commands.append($0); return 0 })
        EndpointKeyStore.delete(profile: Profile(command: "claude-work", configDirectory: "/synthetic/work", managed: true),
                                security: { commands.append($0); return 0 })
        XCTAssertEqual(commands, [["delete-generic-password", "-a", NSUserName(), "-s", EndpointKeyStore.serviceName(for: profile)]])
    }

    func testOnlyManagedEndpointProfilesReachTheirKeychainItem() throws {
        let parsed = try EndpointAPIKey(parsing: key)
        let unsupported = [Profile(command: "claude-work", configDirectory: "/synthetic/work", managed: true),
                           Profile(command: "claude-console", configDirectory: "/synthetic/console", managed: true, authKind: .apiKey),
                           Profile(command: "claude-imported", configDirectory: "/synthetic/imported", authKind: .endpoint, endpoint: configuration),
                           Profile(command: "claude-relative", configDirectory: "relative", managed: true, authKind: .endpoint, endpoint: configuration),
                           Profile(command: "claude-bare", configDirectory: "/synthetic/bare", managed: true, authKind: .endpoint)]
        for candidate in unsupported {
            XCTAssertThrowsError(try EndpointKeyStore.read(profile: candidate, securityRead: { _ in XCTFail("reached Keychain"); return (Data(), 44) })) {
                XCTAssertEqual($0 as? EndpointKeyError, .unsupportedProfile, candidate.command)
            }
            XCTAssertThrowsError(try EndpointKeyStore.save(parsed, profile: candidate, securityWrite: { _ in XCTFail("reached Keychain") },
                                                           securityRead: { _ in XCTFail("reached Keychain"); return (Data(), 44) })) {
                XCTAssertEqual($0 as? EndpointKeyError, .unsupportedProfile, candidate.command)
            }
        }
    }

    // MARK: Launch

    func testLaunchEnvironmentPinsTheModelEverywhereAndKeepsUnrelatedVariables() throws {
        let hostile = ["ANTHROPIC_API_KEY": "parent-api-key", "ANTHROPIC_AUTH_TOKEN": "parent-token", "ANTHROPIC_BASE_URL": "https://parent.invalid",
                       "ANTHROPIC_MODEL": "claude-opus-5-5", "ANTHROPIC_SMALL_FAST_MODEL": "claude-haiku-5-5", "CLAUDE_CODE_SUBAGENT_MODEL": "opus",
                       "CLAUDE_CONFIG_DIR": "/synthetic/other", "CLAUDE_CODE_OAUTH_TOKEN": "parent-oauth", "OTEL_EXPORTER_OTLP_ENDPOINT": "https://otel.invalid",
                       "OTEL_LOGS_EXPORTER": "otlp", "CLAUDE_CODE_ENABLE_TELEMETRY": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "0",
                       "ANTHROPIC_DEFAULT_MODEL": "claude-opus-5-5", "CLAUDE_CODE_AUTO_MODE_MODEL": "claude-sonnet-5-5",
                       "CLAUDE_CODE_BG_CLASSIFIER_MODEL": "x", "CLAUDE_CODE_WORKFLOW_SUBAGENT_MODEL": "x", "ANTHROPIC_CUSTOM_MODEL_OPTION": "x",
                       "ANTHROPIC_CUSTOM_MODEL_OPTION_NAME": "x", "CLAUDE_CODE_USE_GATEWAY": "1",
                       "E2E_UNRELATED": "kept", "PATH": "/usr/bin:/bin"]
        let base = try LaunchCommand.environment(profile: profile, inherited: hostile)
        let environment = EndpointLaunch.environment(base, configuration: configuration, key: key)
        XCTAssertEqual(environment, [
            "CLAUDE_CONFIG_DIR": "/synthetic/claudock-endpoint", "ANTHROPIC_BASE_URL": deepseek, "ANTHROPIC_AUTH_TOKEN": key,
            "ANTHROPIC_MODEL": "deepseek-flash", "ANTHROPIC_DEFAULT_OPUS_MODEL": "deepseek-flash", "ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek-flash",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "deepseek-flash", "ANTHROPIC_DEFAULT_FABLE_MODEL": "deepseek-flash",
            "ANTHROPIC_SMALL_FAST_MODEL": "deepseek-flash", "CLAUDE_CODE_SUBAGENT_MODEL": "deepseek-flash",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_NON_ESSENTIAL_MODEL_CALLS": "1", "CLAUDE_CODE_DISABLE_1M_CONTEXT": "1",
            "E2E_UNRELATED": "kept", "PATH": "/usr/bin:/bin"])
    }

    func testOnlyThePinnedModelMayBeChosenOnTheCommandLine() throws {
        let allowed: [[String]] = [[], ["-p", "hi"], ["--model", "deepseek-flash"], ["--model=deepseek-flash"], ["--fallback-model", "deepseek-flash"],
                                   ["--fallback-model=deepseek-flash,deepseek-flash"], ["-p", "--model deepseek-v4-pro"],
                                   ["--resume", "abc", "--print", "x"], ["-p", "--model"], ["--advisor", "deepseek-flash"]]
        for arguments in allowed {
            XCTAssertNoThrow(try EndpointLaunch.checkModelArguments(arguments, configuration: configuration), "\(arguments)")
        }
        let refused: [([String], String)] = [
            (["--model", "deepseek-v4-pro"], "--model"), (["-p", "x", "--model=deepseek-v4-pro"], "--model"), (["--model", "opus"], "--model"),
            (["--model", "Deepseek-Flash"], "--model"), (["--model="], "--model"), (["--model", "deepseek-flash", "--model", "sonnet"], "--model"),
            (["--fallback-model", "deepseek-v4-pro"], "--fallback-model"), (["--fallback-model=deepseek-flash,deepseek-v4-pro"], "--fallback-model"),
            (["--fallback-model", "deepseek-flash,"], "--fallback-model"), (["--advisor", "deepseek-v4-pro"], "--advisor"),
            (["--advisor=opus"], "--advisor"),
            // Claude Code takes `--` as the value of an option that needs one, so `--` does not end the check.
            (["--append-system-prompt", "--", "--model", "deepseek-v4-pro"], "--model"), (["-p", "--", "--model", "deepseek-v4-pro"], "--model")]
        for (arguments, option) in refused {
            XCTAssertThrowsError(try EndpointLaunch.checkModelArguments(arguments, configuration: configuration), "\(arguments)") { error in
                XCTAssertEqual(error as? EndpointLaunchError, .modelNotAllowed(option: option, pinned: "deepseek-flash"), "\(arguments)")
                XCTAssertTrue(error.localizedDescription.contains("deepseek-flash"))
                XCTAssertFalse(error.localizedDescription.contains("v4-pro"), "the refused value is not echoed")
            }
        }
        let wide = try EndpointConfiguration(baseURL: deepseek, model: "deepseek-flash[1m]")
        XCTAssertNoThrow(try EndpointLaunch.checkModelArguments(["--model", "deepseek-flash[1m]"], configuration: wide))
        XCTAssertThrowsError(try EndpointLaunch.checkModelArguments(["--model", "deepseek-flash"], configuration: wide))
    }

    // MARK: Kinds

    func testKindsAreExplicit() {
        XCTAssertEqual(ProfileAuthKind.allCases, [.subscription, .apiKey, .consoleLogin, .endpoint])
        XCTAssertEqual(ProfileAuthKind.allCases.filter(\.isConsole), [.apiKey, .consoleLogin])
        XCTAssertEqual(ProfileAuthKind.allCases.filter(\.isEndpoint), [.endpoint])
        XCTAssertEqual(ProfileAuthKind.endpoint.title, "Third-party endpoint")
    }

    func testEndpointProfilesNeverTakeConsoleOrSubscriptionPaths() throws {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        XCTAssertEqual(AccountAvailability.classify(profile: profile, snapshot: nil, error: nil, credit: nil, now: now), .untracked)
        XCTAssertEqual(AccountAvailability.classify(profile: profile, snapshot: nil, error: .noCredentials, credit: nil, creditFailed: true, now: now), .untracked)
        for required in [false, true] {
            for arguments in [[], ["setup-token"], ["--resume", "abc"]] {
                XCTAssertEqual(try InferenceTokenPolicy.launchCredential(profile: profile, claudeArguments: arguments, signIn: false, requireToken: required,
                                                                         mint: { _ in XCTFail("An endpoint profile must not read an inference token"); return nil }),
                               .endpointKey)
            }
        }
        XCTAssertThrowsError(try ConsoleLogin.isSignedIn(profile: profile, security: { _ in XCTFail("reached Keychain"); return 0 })) {
            XCTAssertEqual($0 as? ConsoleLoginError, .unsupportedProfile)
        }
        XCTAssertThrowsError(try APIKeyStore.isSaved(profile: profile, security: { _ in XCTFail("reached Keychain"); return 0 })) {
            XCTAssertEqual($0 as? APIKeyError, .unsupportedProfile)
        }
        XCTAssertThrowsError(try InferenceCredential.environmentToken(profile: profile, mint: { _ in XCTFail("read a token"); return nil })) {
            XCTAssertEqual($0 as? MintTokenError, .unsupportedProfile)
        }
        XCTAssertThrowsError(try APICreditStore.setBalance(5, profile: profile, home: "/synthetic/no-home", now: now)) {
            XCTAssertEqual($0 as? APICreditError, .endpointProfile("deepseek"))
            XCTAssertTrue($0.localizedDescription.contains("billed per token by the provider"))
        }
    }
}
