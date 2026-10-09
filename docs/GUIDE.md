# Claudock user guide

A native Mac menu bar app that puts your Claude Code accounts in one place. Check subscription limits, explore recorded token activity, continue a saved session with another profile, and manage profiles from one app-owned registry. Optional shell integration adds `claudock` and missing `claude-{profile}` shortcuts while preserving the commands you already use.

Built with SwiftUI and AppKit, with no third-party package dependencies. Requires macOS 14 or newer.

Claudock is an independent open-source project, unaffiliated with Anthropic. Live subscription limits use Claude's undocumented OAuth usage endpoint. Availability and response formats can change without notice; this app cannot guarantee continuous access.

<p><img src="screenshots/accounts.png" alt="Synthetic account usage preview" width="350"> <img src="screenshots/overview.png" alt="Synthetic local token dashboard preview" width="350"></p>

Screenshots use the built-in synthetic demo. No real account data is shown.

Each account row has **Open in Terminal** to start that profile and **Copy** to copy its launch command. Copy displays a visible confirmation; launch failures appear beside the account. Unresolved custom wrappers retain the Copy action until their subscription config is imported.

## Get started

For a packaged build, open **Claudock.app** and move it to **Applications**. No Xcode is needed to run the app. A local or CI build is signed ad hoc and is not notarized; it does not have the Gatekeeper trust of a Developer ID signed, notarized release. Only open a downloaded build from a source you trust, using macOS's standard **Privacy & Security → Open Anyway** flow if needed.

To build from source, install **Xcode 16 or newer**, open Xcode once to finish setup, then double-click **Bootstrap.command**. Or run this from the repository:

```sh
./scripts/bootstrap.sh
```

Bootstrap checks the Mac and Swift toolchain, runs the tests, packages a fresh app under `dist/Build.*/`, and opens it. It does not install dependencies, change your shell configuration, or enable launch at login. A full Xcode installation is needed for the test frameworks; Command Line Tools alone are insufficient. With Xcode in a custom location, set `DEVELOPER_DIR` to that app's `Contents/Developer` directory before running the script.

The setup guide introduces the app, imports existing Claude profiles without executing your shell, detects the Claude executable, and explains menu bar access and email visibility. New users can manage every account through the app; shell integration is optional. Choose **Add an account** to open profile management, or **Open my dashboard** to start monitoring. You can reopen the guide later with **Settings → Show setup guide…**.

Click the menu bar icon to open the usage popover; click elsewhere to close it. For more room, click the window icon in the header or right-click the menu bar icon and choose **Open dashboard**. The dashboard is an ordinary resizable window that you can minimize or close. Closing it keeps the menu bar app running.

Install and sign in to [Claude Code](https://code.claude.com/docs/en/setup) to obtain live account limits. In **Manage profiles**, enter a name and choose **Add profile** to create an account. **Import folder…** lets you use an existing Claude config directory. **Open Claude sign-in after adding** is selected by default. For an existing account, choose **Re-login**, finish authentication in Terminal, and refresh the dashboard. If Claude Code is installed in a custom location, choose **Locate Claude executable…** in Settings.

## Your profiles, together

On first use, Claudock imports the default `claude` account and statically reads zsh functions and aliases named `claude-{profile}`. Later refreshes use its own profile registry. Use **Import zsh profiles** in the app or `claudock profile import-shell` to rescan external declarations. Common declarations import directly:

```zsh
claude-work() {
  CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude "$@"
}

alias claude-personal='CLAUDE_CONFIG_DIR="$HOME/.claude-personal" claude'
```

Discovery reads `.zshenv`, `.zprofile`, and `.zshrc`, following bounded literal `source` paths. It does not execute your shell startup files. Wrappers with dynamically computed paths can need a manual import. The app also recognizes literal `_claude-native` config-directory wrappers. Secret-looking source files are skipped.

The **Accounts** tab shows **5-hour**, overall **Weekly**, and **Fable** allowances in three equally weighted, aligned rows. Percentages represent **used** allowance; the vertical pace tick marks the elapsed fraction of a known 5-hour or 7-day window. A fill past the tick is ahead of elapsed time. Short reset countdowns sit beside each percentage; hover for the full reset date or hover a label for the full window title. Limits at 100% or more include a symbol and **Full**. If several Fable allowances are returned, the most used one occupies the Fable row and the others retain compact meters below. Without a reported Fable allowance, its row shows an empty track, **—**, and **Not reported**. Missing session or overall weekly rows are omitted, and unknown durations or missing reset times have no tick. Accounts refresh sequentially, by default five minutes after a refresh completes. Choose a 1-, 5-, or 15-minute interval in Settings. Manual refresh has a one-minute cooldown. Rate limits delay the next attempt for that account, and failures retain the last reading with muted meters and a stale indicator.

## Local token activity

The **Overview** tab summarizes recorded activity across profile config folders for **7 days** or **30 days**, including today. The headline shows **processed tokens**, including cache reads and writes. **Input + Output** is shown separately, and **Subagent contribution** identifies the portion already included from recognized subagent logs. It also includes a daily chart, per-profile totals, output tokens, session count, and cache reuse. Hover a profile total for its input, output, cache read, and cache write breakdown.

Recorded tokens are the sum of input, output, cache read, and cache creation counters in local Claude session logs. Reused context counts on each request, so the total is not a count of unique text. Cache reuse is cache-read tokens divided by input plus cache-read plus cache-write tokens. These figures describe local recorded activity; they do not measure account billing or subscription allowance.

The scanner reads main session JSONL files under each profile's `projects` folder, plus direct subagent logs and recognized workflow logs under `<project>/<sessionUUID>/subagents/workflows/wf_*/`. It supports shared or symlinked `projects` roots. New profiles created by Claudock share the default `~/.claude` history. When multiple profiles point to the same history folder, the app scans it once and labels its totals **Shared history**. Claude's local logs do not provide a reliable account identifier, so shared history cannot be split accurately between those accounts.

Per-profile totals are available when history folders are isolated. Duplicate message history across main, subagent, copied, and forked logs is counted once using message identifiers; attribution among isolated copies goes to the oldest local file copy. This is a local attribution heuristic, not proof of which account was originally billed. Deleted logs, other computers, unsupported records, and unrecognized log locations are outside the totals.

History scanning runs in the background with a 120-second and 8 GiB total read budget, up to 50,000 files, 512 MiB per file, and 32 MiB per line, plus directory-entry and message limits. The dashboard shows scanned versus eligible files and the scan time. **Partial local history** means some records were unreadable, invalid, or skipped because of a limit; the total is then incomplete. Matching file counts alone do not guarantee every record was usable. The app keeps summaries in memory and does not upload transcripts or analytics.

## Continue a saved session

In **Sessions**, search by project or profile, choose a 7- or 30-day period, and select **Continue as…** beside a session. Choose the destination under **Continue using**, then select **Continue in Terminal**. The list shows up to the 100 most recent matching sessions from the local scan.

The app opens the original project directory in a new Terminal and starts Claude Code under the chosen profile with `--resume` pointing to the source JSONL file and `--fork-session`. The source file stays in place, and an existing Terminal session is not stopped. The new session uses the target profile's Claude settings and login. Claude Code's normal project trust and tool permission prompts still apply.

This requires Claude Code's support for an absolute JSONL resume path. That argument support was checked against Claude Code **2.1.263**; compatibility with other versions and a successful live account-to-account continuation are separate checks. A missing project directory or unavailable source file prevents launch. If the destination needs authentication, use **Re-login** first.

## Make it yours

Open the **…** menu in the header for Settings. Preferences are saved locally.

- **Show account emails** is optional and off by default.
- **Highest usage first** brings accounts nearest a limit to the top.
- **Compact account rows** reduces spacing in Accounts.
- **Refresh interval** offers 1, 5, or 15 minutes; the default is 5.
- **Appearance** offers System, Light, and Dark.
- **Accent** offers Copper, Sage, Iris, and Blue.
- **Launch at login** can be enabled from Settings after placing the app in Applications.
- **Locate Claude executable…** selects a custom Claude installation for actions launched by the app.
- **Require inference token to launch** makes every Claudock launch of a subscription profile use its inference token; without a valid one, the launch stops instead of using the profile's normal login. `claudock require-token on|off|status` changes the same setting.
- Closing the dashboard keeps the menu bar app running. Use Settings or right-click the menu bar icon to quit.

Claudock accepts Claude Pro, Max, Team, and Enterprise subscription profiles, and Anthropic Console accounts, through a [pasted API key](#console-api-keys) or [Claude Code's own Console sign-in](#sign-in-to-a-console-account-instead). External-provider wrappers such as Vertex, Bedrock, and Foundry are excluded from import. Legacy cloud registrations are removed from the app without deleting their configuration or shared history.

## Manage profiles

Use **Manage profiles** to add or import accounts, rename them, re-login, and remove them from Claudock. You can use these actions entirely through the app. Adding, renaming, and removing profiles do **not** change `.zshrc`.

Claudock saves names and directory bindings in:

```text
~/Library/Application Support/Claudock/profiles.json
~/Library/Application Support/Claudock/accounts/<stable-id>/claude/
~/Library/Application Support/Claudock/api-credit.json      # Console credit, once set
```

New accounts receive a private, stable config directory whose UUID does not depend on the display name. This keeps each account's login separate. The directory links its projects and history, plus common settings, plugins, and skills, to the default `~/.claude` setup. You can keep using the same conversations and preferences across accounts; changes to shared settings affect the profiles linked to them.

Importing an explicit existing folder preserves its paths, credentials, history, and layout without adding these links. Renaming never moves an account directory. Removing a profile only removes its Claudock registration; it preserves Claude conversations, settings, credentials, and original shell wrappers. The default account is protected from rename and removal.

When upgrading from Claude Usage, active shell declarations are imported, including the old `~/.config/claude-usage/profiles.zsh` when it is sourced by zsh. Legacy files remain intact; an orphaned old JSON registry with no active wrapper is not automatically imported, so use Import folder for those accounts. Claudock does not rewrite old generated wrappers or remove their source line. Existing external `claude-NAME` wrappers continue to be owned by their original shell configuration; renaming or removing a Claudock entry does not rewrite those commands.

### Optional shell integration

Open **Manage profiles → Enable claudock in zsh** to install the `claudock` command and shortcuts such as `claude-work`. Place the app in its final location first. Enabling creates `~/.config/claudock/init.zsh` and adds only this named loader block to `.zshrc`, with an exact backup before changing an existing shell file:

```zsh
# >>> Claudock shell integration >>>
[[ -r "$HOME/.config/claudock/init.zsh" ]] && source "$HOME/.config/claudock/init.zsh"
# <<< Claudock shell integration <<<
```

**First setup:** open a new Terminal tab to load the integration. It creates missing `claude-NAME` functions for available profiles. Existing aliases, functions, and executables keep their names; `claude` itself is preserved. When a name is already in use, select the account explicitly with `claudock run NAME`.

**After upgrading:** launch the updated app. It upgrades an enabled, unchanged Claudock-owned integration v1–v3 to v4 without turning integration on for users who left it off. Adapter v4 creates only named profile shortcuts. When loaded, it removes a previously generated `claude-auto` function only if its body still matches the definition recorded by Claudock; user replacements remain intact. Upgrade failures appear in Manage profiles. An already-open Terminal still has its old function definitions: open a new tab, or run this once in each existing tab:

```zsh
source ~/.config/claudock/init.zsh
```

**Later profile changes:** once v4 is loaded, shortcuts synchronize when the file is sourced, before each prompt (`precmd`), and before the next entered command (`preexec`). A profile added through the GUI while Terminal is idle is available before you run your next command. Renamed or removed profiles clean up only generated functions whose bodies still match Claudock's recorded definitions; custom edits and other user commands remain intact. These updates change the running shell's functions, not `.zshrc`.

```sh
claudock profile list
claudock profile add work
claudock profile login work
claude-work
claudock profile rename work office
claude-office
claudock run office -- --resume
claudock usage
claudock profile remove office
claudock profile add console --api-key
claudock profile set-key console
claudock profile set-credit console 200
claudock profile add team --console
```

The namespaced command and generated shortcuts call the CLI bundled inside the app. Shortcuts forward the full profile selector, such as `claude-office`, so similarly named profiles remain distinct. The internal `claudock shell profile-names` helper reads the existing registry and emits selectors as data; it does not discover accounts, create or write the registry, access credentials, or make network requests.

Disabling integration removes Claudock's marked loader block and managed integration files. Open a new Terminal tab afterward to unload its functions and hooks; already-open shells retain what they loaded. Existing user shell declarations remain unchanged.

Import a pre-existing account with `claudock profile add work --directory /absolute/config/folder`. `profile login`, `profile setup-token`, and `run` replace the CLI process with Claude in the **current Terminal and working directory**, using the selected account's config directory and a cleared set of conflicting authentication/provider settings. A Console profile's `run` (API key or Console sign-in) keeps `claudock` running as Claude's parent instead, so it can [count the credit](#track-the-console-credit). Additional Claude arguments go after `--` and are forwarded as literal arguments without shell evaluation. The configured Claude executable in Settings applies to both the app and CLI.

`claudock usage` makes one sequential quota request for each supported profile and prints tab-separated profile, usage-window, used-percentage, and reset-time columns. It prints no emails or credentials and exits unsuccessfully if a requested profile fails. Console API-key and Console-login profiles have no subscription limits and get no request: with a [credit set](#track-the-console-credit) they print a row of the same shape, `console  Console API  Credit · $187.42 of $200.00 left  6.29  -`, and without one a note on stderr that names `profile set-credit` (for a Console-login profile, with its Console organization). This reports subscription allowance and Console credit; use Overview for local token activity. `claudock shell status`, `enable`, and `disable` expose the same optional integration controls. If the app moves, enable integration again from the app's new location to update its executable path.

Without shell integration, all GUI features work and the CLI can still be invoked by its absolute path:

```sh
'/Applications/Claudock.app/Contents/MacOS/claudock' profile list
```

Automatic integration refuses a symlinked `.zshrc` or a detected custom `ZDOTDIR` so it does not modify the wrong startup file. For a dotfile manager or custom shell layout, keep integration off and add this function to your own shell configuration, adjusting the app path to its actual location:

```zsh
function claudock() {
  command '/Applications/Claudock.app/Contents/MacOS/claudock' "$@"
}
```

This minimal manual setup provides only `claudock`. Use `claudock run NAME`, or define your own shortcuts through your dotfile manager.

## Console API keys

A Console API-key profile runs Claude Code with a Claude Console API key instead of a subscription login. Use one to keep working when a subscription reaches its limit. API usage is billed per token by the Console, not by a subscription, and is charged to the key's Console organization.

**Add one.** In **Manage profiles**, choose **Console API key**, enter a profile name, paste the key, and choose **Add profile**. In Terminal, the key is read from standard input, never from command arguments:

```sh
claudock profile add console --api-key              # prompts without showing the key
pbpaste | claudock profile add console --api-key    # or pipe it in
```

Paste the raw key (`sk-ant-api03-…`, `sk-ant-usr-…`, or any other `sk-ant-` key from the Console) or its `export ANTHROPIC_API_KEY=…` line; the input is parsed as data and never executed. A few `sk-ant-` credentials are not API keys and are rejected: subscription OAuth tokens (`sk-ant-oat01-…`) and refresh tokens (`sk-ant-ort01-…`) and Admin API keys (`sk-ant-admin01-…`), because they cannot be used as `ANTHROPIC_API_KEY`, and Claude session credentials (`sk-ant-sid01-…`, `sk-ant-si-…`, `sk-ant-cc-…`, `sk-ant-ccsr-…`), which are not Console API keys. Create an API key in the Claude Console instead. `--directory ABS_PATH` imports an existing config folder, as for other profiles. The key is saved in Keychain before the profile appears; if saving fails, no profile is created.

**Use it.** `claudock run console`, the `claude-console` shortcut, **Open in Terminal**, and **Continue as…** work as they do for subscription profiles. For that launch only, Claudock clears inherited authentication and provider variables, sets `ANTHROPIC_API_KEY` from Keychain, and keeps the profile's config folder; it never adds an inference token. New profiles share session history, so `claudock run console -- --resume` continues a conversation started under a subscription.

The first interactive launch asks whether to use the API key; choose **Yes**. Claude Code saves the answer in the profile's own config folder, so later launches do not ask again. Non-interactive `-p` runs use the key directly.

**Replace it** with **Replace API key…** in **Manage profiles**, or `claudock profile set-key console`. **Re-login** is not offered for these profiles, and `claudock profile login` refuses them unless you [switch to a Console sign-in](#sign-in-to-a-console-account-instead) with `--console`. The dashboard shows an **API** badge and, once a credit is set, a **Credit** meter instead of limit bars; **Highest usage first** lists these profiles after subscription accounts.

### Sign in to a Console account instead

Claude Code can sign in to an Anthropic Console account itself (`claude auth login --console`, "Use Anthropic Console (API usage billing)"). It then creates an API key for that account and keeps it in Keychain, so there is no key to create, copy, or paste. A Console-login profile uses that sign-in. In **Manage profiles**, choose **Console account (sign in)**, enter a name, and choose **Add profile**; the Console sign-in opens in Terminal and your browser. In Terminal:

```sh
claudock profile add team --console     # adds the profile, then signs it in through the browser
claudock run team
```

`--directory ABS_PATH` imports an existing config folder, as for other profiles. If the sign-in is cancelled or fails, the profile stays; sign it in later with `claudock profile login team`, or **Sign in…** on its row in **Manage profiles**.

**Which to choose.** Sign in when you can open the Console account in a browser on this Mac: Claude Code creates, stores, and uses the key itself, and the dashboard names the account's organization, such as **Console login · Example LLC**. Paste a key when someone gave you one, when the profile must use one particular key, or when you cannot sign in here. Either way usage is billed per token, the [Console credit](#track-the-console-credit) is tracked the same way, and the profile shares your session history. Usage is charged to the Console organization of the sign-in, not to a subscription.

**Use it.** `claudock run team`, the `claude-team` shortcut, **Open in Terminal**, and **Continue as…** start Claude Code with the profile's own sign-in. Claudock clears inherited authentication and provider variables and passes no key or token. If the profile is not signed in, for example after a cancelled sign-in, the launch stops before Claude starts: `team is not signed in to a Console account. Sign in with: claudock profile login team`.

**Switch between them.** `claudock profile login console --console` signs an API-key profile in to its Console account. Once Claude Code finishes and has saved its key, the profile becomes a Console-login profile; if you cancel or the sign-in fails, it keeps using its pasted key. The pasted key stays in Keychain, unused, and the command prints its service name and the `security delete-generic-password` command that deletes it. `claudock profile set-key team` goes the other way: it saves a pasted key and switches the profile to it, and Claude Code's sign-in stays in Keychain until you use it again with `claudock profile login team --console`. A subscription profile does not switch; add a separate profile for the Console account.

The dashboard shows a Console-login profile like an API-key profile, with an **API** badge, its organization, and a **Credit** meter once a credit is set.

Inference tokens do not apply: `profile setup-token` and `profile set-token` refuse Console-login profiles, and **Require inference token to launch** does not block them. **Remove** keeps Claude Code's sign-in in Keychain, in its `Claude Code-…` item, and the CLI prints that item's name.

### Track the Console credit

Anthropic offers no API for the prepaid credit left on a Console organization, so you enter it yourself. Look up the remaining credit in the Claude Console, then choose **Set credit…** on the profile's dashboard row (or in **Manage profiles**), or run:

```sh
claudock profile set-credit console 187.42
```

The amount is in US dollars, from 0 to 1,000,000, with at most two decimals. Claudock records it with the current time; spend from before that no longer counts. From then on the dashboard row shows a meter of what has been spent, **$187.42 left of $200.00**, and **since** the date you set it, and `claudock usage` prints the same as a row. Below 10% of the credit or below $5 left, the row turns red, shows **LOW CREDIT**, and counts toward the number beside the menu bar icon.

This works the same for API-key and Console-login profiles. Claudock subtracts what Claude Code itself reports for every request in sessions that Claudock starts on this Mac: `claudock run`, the profile's shortcut, **Open in Terminal**, and **Continue as…**. For these launches `claudock` stays running as Claude's parent with a small receiver on `127.0.0.1`, and Claude Code sends it the cost of each request through its OpenTelemetry log export, about once a second: the same figures Claude Code adds up as its own session cost. Each one is saved as it arrives. Ctrl-C, Ctrl-Z, `fg`, and the exit status behave as before. To stop such a run from a script, send SIGTERM, which Claudock passes on, or signal the whole process group: SIGINT or SIGQUIT sent to `claudock`'s process ID alone is ignored, and if `claudock` is killed with SIGKILL, Claude keeps running and the rest of its spend is not counted.

This is an estimate, and the Console balance is authoritative. Use of the same key elsewhere, on other Macs, in scripts, or in other tools, is not seen; neither are Claude Code sessions started without Claudock. Set the credit again from the Console whenever you check it. A few things can make the estimate low: Claude Code runs that are killed outright (`kill -9`) lose the requests of their last second, and settings that change Claude Code's telemetry (an `env` entry for `OTEL_…` or `CLAUDE_CODE_ENABLE_TELEMETRY` in the profile's or project's settings, or managed settings) can send its reports elsewhere; Claudock names such a setting before it starts Claude. When an interactive session ends normally, Claudock also compares Claude Code's own session total in the profile's `.claude.json` and adds any difference.

For these launches Claudock replaces any `OTEL_*` variables in your environment, so your own OpenTelemetry collector does not receive them.

**Remove it** like any profile. Removal keeps the key in Keychain, as Claudock keeps other credentials, and the CLI prints the item's service name. To delete the key, use that name:

```sh
security delete-generic-password -s 'Claudock-apikey-…'
```

The key stays valid in the Console until you revoke it there.

Claudock versions before Console API-key support cannot open a profile registry that contains an API-key or Console-login profile, and versions before Console-login support cannot open one that contains a Console-login profile; they report it as invalid rather than turning the profile into a subscription profile. Remove those profiles before going back to such a version.

## Privacy and permissions

The app reads each profile's existing Claude OAuth credentials from the corresponding macOS Keychain item, with Claude's `.credentials.json` fallback only when that item is absent. Access tokens are sent to `https://api.anthropic.com/api/oauth/usage`. When an access token expires or that endpoint returns HTTP 401, Claudock uses the saved refresh token at `https://platform.claude.com/v1/oauth/token` and updates the same existing credential store. Both HTTP clients reject redirects and use ephemeral sessions without cookies or caches.

Console API keys live in their own Keychain items, named `Claudock-apikey-` followed by a hash. Claudock reads one only to launch its profile and passes it to Claude Code through that process's environment; it never sends the key anywhere itself. For a Console-login profile, Claude Code keeps its own key in its `Claude Code-…` item: Claudock only checks that the item exists, from its attributes, and never reads it. It reads the Console organization's name from the profile's `.claude.json` to show it.

For a Console API-key or Console-login launch, Claudock turns on Claude Code's OpenTelemetry log export and points it at a receiver inside `claudock`, on `127.0.0.1` at a random port and path; the reports never leave the Mac. Claudock keeps only each request's cost, model, session ID, and time, in `~/Library/Application Support/Claudock/api-credit.json` (readable only by you), never keys, prompts, or responses.

There is no analytics service, telemetry, or developer-operated backend. Automatic renewal coordinates with Claude Code's credential locks, preserves unrelated fields, and stores replacement refresh tokens returned by Anthropic. It does not renew on quota HTTP 403, 429, or network failures. When the refresh token is missing, expired, or rejected, re-login delegates to Claude Code in Terminal through a temporary local command file that deletes itself when it runs. macOS may request Keychain access. Profile configuration contains local paths and names; keep it out of public issues and repositories. See [SECURITY.md](../SECURITY.md) for reporting guidance.

## Troubleshooting

| Message or symptom | What to do |
| --- | --- |
| Profile is missing | Rescan shell profiles, or import its config folder in Manage profiles. Shell import needs a `claude-NAME` wrapper with a literal path. |
| Config directory cannot be resolved | Replace a computed path with a literal `CLAUDE_CONFIG_DIR`, or import the profile. |
| This login cannot be renewed | Choose Re-login, finish Claude Code authentication in Terminal, then refresh. |
| Credential update is busy | Retry after a minute or open the profile in Claude Code. Claudock does not steal existing or stale lock directories. |
| Another profile update is in progress | Another Claudock process held the profile registry for more than five seconds, for example while adding a profile. Try again. Parallel launches share the registry and do not cause this. |
| Could not update saved credentials | Unlock Keychain and retry. Claudock retains a successful renewal in memory while retrying its save; closing the app loses that unsaved result. |
| The last renewal could not be confirmed | Open the profile in Claude Code or re-login. Claudock will use the updated credential; it will not resend a potentially consumed refresh token. |
| This credential cannot read usage | Check the account and credential permissions in Claude Code. This error does not trigger token renewal. |
| Keychain access unavailable | Unlock the Mac, respond to any Keychain access prompt, then retry. |
| HTTP 429 / cooldown | Wait for the displayed retry time. Repeated refreshes will not bypass it. |
| Unrecognized usage response | The upstream endpoint may have changed. Report the app version and message; do not attach credentials or raw responses. |
| `claudock` is unavailable | Enable **Manage profiles → Enable claudock in zsh**, then open a new Terminal tab. If the app moved, enable integration again from its new location. |
| Profile exists in the app, but `claude-work5` is not defined | Confirm integration is enabled. After upgrading, launch the new app and open a new tab or run `source ~/.config/claudock/init.zsh` once. Then try `claude-work5`; `claudock run work5` also works. |
| A shortcut runs my original wrapper or executable | Existing commands take priority. Use `claudock run NAME` to select the Claudock profile explicitly. |
| Token totals look larger than expected | Totals include cache reads/writes and count context reused on separate requests. They are not unique tokens, billed cost, or quota. |
| Partial history | The bounded local scan skipped data. Select 7 days for a smaller window; totals remain a partial view. |
| Tokens appear under Shared history | New profiles share the default Claude history. Profiles with the same resolved `projects` folder contribute one set of logs; account attribution is unavailable. |
| Continue as… is unavailable | The saved log has no usable project path. A project folder must exist to continue there. |
| Claude rejects a resume file | Confirm your Claude version supports absolute JSONL paths with `--resume`; the app's compatibility check used 2.1.263. |
| No Console API key is saved | Save one with **Replace API key…** in Manage profiles or `claudock profile set-key NAME`. |
| NAME is not signed in to a Console account | The Console sign-in was cancelled, failed, or was removed. Sign in with `claudock profile login NAME` or **Sign in…** in Manage profiles. |
| `The Console sign-in did not finish; NAME still uses its Console API key` | Nothing changed. Run `claudock profile login NAME --console` again and finish the sign-in in the browser. |
| Claude asks whether to use an API key | Choose Yes. Claude Code remembers the answer for that profile. |
| The credit left differs from the Console | The estimate counts only Claude Code sessions Claudock starts on this Mac. Set the credit again from the Console balance: `claudock profile set-credit NAME AMOUNT` or **Set credit…**. |
| `… sets OTEL_… for Claude Code, which can send its usage events elsewhere` | A settings file gives Claude Code its own telemetry settings, which override Claudock's. Remove that `env` entry for API-key profiles, or set the credit again later. |
| `usage events from this run could not be saved` | The credit ledger was busy or unreadable. Set the credit again from the Console balance. |
| NAME's saved inference token belongs to a different account than its current Claude login | The profile was signed in to another account after its token was saved. Run `claudock profile login NAME` with the token's account, or make a new token: `claudock profile setup-token NAME`, then `pbpaste \| claudock profile set-token NAME`. |
| Launch at login needs approval | Check System Settings → General → Login Items & Extensions. |

## Development and builds

```sh
xcrun swift test
python3 Tests/CLIIntegration/check.py
./scripts/build-app.sh
open 'dist/Claudock.app'
```

`build-app.sh` accepts an output directory and refuses to overwrite an existing `Claudock.app`. It builds both `ClaudockApp` and `claudock`, stages them inside the app under `.build/`, generates an AppKit vector icon, validates the plist, signs the bundled CLI before signing the app, and verifies both signatures. The package uses Swift tools 6.0 and Swift 5 language mode. The GitHub Actions workflow tests and packages on macOS 15 and retains an app ZIP as a build artifact. CI does not publish releases.

Build and prepare releases outside cloud-synced folders. Some file providers attach Finder metadata to `.app` bundles after a build, causing a later signature check to fail even when packaging passed. The build removes disallowed metadata from its new bundle before signing and checks the final path, but cannot prevent subsequent changes by other software. Apple's [code-signing guidance](https://developer.apple.com/library/archive/qa/qa1940/_index.html) explains this error.

The build targets the machine's architecture. Build on Apple Silicon for arm64 and on Intel for x86_64; the current script does not produce a universal binary. Intel support has not been verified. A passing build on one architecture is not verification on the other. See [CONTRIBUTING.md](../CONTRIBUTING.md), [docs/ARCHITECTURE.md](ARCHITECTURE.md), and the [release checklist](RELEASING.md).

### Synthetic preview

Use demo mode to explore the interface or capture screenshots with synthetic data:

```sh
'dist/Claudock.app/Contents/MacOS/ClaudockApp' --demo
```

Demo mode opens an ordinary dashboard window with a **DEMO** indicator. It skips real account discovery, credential access, local-history scanning, and usage network requests. Profile changes, sign-in, and session continuation are disabled. Appearance preferences still use the app's local settings. Quit the preview and open the app normally to monitor your accounts from the menu bar.

### Read-only local analytics diagnostics

To print local token categories and scan coverage without opening the UI, reading credentials, or requesting live quota:

```sh
'dist/Claudock.app/Contents/MacOS/ClaudockApp' --analytics
```

For a fixed upper timestamp, use `--through` with an ISO 8601 value. This example captures the current UTC time before scanning:

```sh
SCAN_CUTOFF=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
'dist/Claudock.app/Contents/MacOS/ClaudockApp' --analytics --through "$SCAN_CUTOFF"
```

The diagnostic uses the current seven-calendar-day window; `--through` changes its upper cutoff, not the start date. It prints totals, input/output/cache counters, per-profile or shared-history totals, scanned/eligible files, bytes, and a partial flag. It does not modify logs or freeze files being written by Claude. Output can reveal profile names and activity; redact it before sharing.

For a distributable release, use your own Apple Developer ID Application identity:

```sh
CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./scripts/build-app.sh dist/signed
ditto -c -k --sequesterRsrc --keepParent 'dist/signed/Claudock.app' dist/Claudock-submission.zip
xcrun notarytool submit dist/Claudock-submission.zip --keychain-profile ClaudockNotary --wait
xcrun stapler staple 'dist/signed/Claudock.app'
xcrun stapler validate 'dist/signed/Claudock.app'
spctl --assess --type execute --verbose=2 'dist/signed/Claudock.app'
ditto -c -k --sequesterRsrc --keepParent 'dist/signed/Claudock.app' dist/Claudock-release.zip
```

These commands assume you have configured a `ClaudockNotary` Keychain profile with Apple's `notarytool store-credentials`. Signing enables the hardened runtime. Check that notarization reports **Accepted** before stapling or distributing. The Claudock migration intentionally retains the previous `io.github.claudeusage.ClaudeUsage` bundle identifier to preserve preferences and login-item identity. A new fork should choose its own identifier before its first release and keep GUI/CLI preference domains consistent. No signing credentials or notarization service setup are included in this repository.

## License

[MIT](../LICENSE). Claude and Claude Code are trademarks of their respective owner.

Automatic token renewal runs in the resident menu bar app. The one-shot `claudock usage` command reads quota without rotating credentials; an expired-token message directs you to Claudock or the relevant Claude profile.

## Long-lived inference tokens

Open **Manage profiles → Set token…** (or **Manage token…** for an existing token). **Paste token** is selected by default. Paste a raw `sk-ant-oat01-…` token or its `export CLAUDE_CODE_OAUTH_TOKEN=…` assignment and choose **Save to Keychain**. The input is parsed as data, never executed. Import does not require a browser or a prior normal Claude login.

Pasted tokens are assigned manually to the selected profile. Their provider account identity cannot be verified from the opaque value; expiry is shown as unknown unless supplied. Use the matching account's token when pairing it with a quota-monitoring login.

The **Create in browser** option remains available for new tokens. It opens Claude authorization and accepts the returned `code#state` in its own field. That flow verifies account/organization against the profile's existing login and uses the expiry reported by Claude, requesting one year by default.

From Terminal, `claudock profile set-token NAME` saves a token the same way. It reads the token from standard input, with a prompt that hides input at a terminal or from piped input, and never from command arguments. Add `--expires ISO8601_DATE` when you know the expiry. To create a token for a profile, run Claude Code's own `setup-token` command under it. It signs in through your browser, so make sure the browser is signed in to the matching claude.ai account:

```sh
claudock profile setup-token work
pbpaste | claudock profile set-token work
claudock profile tokens
```

`claudock profile setup-token work` takes no other arguments and never reads the saved token, so it works whatever that token's state. `claudock run work -- setup-token` also works while `setup-token` is the first Claude argument; if a shell function of yours puts flags before it, use `profile setup-token`.

`claudock profile tokens` lists each profile's token status and expiry in UTC, never the token: `none`, `active`, `expired`, `pasted-unverified`, `n/a` for Console API-key, Console-login, and unresolved profiles, or `unavailable` when Keychain cannot be read. A last line on stderr shows whether tokens are required. When a pasted token has expired, `claudock run` stops and tells you to make a new one with `profile setup-token`.

A saved token remembers the account the profile was signed in to when it was saved. If the login later moves to another account, `claudock run` and the app's launches stop and say so (with the requirement below on, they report an invalid token instead): sign in again with the token's account (`claudock profile login work`), or make a new token as above.

Without a token, or after a browser-created token expires, a launch uses the profile's normal Claude Code login. To rule that out, turn on **Require inference token to launch** in Settings, or run `claudock require-token on`. Then `claudock run`, managed shortcuts, **Open in Terminal**, and **Continue as…** stop with instructions whenever a subscription profile's token is missing, expired, or unreadable. `claudock profile login`, `claudock profile setup-token`, and `claudock run NAME -- setup-token` always work, even after a saved token expires or belongs to another account, so you can create a replacement, and Console API-key and Console-login profiles keep using their key or sign-in. The setting is off by default; `claudock require-token status` prints `on` or `off`.

Saved tokens are preferred by GUI launches, managed shortcuts, and `claudock run`. They survive renames. Imported user-authored wrappers retain their previous authentication; use the copied Claudock command for those profiles. Removing a profile preserves token data and does not revoke it remotely.

Quota monitoring still uses normal OAuth. A monitoring re-login warning does not mean an independently saved inference token has expired. Revoked or expired tokens need replacement; an unknown expiry is not a promise of unlimited validity.

## Account plan badges

Claudock reads `subscriptionType` and `rateLimitTier`, using the mappings verified in Claude Code 2.1.270. Max 5×, Max 20×, and Team Premium display distinct badges. Missing or unrecognized Max/Team subtypes remain **tier unknown**. A lower quota or an unfamiliar Team rate is not enough evidence to call a seat Standard.
