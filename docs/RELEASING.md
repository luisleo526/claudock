# Release checklist

Use this checklist for a versioned source or macOS app release. The project provides source, tests, packaging scripts, and CI build artifacts; those alone do not establish a production audit, a notarized distribution, or a working upstream endpoint.

## Prepare an immutable candidate

- Set the app version and build number in `scripts/build-app.sh`, and keep the request User-Agent/version text consistent where applicable.
- Preserve `io.github.claudeusage.ClaudeUsage` for this project's Claudock migration so existing preferences and login-item identity survive. A separately branded fork must choose its own identifier and update the shared GUI/CLI preference domain before its first release.
- Record the candidate commit, macOS version, Xcode/Swift version, and build architecture. Keep release notes and screenshots free of account identities, paths, transcripts, and credentials.
- Review changes to discovery, credential isolation, shell mutations, session continuation, and packaging against that exact candidate. If code changes after review, repeat the affected review and checks.

## Reproduce tests and packaging

On macOS 14 or newer with full Xcode 16 or newer, run:

```sh
xcrun swift --version
xcrun swift test
python3 Tests/CLIIntegration/check.py
./scripts/build-app.sh dist/release-check
codesign --verify --strict --verbose=2 'dist/release-check/Claudock.app/Contents/MacOS/claudock'
codesign --verify --strict --verbose=2 'dist/release-check/Claudock.app'
lipo -archs 'dist/release-check/Claudock.app/Contents/MacOS/ClaudockApp'
'dist/release-check/Claudock.app/Contents/MacOS/claudock' --help
'dist/release-check/Claudock.app/Contents/MacOS/claudock' version
```

Use a fresh output directory; the packaging script refuses to replace an existing app. For a custom Xcode installation, set `DEVELOPER_DIR` to its `Contents/Developer` directory. The package has no third-party Swift dependencies. This is a reproducible procedure, not a claim of byte-identical binaries across different toolchains or signing times.

The bundle includes the MIT license. Before signing, the build removes debug-map symbols with `strip -S` so release executables do not expose local object-file paths. Executable code sections, Swift runtime metadata, and exported symbols remain present.

Use a checkout/output location outside cloud-synced folders for release preparation. A file provider can attach `com.apple.FinderInfo` after signing and invalidate the bundle's resource checks. The build strips only disallowed FinderInfo/resource-fork attributes on its newly created bundle and verifies the final path; external software can still change it afterward. Diagnose this with Apple's [QA1940](https://developer.apple.com/library/archive/qa/qa1940/_index.html), and verify the extracted artifact again before distribution.

The `macOS` workflow runs tests and packaging on `macos-15`, then creates an application ZIP with `ditto` and uploads it as an artifact. Require a successful run for the exact release candidate. The workflow does not create tags, publish GitHub releases, or use release signing credentials. Its ad-hoc artifact is a development build and omits extended attributes; release archives below preserve macOS metadata after notarization.

## Check the packaged application

- Launch the actual `.app` and check onboarding, the menu bar popover, outside-click dismissal, Settings, and readable light/dark layouts. Open the ordinary dashboard from the window icon/context menu and check resize, minimize, close, and reopening.
- With temporary synthetic profiles, exercise registry add/import, rename, and removal; confirm stable config directories and preserved credentials/history. Confirm CRUD leaves `.zshrc` unchanged and the CLI and GUI see the same registry. Exercise legacy migration while comparing all old shell/registry bytes.
- Separately enable/disable shell integration in a temporary home; confirm exact backups, the marked block, preserved unrelated shell code, and no shadowing of existing `claude`/`claude-NAME` commands. Check the bundled `claudock` function in a new zsh session.
- Check CLI help and malformed commands cause no profile or credential reads. Use an isolated stub executable to verify literal argument forwarding, current working directory, cleared provider/auth environment, signals, and exit status before any live launch. Check per-account quota failure exits without exposing identities or credentials.
- Check Overview's 7-/30-day selection, processed versus input/output totals, main/direct/workflow-subagent coverage, global deduplication, isolated versus shared-history attribution, and scanned/eligible-file counts. Exercise empty/error states and the partial-history label. Keep local recorded tokens distinct from subscription allowance and billing.
- Check Sessions search, target selection, missing-project handling, and the generated resume/fork command. If claiming live cross-account continuation, separately complete it with consenting test accounts and verify the target identity, forked conversation, and intact source.
- Check live usage with a signed-in test profile before claiming current service compatibility. The undocumented endpoint can change independently of the source release. Record only sanitized results.
- Check launch-at-login from the app's final installation location if the release claims it. A unit-test pass is not a check of Keychain access, Terminal launch, authentication, login items, or GUI behavior.

Use the executable's `--demo` option to open an ordinary dashboard for public screenshots and synthetic layout checks. Confirm the DEMO indicator is visible and profile mutations and continuation remain disabled. Demo checks do not replace normal-mode popover behavior, authentication, service compatibility, or real-session verification. Use `--analytics --through` for read-only local accounting comparisons when needed; keep any real diagnostic output out of the public repository.

Intel support has not been verified. Build and run these checks on Intel before distributing an x86_64 artifact as supported. The script builds the current architecture and does not produce a universal binary. A CI host checks only the architecture it actually reports.

## Sign and notarize public app distributions

Use a Developer ID Application certificate belonging to the maintainer. Set `CODE_SIGN_IDENTITY` when packaging; the script enables hardened runtime and timestamping for that identity. The default `-` identity is ad hoc and is unsuitable as a claim of trusted public distribution.

```sh
CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./scripts/build-app.sh dist/signed
ditto -c -k --sequesterRsrc --keepParent 'dist/signed/Claudock.app' dist/Claudock-submission.zip
xcrun notarytool submit dist/Claudock-submission.zip --keychain-profile ClaudockNotary --wait
```

Configure the `ClaudockNotary` Keychain profile with your own Apple credentials beforehand; do not put credentials in the repository, CI artifacts, or release notes. Continue only after the notarization result is **Accepted**:

```sh
xcrun stapler staple 'dist/signed/Claudock.app'
xcrun stapler validate 'dist/signed/Claudock.app'
codesign --verify --strict --verbose=2 'dist/signed/Claudock.app'
spctl --assess --type execute --verbose=2 'dist/signed/Claudock.app'
ditto -c -k --sequesterRsrc --keepParent 'dist/signed/Claudock.app' dist/Claudock-release.zip
shasum -a 256 dist/Claudock-release.zip
```

Repackage after stapling so the release ZIP contains the ticket. Verify the extracted release artifact on a separate Mac or clean test user, including a normal Gatekeeper launch. Publish the final checksum, supported macOS versions/architectures, app version, and concise known limitations with the release. Publishing remains a maintainer action; no script in this repository publishes automatically.
