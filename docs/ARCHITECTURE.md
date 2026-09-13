# Architecture

Claudock is a Swift package with a macOS menu bar executable (`ClaudockApp`), a bundled CLI (`claudock`), and a separately testable core. Both executables use the same registry and launch validation. Its primary interface is a SwiftUI view inside a transient AppKit `NSPopover`, anchored to an `NSStatusItem`. Clicking outside dismisses the popover. An explicit window action opens the same dashboard in an ordinary closable, minimizable, resizable `NSWindow`. The app bundle uses `LSUIElement` so it behaves as a menu bar utility without a permanent Dock icon.

## Components

| Component | Responsibility |
| --- | --- |
| `ProfileDiscovery` | Read bounded zsh startup files and literal includes; recognize `claude-*` aliases/functions and bind them to literal config directories. |
| `ProfileStore` / `ProfileManager` | Own the registry, import bounded shell discovery on first use or explicit rescan, and mutate profile names/bindings while preserving Claude data and shell files. |
| `ShellIntegration` | Opt in to a namespaced CLI command and missing profile shortcuts, upgrade unchanged owned integration files, and synchronize only owned functions through zsh hooks. |
| `ClaudockCLI` | Validate command arguments before I/O, expose registry CRUD and quota, and launch Claude with direct `execve` in the current working directory. |
| `CredentialStore` | Read the exact profile credential, preserve its complete JSON, and conditionally update the existing Keychain item or credential file. |
| `CredentialRefresher` / `ClaudeCredentialLock` | Renew expired or rejected access tokens with shared Claude locks, scoped OAuth requests, conditional persistence, and bounded retries. |
| `UsageClient` | Fetch the HTTPS usage endpoint with an ephemeral session, no redirects, timeouts, and status-specific errors. |
| `UsageSnapshot` | Decode supported usage-response shapes into displayable windows and reset dates. |
| `SessionAnalytics` | Scan bounded local session logs, deduplicate message usage, and aggregate recorded tokens by day and profile. |
| `MonitorStore` | Coordinate discovery, sequential polling, per-account state, cooldowns, and preferences on the main actor. |
| `MonitorView` | Render account limits, stale states, settings, and profile actions. |
| `OverviewView` / `SessionsView` | Show local activity and searchable sessions; collect an explicit target profile before a continuation. |
| `TerminalLauncher` / `LaunchCommand` / `ClaudeExecutable` | Resolve the shared executable preference, isolate the profile environment, and quote arguments for GUI Terminal launches; CLI reuses environment validation with direct argument vectors. |
| `WelcomeView` | Introduce the app, detect Claude, and route new users to add/import profiles. |
| `AppDelegate` | Own the menu bar item, transient popover, optional ordinary dashboard window, and application lifecycle. |

## Refresh flow

1. Load the app-owned profile registry. On first use, import active statically discovered shell profiles, including sourced legacy wrappers; later shell rescans are explicit.
2. Reuse the prior state only when the profile binding still matches.
3. Skip profiles whose rate-limit cooldown has not elapsed.
4. Read credentials for one profile and make its request. Discovery and credential I/O run off the UI thread.
5. Replace the successful reading, or retain it with an explicit stale/error state.
6. After the account pass, schedule the next automatic check using the selected 1-, 5-, or 15-minute interval. Manual refresh has a separate one-minute cooldown.

There is no background web service, database, or credential synchronization. Usage readings are in memory. Dismissing the popover or closing the dashboard leaves polling active until the menu bar app quits. Polling resumes after sleep when the next check is due.

## Local analytics

`SessionAnalytics` reads main JSONL sessions, direct subagent logs, and recognized workflow logs under `<project>/<sessionUUID>/subagents/workflows/wf_*/` for a selected 7- or 30-day window. It resolves the selected config and `projects` roots, including symlinked roots, while rejecting symlinked descendants/files. New profiles share the default `~/.claude` history through symlinks. Multiple profiles that resolve to the same history root share one scan and contribute to the `shared-history` bucket, displayed as **Shared history**. CLI logs do not provide a reliable account identity, so shared-root totals remain unattributed to individual accounts. Per-profile totals require isolated history folders, such as an imported directory with its own history.

File enumeration, line length, file size, cumulative bytes, message count, and elapsed time are bounded; incomplete or invalid input produces a partial-history flag. The background scan allows 120 seconds, 8 GiB total, 512 MiB per file, 32 MiB per line, 50,000 files, 400,000 directory entries, and 250,000 unique message records. `eligibleFiles`, `scannedFiles`, and `scannedBytes` provide coverage alongside the partial flag; equal file counts do not imply all records were valid.

For assistant records with usable usage counters, the scanner adds input, output, cache-read, and cache-creation tokens. Duplicate records are keyed globally across main, subagent, copied, and forked logs by message ID, falling back to request or record ID. Repeated snapshots of an identified message merge counter maxima. Across isolated histories, duplicated history is attributed to the oldest local file copy; shared roots retain shared attribution. This heuristic prevents duplicated transcripts from adding the same message twice; it does not establish account billing ownership. Missing identifiers or malformed counters make the scan partial.

Calendar-day chart buckets use the Mac's current calendar. Reused context across distinct requests remains part of each request's recorded token totals. The headline is processed tokens including cache counters; input plus output is shown separately. `subagentTokens` identifies an included subset, not an additional amount to add to the total. Neither the aggregate nor per-profile figures are subscription quota, billed cost, or unique text. The Overview cache reuse ratio is cache-read tokens divided by input plus cache-read plus cache-creation tokens.

Analytics runs off the UI thread. A generation number prevents an earlier scan from replacing a newer requested period. Summaries remain in memory. The scanner extracts usage, local project paths, timestamps, and session identifiers for the UI; transcripts and analytics are not uploaded by this app.

## Session continuation

The Sessions tab shares the analytics period and lists up to 100 recent search matches. A user explicitly chooses a target profile for **Continue as…**. The app verifies the source remains a regular, non-symlink JSONL file and that the project directory exists, then launches the selected Claude executable with the absolute source path as `--resume` and `--fork-session`.

The launcher clears conflicting provider, credential, model, and nested-session environment variables and supplies the target config directory. It writes a private temporary `.command` file and opens it with Terminal through `NSWorkspace`; the script deletes itself before executing Claude. It does not stop the original process or move the source transcript. Claude owns fork persistence, authentication, project trust, and tool permissions. Absolute-JSONL resume argument support was checked against Claude Code 2.1.263; source inspection or launch alone does not establish a completed live continuation.

## Preferences and onboarding

The three-step welcome sheet explains limits versus local activity, detects Claude, offers account setup, and explains how to open and dismiss the menu bar popover. Users can select a custom executable if discovery misses it. `UserDefaults` stores appearance, accent, compact layout, email visibility, usage sorting, refresh interval, executable path, and onboarding completion. Available appearances are System, Light, and Dark; accents are Copper, Sage, Iris, and Blue. The app delegates optional launch-at-login registration to `SMAppService`.

`--demo` opens the ordinary dashboard window with synthetic profiles and readings, without account discovery, Keychain access, history scanning, or usage HTTP requests. A visible DEMO label identifies it, and profile mutations and session launches are disabled. It supports public screenshots and UI checks without personal data. Appearance controls still use local preferences; demo rendering is not evidence of live service or authentication behavior.

`--analytics` performs a read-only local scan and prints token categories and coverage. `--through` supplies an ISO 8601 upper timestamp; the diagnostic's lower bound remains the start of the current seven-calendar-day window. It does not read credentials or call the usage endpoint, and it does not freeze files while Claude writes them. Diagnostic output can include profile names and usage patterns and is not a public fixture.

## Profile and authentication identity

`~/Library/Application Support/Claudock/profiles.json` is the authoritative profile registry for both executables. Profile records have stable registry identities, friendly names/commands, and exact Claude config-directory bindings. New account directories use `accounts/<stable-id>/claude/`; a rename changes the label without changing its config directory or path-derived Keychain service. Imported directories are never moved. The default profile retains Claude Code's default credential service. Credential lookup must never cross to a different profile when an entry is missing or unavailable.

New profiles retain a private UUID config root for independent authentication, while symlinks share projects/history and common settings, plugins, and skills from `~/.claude`. Credential identity remains bound to the private config path; sharing history does not merge logins. Shared settings changes apply to the profiles using those links. Explicit folder imports retain their existing layout and do not receive automatic shared-data links.

Initial import statically reads active shell declarations, including the prior `~/.config/claude-usage/profiles.zsh` only when sourced. Orphaned legacy JSON registries are preserved but not automatically imported. Those legacy files and source lines remain intact. Later polling loads the registry rather than reinterpreting startup files; a deliberate shell-import action refreshes external declarations. Profile add, rename, and removal operate on the registry and do not write `.zshrc`. Removal preserves the Claude config directory, conversations, credential entry, and external shell wrappers.

Shell integration is a separate, optional mutation. It writes `~/.config/claudock/init.zsh` and a marked loader block in `.zshrc`, taking an exact backup before modifying an existing shell file. Version 2 exposes the `claudock` function bound to the installed app's bundled executable and creates missing `claude-NAME` shortcut functions. Existing user aliases, functions, and executables take priority; the default `claude` command is preserved.

Shortcut synchronization runs at source time and through zsh `precmd` and `preexec` hooks. `preexec` covers a GUI profile addition made while the shell is already sitting at a prompt, before that user's next entered command executes. The internal `claudock shell profile-names` emitter reads an existing registry snapshot as data without discovery, registry creation/writes, profile locking, credential access, or networking. Generated shortcuts forward the full selector through `claudock run`, preserving argument boundaries. Rename/removal cleanup only removes functions whose current bodies exactly match the definitions Claudock recorded; externally changed definitions remain intact. Profile CRUD continues to update only the registry and never rewrites `.zshrc`.

The 1.4.0 app upgrades an already-enabled, unchanged owned v1 integration to v2 on startup. It does not enable integration when off, and upgrade failures appear in Manage profiles. An existing v1 Terminal session must source `~/.config/claudock/init.zsh` once or open a new tab to install the new hooks. Subsequent profile changes use those loaded hooks and require no further reload. Disabling integration removes the owned startup files/block; open a new shell to unload previously installed functions and hooks. Re-enable integration after moving the app to update the bundled executable path.

The app and CLI use the same custom executable preference domain. The bundle identifier remains `io.github.claudeusage.ClaudeUsage` during the Claudock branding migration to preserve existing preferences and login-item identity. Branding does not move account directories or alter credential bindings.

`claudock run NAME -- ARGUMENTS` and `claudock profile login NAME` replace the current CLI process with Claude through POSIX `execve`; no intermediate shell evaluates arguments. They retain the invoking working directory and terminal. `LaunchCommand.environment` validates supported profiles and clears conflicting credential, provider, model, and nested-session variables before setting the account's literal `CLAUDE_CONFIG_DIR` (or clearing it for the default account). Interactive login happens in Claude Code only after a deliberate action. Discovery never initiates login. Quota monitoring can renew an expired access token through the saved OAuth refresh token.

`claudock usage` requests quota sequentially for supported profiles and emits tab-separated window percentages/reset timestamps. It skips unresolved and Vertex profiles with a message, reports per-account failures, and returns a failure status when a requested account fails. No email or credential fields are printed. It performs no automatic polling; the GUI owns scheduled refresh and cooldown state.

## Limits and external dependencies

The internal Anthropic usage endpoint is a compatibility boundary, not a supported public API contract. Unknown or invalid response shapes must produce a clear error instead of fabricated zero usage. A last-known reading must be identifiable as stale. Vertex AI billing does not map to Claude subscription allowances.

The zsh reader is a constrained static parser, not a complete shell interpreter. It follows literal includes with size/depth/count bounds, keeps quoted constructs opaque, and skips sensitive-looking paths. It deliberately cannot reconstruct arbitrary dynamically generated configuration. Manual import is the escape hatch.

## Packaging and verification

`scripts/bootstrap.sh` validates the build environment, runs tests, packages into a fresh output directory, and opens the app. `scripts/build-app.sh` builds the current architecture, stages a bundle in the private system temporary directory, generates an AppKit icon, adds the plist, signs the bundled CLI and then the containing app, and verifies both signatures. Staging uses private permissions; public app directories, executable, and resource permissions are normalized before signing so a caller's permissive umask cannot make the app group/world-writable. It refuses to overwrite an existing destination app. Release signing and notarization require the maintainer's own Apple credentials.

Unit tests should use temporary homes and synthetic account responses. App interaction, real Keychain permissions, real Claude authentication, upstream compatibility, signing/notarization, and a packaged launch are distinct checks; a unit-test pass does not establish all of them. CI packages a local-build artifact and does not publish a public release.

Resolved subscription profiles copy an exact Claudock selector through the bundled CLI, including imported profiles. Shell-disabled users receive a quoted absolute CLI path. Only unsupported custom/Vertex wrappers retain a raw shell command. Registry deduplication uses Claude credential-service identity, while analytics groups resolved history directories; these are separate identities.

## Automatic credential renewal

The resident app attempts one renewal-and-quota-retry cycle on local access-token expiry or quota HTTP 401. HTTP 403, rate limits, offline errors, and server failures do not trigger renewal. The refresh exchange uses the saved scopes and client ID, or Claude Code's public first-party client ID when no custom ID is stored. It sends no model prompt and requests no longer token lifetime.

The implementation follows the directory-lock and JSON formats inspected in Claude Code 2.1.263. It acquires `.oauth_refresh.lock` and the canonical configuration-directory path plus `.lock`, rereads the credential, and adopts another process's updated token when present. The separate `.storage-write.lock` protects short permission-check and read/merge/write/readback operations; it is never held during HTTP. Lock directories stay empty and receive heartbeats. Claudock refuses to steal pre-existing locks, including stale ones; Claude Code can recover its abandoned locks.

Writes target the existing backend, preserve unrelated JSON fields, and retain a returned replacement refresh token. Keychain writes use the same trusted `security -i` stdin path as Claude Code to preserve existing reader access. The app checks the complete document and persistent item identity before and after the write, and refuses a missing item before writing. The underlying `security -U` operation is an upsert, so these cooperative locks and guarded writes are not a transactional guarantee against every external writer: Claude Code has a logout fallback that can bypass its storage lock, and same-user tools can ignore the protocol. An identity mismatch is reported without deleting the other item. File writes use an existing-only atomic swap. A Keychain failure never switches to plaintext.

The Keychain stdin command has a 4,032-byte ceiling. Claudock fails visibly when the encoded document exceeds it; it never falls back to secrets in process arguments. A renewed response that exceeds the ceiling is retained in memory with the other pending-save failures.

Before dispatch, the app durably publishes a private, secret-free `.claudock-refresh-<service-hash>.json` marker in the profile configuration directory. It records only the fingerprint of the submitted token pair. A lost or malformed HTTP response, post-dispatch cancellation, or process crash leaves the marker in place; another process will not resend that same pair. A newer credential clears the old marker. Definitive authentication/rate-limit responses and confirmed saves clear their matching marker. Corrupt markers fail closed.

A successful exchange that cannot be saved stays in memory for a later save attempt, avoiding another POST with the old refresh token. Matching tokens on a changed authoritative backend can receive the pending result while retaining that backend's other fields. Exiting the app loses an unsaved result; the durable marker prevents blind reuse and directs the user to Claude Code or re-login. Credential contention/save failures back off for a minute; an explicit invalid grant is not retried while the token pair remains unchanged. Cancellation before dispatch is not cached. No token or raw OAuth error body belongs in diagnostics.

The one-shot `claudock usage` command reads quota without rotating credentials. It directs users with an expired token to the resident app or their Claude profile, so exiting the command cannot discard a pending rotation.
