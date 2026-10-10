# Contributing

Claudock is a native macOS utility. Contributions should make many-account workflows easier while keeping profile credentials and shell configuration safe.

## Local development

Use macOS 14 or newer and a full Xcode 16 or newer installation. There are no third-party Swift package dependencies.

```sh
xcrun swift test
python3 Tests/CLIIntegration/check.py
./scripts/build-app.sh dist/development
open 'dist/development/Claudock.app'
```

Choose a fresh output directory for each package build, or move your previous app first. The build script intentionally refuses to overwrite a bundle. For a custom Xcode installation, export its `Contents/Developer` path as `DEVELOPER_DIR`.

Core logic belongs in `Sources/UsageCore`; UI and macOS integration belong in `Sources/ClaudeUsage`; the bundled command-line entry point is `Sources/ClaudockCLI`. The historical GUI source-directory name and bundle identifier are retained during the Claudock migration. Keep I/O injectable or isolate it so tests can use temporary directories and synthetic data. Do not run a test against real profiles, credentials, shell files, or live usage endpoints.

The CLI smoke harness compiles the exact CLI, `Profile`, and `LaunchCommand` sources against synthetic storage, executable-discovery, credentials, network, and shell boundaries. It exercises literal argument forwarding, the current directory, exit-status propagation, authentication environment isolation, and malformed commands without accessing real accounts. Temporary binaries stay under `.build/` and are removed afterward. Its printed source hashes identify the checked code; it does not establish real authentication or live quota compatibility. It also keeps README.md honest. Every `claudock` command in the README's shell code blocks (`sh`, `bash`, `zsh`, `shell`, or `console`) must be accepted by the CLI parser, with standard input empty. Usage lines, such as the README's command cheat sheet repeats from `claudock help`, expand to each form they allow, with placeholders such as `NAME` replaced by synthetic values; other examples run as written. The code blocks must show every usage line of `claudock help`, and every relative link, image, and heading anchor must exist with the exact letter case. Inline code in prose and tables is not run. Change the README and the CLI together.

`python3 Tests/CLIIntegration/concurrency_e2e.py` starts twelve launches and a rename at once against one temporary registry, first while it is held and then all together; it uses no Keychain item.

`python3 Tests/CLIIntegration/usage_e2e.py` drives `claudock usage` and `claudock available` through the shared usage cache, cooldowns, request spacing, and the fetch lock against a stub usage endpoint on 127.0.0.1 that answers 200 or 429 per profile and timestamps every request. It builds a test CLI with `-D CLAUDOCK_TEST_USAGE_ENDPOINT` in `.build/usage-endpoint-test` and deletes that binary after the run: only such a build reads its endpoint from `CLAUDOCK_TEST_USAGE_ENDPOINT`, so the ordinary debug binary that other checks use is never replaced and no shipped build can be redirected. Every `claudock` it starts also runs under `sandbox-exec` with outbound network limited to loopback. Profiles get synthetic `.credentials.json` files in throwaway homes, and their Keychain lookups find no item; it creates no Keychain item. Time passing is simulated by editing the cache, and two checks wait out the 30-second lock wait. `python3 Tests/CLIIntegration/api_key_e2e.py`, `python3 Tests/CLIIntegration/token_e2e.py`, `python3 Tests/CLIIntegration/credit_e2e.py`, `python3 Tests/CLIIntegration/console_login_e2e.py`, and `python3 Tests/CLIIntegration/endpoint_e2e.py` drive the real `claudock` binary end to end against your login Keychain, for Console API-key profiles, CLI inference tokens, Console credit, Console-login profiles, and third-party endpoint profiles. The credit check's fake `claude` posts OTLP events built from `otlp_logs_fixture.json`, a sanitized export from Claude Code 2.1.295 with synthetic identifiers. The Console-login check's fake `claude auth login --console` saves a synthetic key under the `Claude Code-<hash>` service Claude Code 2.1.295 uses for the profile's config folder, and never touches the default profile's own `Claude Code` item. Each builds the CLI and runs it in throwaway homes: `CFFIXED_USER_HOME` redirects Claudock's home while `HOME` stays real so `security` finds the login Keychain. A fake `claude` records each launch, keys and tokens are random synthetic values, and every Keychain item a check creates is deleted before it exits, also after a failure. The items the checks add themselves, such as a synthetic Claude Code login to see `profile remove` list it, or an inference-token item to prove a refused `profile clear-token` deletes nothing, take their services from the throwaway home's config path, and the harness refuses the default profile's five real items (Claude Code's login and Console key, and Claudock's token, API key, and endpoint key under the login's name). They need an unlocked login Keychain and refuse to run while Claudock has a custom Claude executable preference, so the real Claude is never launched. Preferences cannot be redirected to a temporary home, so `token_e2e.py`, `console_login_e2e.py`, and `endpoint_e2e.py` turn the shared `requireInferenceToken` setting on and off through the CLI and restore its original value before exiting, also after a failure. The checks refuse to start while that setting is on; if a run was killed while it was on, `defaults delete io.github.claudeusage.ClaudeUsage requireInferenceToken` restores the default. `endpoint_e2e.py` also writes synthetic compact transcripts into its throwaway home's shared `projects` folder to check which sessions an endpoint profile refuses to resume.

`python3 Tests/CLIIntegration/endpoint_live_smoke.py` is opt-in and never part of CI: it makes one real request to a third-party endpoint, billed by its provider. It needs `CLAUDOCK_LIVE_ENDPOINT_KEY_FILE` (a key file: the raw key or one `export NAME=value` line), `CLAUDOCK_LIVE_ENDPOINT_URL`, and `CLAUDOCK_LIVE_ENDPOINT_MODEL`, and takes `CLAUDOCK_LIVE_ENDPOINT_BEHAVES_AS`. It adds the profile in a throwaway home with the key file on standard input, runs the installed Claude Code through a wrapper with `HOME` set to that home and the auto-updater off, checks that the answer came from the pinned model only, reports whether Claude Code warned about an unknown model, and deletes the Keychain item and the home afterwards. It never prints the key.

## Pull requests

Describe the user-visible problem, the resulting behavior, and how it was verified. Include focused tests for parsing, profile isolation, persistence, and failure handling when those contracts change. For visible changes, prefer screenshots from the synthetic preview:

```sh
'dist/development/Claudock.app/Contents/MacOS/ClaudockApp' --demo
```

Demo mode opens an ordinary dashboard window with synthetic accounts, limits, and local activity; it skips real account/history/network reads and disables profile mutations and session launches. If using a normal screenshot instead, redact account emails, local paths, and usage details. Verify keyboard access, VoiceOver labels, small-window layout, and an account with an error or no data. In normal mode, also verify menu bar popover dismissal on outside clicks and the dashboard's separate minimize/close controls.

Before submitting:

- Run `xcrun swift test`, validate CLI help and malformed arguments without touching real profiles, and package both executables.
- Test registry CRUD and optional shell integration independently. Profile changes must leave `.zshrc` unchanged, and disabling integration must preserve unrelated shell content and existing Claude wrappers.
- Check the app opens and the changed interaction works on your Mac.
- Keep logs, crash reports, screenshots, and test fixtures free of personal data and credentials.
- Document any new local files, permission prompts, network requests, or migration behavior.
- State your macOS version, Xcode version, and architecture. Do not imply other platforms or architectures were tested.

Changes must preserve explicit account-to-config-directory binding. Do not fall back to another account's Keychain entry. Do not execute shell source during discovery or interpolate profile input into executable shell/AppleScript without an audited escaping boundary. Removal must preserve Claude conversations and credentials unless a separately designed destructive action explicitly requires them to be erased; the only such action is deleting a saved inference token (`profile clear-token`, **Delete token**), and removal itself lists the credentials it keeps.

The OAuth usage endpoint is undocumented. Use sanitized, synthetic fixtures to cover response changes; do not commit raw service responses from a real account. Monitoring failures should remain visible and retain the last successful reading, without retry loops that overwhelm the endpoint.

Please report potential vulnerabilities privately as described in [SECURITY.md](SECURITY.md). Do not include exploit details or secrets in a public issue.
