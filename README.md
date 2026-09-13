<img src="docs/assets/icon.png" width="80" height="80" alt="Claudock app icon">

# Claudock

**Your Claude accounts, one menu bar.** Track Fable limits, manage profiles, and explore local token activity.

[Download preview](https://github.com/luisleo526/claudock/releases/download/v1.4.0/Claudock-1.4.0-macOS-arm64.dmg) · [User guide](docs/GUIDE.md)

> **v1.4.0 preview** for **Apple Silicon**, **macOS 14+**. Ad-hoc signed and **not Apple-notarized**. No Xcode needed to run the app.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/accounts.png">
  <img src="docs/screenshots/accounts-light.png" width="620" alt="Claudock account view with large Fable usage bars, reset countdowns, and smaller session and weekly limits">
</picture>

*All screenshots show synthetic demo profiles. Percentages show allowance used.*

## Get started

1. Open the downloaded DMG and drag **Claudock.app** to **Applications**.
2. Open Claudock from Applications. If macOS blocks this preview, follow [Apple's instructions for opening an unnotarized app](https://support.apple.com/en-us/102445). After attempting to open it, the approval is under **System Settings → Privacy & Security → Open Anyway**.
3. Click the menu bar icon. Import your existing profiles, or open **Manage profiles** to add an account and sign in.

[Claude Code](https://code.claude.com/docs/en/setup) is needed for sign-in and Terminal actions. Existing `claude-work` and `claude-personal` wrappers can be imported without executing your shell startup files.

Click elsewhere to dismiss the popover. Open the regular dashboard window when you want more room; closing it leaves the menu bar app running.

Also available: [ZIP archive](https://github.com/luisleo526/claudock/releases/download/v1.4.0/Claudock-1.4.0-macOS-arm64.zip) and [SHA256 checksums](https://github.com/luisleo526/claudock/releases/download/v1.4.0/Claudock-1.4.0-SHA256SUMS.txt). See the [release notes](https://github.com/luisleo526/claudock/releases/tag/v1.4.0).

<details>
<summary>Build from source</summary>

Building requires **full Xcode 16 or newer**. Open Xcode once to finish setup, then run:

```sh
git clone https://github.com/luisleo526/claudock.git
cd claudock
./scripts/bootstrap.sh
```

You can also double-click **Bootstrap.command** in the source folder. Bootstrap checks the toolchain, runs tests, builds Claudock, and opens it. Quit the app, move it from `dist/Build.*/` to Applications, then reopen it.

The build targets your Mac's architecture. Apple Silicon is validated; Intel remains unverified. [Development guide](CONTRIBUTING.md) · [Build and release details](docs/RELEASING.md)

</details>

## Check Fable first

Fable gets the main progress bar, a readable percentage, and its reset time. Session and overall weekly limits sit underneath.

When several Fable limits are reported, the most used one leads. If Claude reports no Fable allowance, Claudock keeps the standard limits visible.

Open the profile you need with **Open in Terminal**, or use **Copy** for its launch command.

## Keep your accounts organized

Add, import, rename, re-login, and remove profiles from **Manage profiles**. New profiles keep independent logins while sharing session history, settings, plugins, and skills with your default `~/.claude` setup. Imported folders keep their existing layout and logins.

Renaming preserves account data. Removing a profile keeps its Claude folders, conversations, and credentials.

**Profile management does not edit `.zshrc`.** Terminal integration is a separate option, off by default.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/profiles.png">
  <img src="docs/screenshots/profiles-light.png" width="620" alt="Claudock profile manager with account setup, re-login controls, and optional zsh integration, using synthetic profiles">
</picture>

*Synthetic demo with account actions disabled; setup wording shown predates the shared-history default in 1.4.0.*

## See what your sessions used

Explore 7- or 30-day activity: input, output, cache reads, cache writes, and subagent contributions.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/overview.png">
  <img src="docs/screenshots/overview-light.png" width="620" alt="Claudock token activity dashboard with processed tokens, daily activity, cache reuse, and profile totals">
</picture>

Recorded tokens include reused context. They describe local activity, not billing or subscription allowance. New profiles share history by default. Shared histories are counted once and labeled clearly; they cannot be reliably divided between accounts. The dashboard shows scan coverage and marks incomplete history.

[How local tokens are counted](docs/GUIDE.md#local-token-activity)

## Continue with another profile

In **Sessions**, choose **Continue as…**, select an account, and open a fork of the conversation in a new Terminal.

Your original session keeps running. The new session uses the selected profile's login and settings, with Claude Code's normal project and tool permissions.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/sessions.png">
  <img src="docs/screenshots/sessions-light.png" width="620" alt="Claudock sessions view with project search, a seven-day filter, and Continue as controls for synthetic conversations">
</picture>

Continuation is a **preview feature** that depends on compatible Claude Code JSONL resume support. [Compatibility details](docs/GUIDE.md#continue-a-saved-session).

## Keep logins fresh

The resident app automatically renews eligible expired logins using each profile's saved refresh token. When renewal needs your attention, the account row explains what to do.

macOS may ask for Keychain access. If a renewal cannot be confirmed, open that profile in Claude Code or re-login. Claudock avoids resending a refresh token that may already have been consumed. [Authentication details](docs/GUIDE.md#privacy-and-permissions).

## Terminal, when you want it

In **Manage profiles**, turn on **Enable claudock in zsh**, then open a new Terminal tab:

```sh
claudock profile list
claudock profile add work
claudock profile login work
claude-work
claudock usage
```

Integration adds the `claudock` command and missing shortcuts such as `claude-work`. Your existing aliases, functions, and executables keep their names. `claudock run work` remains available as the explicit form.

**If shell integration was already enabled:** open the updated Claudock app, then open a new Terminal tab or run this once in each existing tab:

```zsh
source ~/.config/claudock/init.zsh
```

Once the new integration is loaded, profiles added in the GUI become available before your next command, including in an idle Terminal tab. Renames and removals update only shortcuts still owned by Claudock. Profile changes never rewrite `.zshrc`, and the GUI works without shell integration.

Automatic renewal runs in the resident app. The one-shot `claudock usage` command reads quota without rotating credentials.

[Shell setup, custom dotfiles, and command reference](docs/GUIDE.md#optional-shell-integration)

## Local by design

- **No Claudock account or hosted backend.** Profiles live on your Mac.
- **No telemetry or transcript uploads from the monitor.** Local activity is read locally.
- **Existing Claude authentication.** Credentials are used to request limits and renew eligible logins through Anthropic, then saved to the existing credential store.

Starting or continuing Claude is an explicit action and uses Claude's normal settings, authentication, and permissions. [Privacy and security details](SECURITY.md).

Claudock is an independent open-source project, unaffiliated with Anthropic. Live subscription limits use Claude's undocumented OAuth usage endpoint. Availability and response formats can change without notice; this app cannot guarantee continuous access.

## Help shape Claudock

[Report a bug](https://github.com/luisleo526/claudock/issues) with what you clicked, what you expected, and your macOS and Claude Code versions. Please use demo screenshots or redact account details. Report security issues through the [private reporting guidance](SECURITY.md).

Contributions to accessibility, profile discovery, and compatibility are welcome. The app uses **SwiftUI and AppKit**, with **no third-party Swift package dependencies**.

Read the [contribution guide](CONTRIBUTING.md), [architecture](docs/ARCHITECTURE.md), and [troubleshooting notes](docs/GUIDE.md#troubleshooting).

## License

[MIT](LICENSE). Claude and Claude Code are trademarks of their respective owner.
