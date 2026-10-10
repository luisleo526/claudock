#!/usr/bin/env python3
"""Exercise the production CLI without accessing real profiles, shell files, or APIs.

Builds the exact CLI, Profile, and LaunchCommand sources with synthetic I/O
boundaries, then checks the real execve process handoff. Also runs every
`claudock` command in README.md's shell code blocks against the same synthetic
build, so the README cannot document a command the parser rejects. Requires
macOS + Xcode.
"""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile


PROJECT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).resolve().parent
README = PROJECT / "README.md"
# The usage lines of `claudock help` are syntax, such as `claudock profile add NAME [--directory ABS_PATH]`. The README's
# command list repeats them, and every form a line stands for runs with these synthetic values in place of its
# placeholders. Any other README command runs exactly as written.
PLACEHOLDERS = {"NAME": "smoke", "NEWNAME": "renamed", "ABS_PATH": "/synthetic/readme-check", "AMOUNT": "187.42",
                "ISO8601_DATE": "2031-01-01", "SECONDS": "60", "CLAUDE_ARGS...": "--resume"}
SHELL_LANGUAGES = {"sh", "bash", "zsh", "shell", "console"}
SHELL_OPERATORS = {"|", "||", "&", "&&", ";", "<", ">", ">>"}


def fenced_lines(text):
    """(line number, language, line) for every line inside a fenced code block: ``` or ~~~, closed by a fence of the
    same kind that is at least as long."""
    fence = language = None
    for number, line in enumerate(text.splitlines(), 1):
        marker = re.match(r"\s*(`{3,}|~{3,})\s*(.*)$", line)
        if fence is None:
            if marker:
                fence, language = marker.group(1), marker.group(2).split(" ")[0]
        elif marker and marker.group(1)[0] == fence[0] and len(marker.group(1)) >= len(fence) and not marker.group(2):
            fence = None
        else:
            yield number, language, line


def readme_commands(text):
    """([(line number, words)], [problems]): each `claudock` command in the README's shell code blocks; output belongs in
    `text` blocks. Comments are dropped. A command may follow a `$ ` prompt, environment assignments, or a shell
    operator, as in `pbpaste | claudock profile set-token work`, and the app's absolute path stands for `claudock`."""
    commands, problems = [], []
    for number, language, line in fenced_lines(text):
        if language not in SHELL_LANGUAGES:
            continue
        try:
            words = shlex.split(line, comments=True)
        except ValueError as error:
            problems.append(f"README.md:{number}: cannot read `{line.strip()}` as shell words ({error})")
            continue
        segment, depth = [], 0
        for word in [*words, None]:
            if word is None or (word in SHELL_OPERATORS and depth == 0):
                while segment and (segment[0] in ("$", "%") or re.fullmatch(r"\w+=\S*", segment[0])):
                    segment = segment[1:]
                if segment and re.fullmatch(r"claudock|/.*/Contents/MacOS/claudock", segment[0]):
                    commands.append((number, ["claudock", *segment[1:]]))
                segment = []
            else:
                # An operator inside `[...]`, as in `[--max-age SECONDS | --fresh]`, belongs to the syntax.
                depth += word.count("[") - word.count("]")
                segment.append(word)
    return commands, problems


def expand_syntax(command):
    """Each command that a usage line stands for: every optional `[...]` part left out and put in, and each
    `on|off|status` choice taken."""
    group = re.search(r"\[([^\[\]]*)\]", command)
    if group:
        return [variant for choice in [""] + [option.strip() for option in group.group(1).split("|")]
                for variant in expand_syntax(command[:group.start()] + choice + command[group.end():])]
    words = command.split()
    for index, word in enumerate(words):
        if re.fullmatch(r"[^|]+(\|[^|]+)+", word):
            return [variant for choice in word.split("|") for variant in expand_syntax(" ".join(words[:index] + [choice] + words[index + 1:]))]
    return [" ".join(words)]


def heading_anchors(text):
    """GitHub's anchor for each heading outside code blocks: link text only, lower case, punctuation dropped, spaces as
    hyphens, and `-1`, `-2` on repeats."""
    fenced = {number for number, _, _ in fenced_lines(text)}
    anchors, seen = set(), {}
    for number, line in enumerate(text.splitlines(), 1):
        heading = re.match(r"#{1,6}\s+(.*?)(\s+#+)?\s*$", line)
        if heading and number not in fenced:
            title = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", heading.group(1))
            anchor = re.sub(r"[^\w\- ]", "", title.lower()).replace(" ", "-")
            anchors.add(anchor if anchor not in seen else f"{anchor}-{seen[anchor]}")
            seen[anchor] = seen.get(anchor, 0) + 1
    return anchors


def exists_exactly(path):
    """Whether `path`, relative to the repository, exists with the letter case of every part. GitHub tells
    `docs/guide.md` from `docs/GUIDE.md`; this Mac's file system usually does not."""
    normal = os.path.normpath(path)
    if normal.startswith("..") or os.path.isabs(normal):
        return False
    current = PROJECT
    for part in Path(normal).parts:
        try:
            if part not in os.listdir(current):
                return False
        except OSError:
            return False
        current = current / part
    return True


def readme_link_problems(text):
    """Relative links and images of the README that point at a missing file or heading, or at a path in the wrong
    letter case. Inline links and `src`, `srcset`, and `href` attributes outside code are read."""
    fenced = {number for number, _, _ in fenced_lines(text)}
    prose = "\n".join(line for number, line in enumerate(text.splitlines(), 1) if number not in fenced)
    prose = re.sub(r"`[^`\n]*`", "", prose)
    targets = re.findall(r"\]\(([^)\s]+)", prose) + re.findall(r'(?:src|srcset|href)="([^"\s]+)', prose)
    problems = []
    for target in sorted(set(targets)):
        if re.match(r"[a-z][a-z0-9+.-]*:", target, re.IGNORECASE):
            continue
        path, _, anchor = target.partition("#")
        if path and not exists_exactly(path):
            problems.append(f"{target}: no such file")
        elif anchor:
            headings = text if not path else (PROJECT / path).read_text() if path.endswith(".md") else None
            if headings is not None and anchor not in heading_anchors(headings):
                problems.append(f"{target}: no such heading")
    return problems


def check(base):
    environment = os.environ.copy()
    home = base / "home"
    home.mkdir()
    environment["HOME"] = str(home)
    if "DEVELOPER_DIR" not in environment and Path("/Applications/Xcode.app/Contents/Developer").is_dir():
        environment["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"

    def compile_swift(arguments):
        result = subprocess.run(["xcrun", "swiftc", *arguments], cwd=base, env=environment, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr)

    sources = [PROJECT / "Sources/ClaudockCLI/ClaudockCLI.swift", PROJECT / "Sources/UsageCore/Profile.swift", PROJECT / "Sources/UsageCore/LaunchCommand.swift",
               PROJECT / "Sources/UsageCore/SubscriptionPlan.swift"]
    compile_swift(["-emit-library", "-emit-module", "-module-name", "UsageCore", "-o", str(base / "libUsageCore.dylib"),
                   str(FIXTURES / "UsageCoreFixture.swift"), str(sources[1]), str(sources[2]), str(sources[3]),
                   str(PROJECT / "Sources/UsageCore/SubscriptionConfiguration.swift"), str(PROJECT / "Sources/UsageCore/APICredit.swift")])
    binary = base / "claudock"
    compile_swift(["-parse-as-library", "-I", str(base), "-L", str(base), "-lUsageCore", "-Xlinker", "-rpath", "-Xlinker", str(base),
                   "-o", str(binary), str(sources[0])])

    launch_source = sources[2].read_text()
    cleared_keys = re.findall(r'"([A-Z_]+)"', launch_source.split("public static func quote")[0])
    fake = base / "fake-claude"
    fake.write_text("#!" + sys.executable + "\n" + '''import json, os, sys
print(json.dumps({"argv": sys.argv[1:], "cwd": os.getcwd(), "env": {
    key: value for key, value in os.environ.items()
    if key in ALLOWED_KEYS
}}))
sys.exit(int(os.environ.get("CLAUDOCK_TEST_EXIT", "0")))
'''.replace("ALLOWED_KEYS", repr(cleared_keys + ["TEST_KEEP"])))
    fake.chmod(0o700)
    marker = base / "store-marker"
    environment["CLAUDOCK_TEST_MARK"] = str(marker)
    environment["CLAUDOCK_TEST_EXECUTABLE"] = str(fake)
    passed = []

    def run(arguments, extra=None, stdin=None):
        return subprocess.run([str(binary), *arguments], cwd=base, env={**environment, **(extra or {})}, stdin=stdin, capture_output=True, text=True, timeout=15)

    notice = "Claudock Auto has been removed. Use 'claudock run PROFILE' to start Claude with a specific profile.\n"
    removal_failures = []
    for arguments in (["auto"], ["auto", "--", "--continue"], ["auto", "--profiles", "a,b", "--", "x"],
                      ["auto", "bad"], ["auto", "--profiles"], ["auto", "--profiles", "a,,b"], ["auto", "--help"]):
        marker.unlink(missing_ok=True)
        result = run(arguments)
        actual = (result.returncode, result.stdout, result.stderr, marker.exists())
        if actual != (2, "", notice, False):
            removal_failures.append(f"{arguments!r}: expected exit 2, empty stdout, exact removal notice, no I/O; got {actual!r}")
        passed.append("removed Auto notice without profile or credential access " + repr(arguments))
    for arguments in ([], ["help"], ["--help"], ["-h"]):
        result = run(arguments)
        if result.returncode != 0 or result.stderr or "auto" in result.stdout.lower():
            removal_failures.append(f"{arguments!r}: help must succeed without Auto; got exit {result.returncode}, stderr {result.stderr!r}, mentions Auto: {'auto' in result.stdout.lower()}")
        passed.append("help omits Auto " + repr(arguments))
    assert not removal_failures, "\n" + "\n".join(removal_failures)

    cases = [([], 0), (["help"], 0), (["--help"], 0), (["version"], 0), (["--version"], 0),
             (["nonsense"], 2), (["run"], 2), (["run", "smoke", "--resume"], 2), (["profile", "add"], 2),
             (["profile", "add", "bad name"], 2), (["profile", "add", "work", "--directory", "relative"], 2),
             (["profile", "add", "default"], 2), (["profile", "add", "a" * 41], 2),
             (["profile", "add", "auto"], 2), (["profile", "rename", "smoke", "AUTO"], 2),
             (["shell", "enable", "extra"], 2), (["shell", "profile-names", "extra"], 2), (["usage", "extra"], 2),
             (["usage", "--max-age"], 2), (["usage", "--max-age", "-1"], 2), (["usage", "--max-age", "86401"], 2),
             (["usage", "--max-age", "1.5"], 2), (["usage", "--max-age", "+5"], 2), (["usage", "--max-age", ""], 2),
             (["usage", "--max-age", "99999999999999999999999"], 2), (["usage", "--fresh", "--max-age", "5"], 2),
             (["usage", "--fresh", "extra"], 2), (["usage", "--fresh", "--fresh"], 2), (["usage", "--max-age", "1", "--max-age", "2"], 2),
             (["profile", "setup-token"], 2), (["profile", "setup-token", "smoke", "extra"], 2),
             (["profile", "setup-token", "smoke", "--expires", "2099-01-01"], 2),
             (["profile", "clear-token"], 2), (["profile", "clear-token", "smoke", "extra"], 2),
             (["profile", "clear-token", "smoke", "--expires", "2099-01-01"], 2), (["profile", "clear-token", "sk-ant-oat01-x"], 2),
             (["profile", "set-credit", "smoke"], 2), (["profile", "set-credit", "smoke", "1.234"], 2),
             (["profile", "set-credit", "smoke", "-5"], 2), (["profile", "set-credit", "smoke", "5", "extra"], 2),
             (["profile", "set-credit", "sk-ant-api03-x", "5"], 2),
             (["profile", "add", "work", "--console", "--api-key"], 2), (["profile", "add", "work", "--api-key", "--console"], 2),
             (["profile", "add", "work", "--console", "--console"], 2), (["profile", "add", "work", "--console=yes"], 2),
             (["profile", "add", "work", "--console", "extra"], 2), (["profile", "login", "smoke", "--console", "extra"], 2),
             (["profile", "login", "smoke", "--claudeai"], 2), (["profile", "login", "--console", "smoke"], 2)]
    for arguments, expected_status in cases:
        marker.unlink(missing_ok=True)
        result = run(arguments)
        assert result.returncode == expected_status, (arguments, result.returncode, result.stderr)
        assert not marker.exists(), (arguments, "unexpected profile store access")
        if arguments in (["version"], ["--version"]):
            assert result.stdout.strip() == "Claudock 1.6.0"
        passed.append("parser " + repr(arguments))

    result = run(["shell", "profile-names"])
    assert result.returncode == 0 and result.stdout == "claudock-profile-names-v1\nclaude-smoke\n"
    passed.append("data-only shell profile names protocol")

    # Synthetic inherited auth/provider values; never inspect or print real values.
    conflicts = dict.fromkeys(cleared_keys, "synthetic-conflict")
    arguments = ["a b", "quote'word", "$(touch SHOULD_NOT_EXIST)", "; echo bad", "--resume", "--model", "demo"]
    result = run(["run", "smoke", "--", *arguments], {**conflicts, "TEST_KEEP": "preserved", "CLAUDOCK_TEST_EXIT": "37"})
    assert result.returncode == 37, result.stderr
    value = json.loads(result.stdout)
    assert value["argv"] == arguments
    assert value["cwd"] == str(base)
    assert value["env"] == {"CLAUDE_CONFIG_DIR": "/synthetic/account space", "TEST_KEEP": "preserved"}, "launch environment isolation failed"
    assert not (base / "SHOULD_NOT_EXIST").exists()
    passed.append("literal argv, cwd, auth cleanup, unrelated env retention, exit 37")

    result = run(["run", "claude"], conflicts)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["env"] == {}, "default profile retained conflicting environment"
    passed.append("default clears config")

    result = run(["profile", "login", "smoke"], conflicts)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["argv"] == ["auth", "login", "--claudeai"]
    passed.append("login argv")
    result = run(["launch-bound", "fixture-stable", "Claude Code-credentials-aabbccdd", "run", "--", "--resume", "fixture.jsonl"], conflicts)
    assert result.returncode == 0 and json.loads(result.stdout)["env"]["CLAUDE_CONFIG_DIR"] == "/synthetic/account space"
    passed.append("GUI launch binds immutable registry identity and credential service")
    result = run(["launch-bound", "fixture-stable", "Claude Code-credentials-12345678", "run", "--"], conflicts)
    assert result.returncode == 2 and not result.stdout
    passed.append("GUI changed profile binding rejected before Claude launch")

    result = run(["run", "smoke"], {**conflicts, "CLAUDOCK_TEST_MINT": "1"})
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["env"] == {"CLAUDE_CONFIG_DIR": "/synthetic/account space", "CLAUDE_CODE_OAUTH_TOKEN": "synthetic-mint-token"}
    passed.append("mint used only through child environment")
    result = run(["profile", "login", "smoke"], {**conflicts, "CLAUDOCK_TEST_MINT": "1"})
    assert "CLAUDE_CODE_OAUTH_TOKEN" not in json.loads(result.stdout)["env"]
    passed.append("relogin is isolated from stored mint")

    # `profile setup-token` is the sign-in path with Claude's setup-token: the profile's own login, never a saved credential.
    setup_hint = ("Sign the browser in to the claude.ai account for smoke first. "
                  "When the token is shown, save it with: pbpaste | claudock profile set-token smoke\n")
    for label, extra in (("a stored mint", {"CLAUDOCK_TEST_MINT": "1"}),
                         ("a required token", {"CLAUDOCK_TEST_REQUIRE_TOKEN": "1", "CLAUDOCK_TEST_MINT": "1"}),
                         ("a saved token of another account", {"CLAUDOCK_TEST_ACCOUNT_MISMATCH": "mismatch"})):
        marker.unlink(missing_ok=True)
        result = run(["profile", "setup-token", "smoke"], {**conflicts, **extra})
        assert result.returncode == 0 and json.loads(result.stdout)["argv"] == ["setup-token"], (label, result.stderr)
        assert json.loads(result.stdout)["env"] == {"CLAUDE_CONFIG_DIR": "/synthetic/account space"}, (label, "setup-token must run on the profile's own login")
        assert result.stderr == setup_hint, (label, result.stderr)
        assert marker.read_text() == "profile store", (label, "setup-token must read only the profile registry")
        passed.append("profile setup-token runs on the profile's own login despite " + label)
    # The Vertex profile resolves, so this fails inside launch's own profile validation, just before it would exec.
    result = run(["profile", "setup-token", "vertex"])
    assert result.returncode == 1 and not result.stdout and "cannot be launched safely" in result.stderr, result.stderr
    assert "Sign the browser in" not in result.stderr, "the hint must wait until Claude is about to run"
    passed.append("profile setup-token prints its hint only when it is about to run Claude")

    # A synthetic inference-token requirement: launches need a token; sign-in and setup-token do not.
    required = {**conflicts, "CLAUDOCK_TEST_REQUIRE_TOKEN": "1"}
    for arguments in (["run", "smoke", "--", "--resume"], ["launch-bound", "fixture-stable", "Claude Code-credentials-aabbccdd", "run", "--", "--resume", "fixture.jsonl"]):
        result = run(arguments, required)
        assert result.returncode == 1 and not result.stdout and "Synthetic token requirement" in result.stderr, (arguments, result.stderr)
    passed.append("required token stops run and app launches before exec")
    result = run(["run", "smoke", "--", "setup-token"], required)
    assert result.returncode == 0 and json.loads(result.stdout)["argv"] == ["setup-token"], result.stderr
    passed.append("setup-token runs without a required token")
    for arguments in (["profile", "login", "smoke"], ["launch-bound", "fixture-stable", "Claude Code-credentials-aabbccdd", "login", "--"]):
        result = run(arguments, required)
        assert result.returncode == 0 and json.loads(result.stdout)["argv"] == ["auth", "login", "--claudeai"], (arguments, result.stderr)
    passed.append("sign-in is exempt from the required token")
    result = run(["run", "smoke"], {**required, "CLAUDOCK_TEST_MINT": "1"})
    assert result.returncode == 0 and json.loads(result.stdout)["env"].get("CLAUDE_CODE_OAUTH_TOKEN") == "synthetic-mint-token"
    passed.append("required token passed only through the child environment")
    result = run(["require-token", "status"], required)
    assert result.returncode == 0 and result.stdout == "on\n"
    result = run(["profile", "tokens"], required)
    assert result.returncode == 0 and result.stderr.endswith("require-token: on\n"), result.stderr
    passed.append("require-token status and the tokens policy line")
    for arguments in (["require-token"], ["require-token", "maybe"], ["require-token", "on", "extra"]):
        marker.unlink(missing_ok=True)
        assert run(arguments).returncode == 2 and not marker.exists(), arguments
    passed.append("require-token argument errors before any I/O")

    # A saved token that belongs to another account stops run and the app's launches with guidance, never sign-in or setup-token.
    mismatch = ("claudock: smoke's saved inference token belongs to a different account than its current Claude login. "
                "Sign in with the token's account: claudock profile login smoke — or make a new token: "
                "claudock profile setup-token smoke, then pbpaste | claudock profile set-token smoke.\n")
    for kind in ("mismatch", "changed"):
        for arguments in (["run", "smoke", "--", "--resume"],
                          ["launch-bound", "fixture-stable", "Claude Code-credentials-aabbccdd", "run", "--", "--resume", "fixture.jsonl"]):
            result = run(arguments, {**conflicts, "CLAUDOCK_TEST_ACCOUNT_MISMATCH": kind})
            assert result.returncode == 1 and not result.stdout and result.stderr == mismatch, (kind, arguments, result.stderr)
    passed.append("a saved token of another account stops run and app launches with guidance")
    # With the requirement on, the policy reports any unreadable token as a missing one, so the guidance does not apply.
    for kind in ("mismatch", "changed"):
        result = run(["run", "smoke", "--", "--resume"], {**required, "CLAUDOCK_TEST_ACCOUNT_MISMATCH": kind})
        assert result.returncode == 1 and not result.stdout and "Synthetic token requirement" in result.stderr, (kind, result.stderr)
    passed.append("a required token that cannot be read is refused as missing")
    for arguments, argv in ((["profile", "login", "smoke"], ["auth", "login", "--claudeai"]),
                            (["run", "smoke", "--", "setup-token"], ["setup-token"])):
        result = run(arguments, {**conflicts, "CLAUDOCK_TEST_ACCOUNT_MISMATCH": "mismatch"})
        assert result.returncode == 0 and json.loads(result.stdout)["argv"] == argv, (arguments, result.stderr)
    passed.append("sign-in and run NAME -- setup-token ignore a saved token of another account")

    # Console-login profiles sign in with --console, and a launch needs Claude Code's own sign-in and injects nothing.
    for arguments in (["profile", "login", "team"], ["profile", "login", "team", "--console"], ["profile", "login", "claude-team", "--console"],
                      ["launch-bound", "fixture-console", "Claude Code-credentials-c0ffee00", "login", "--"]):
        result = run(arguments, {**conflicts, "CLAUDOCK_TEST_MINT": "1"})
        assert result.returncode == 0 and json.loads(result.stdout) == {
            "argv": ["auth", "login", "--console"], "cwd": str(base), "env": {"CLAUDE_CONFIG_DIR": "/synthetic/console team"}}, (arguments, result.stderr)
    passed.append("console-login sign-in runs auth login --console with nothing injected")
    not_signed_in = "claudock: team is not signed in to a Console account. Sign in with: claudock profile login team\n"
    for arguments in (["run", "team", "--", "x"], ["launch-bound", "fixture-console", "Claude Code-credentials-c0ffee00", "run", "--", "x"]):
        marker.unlink(missing_ok=True)
        result = run(arguments, conflicts)
        assert result.returncode == 1 and not result.stdout and result.stderr == not_signed_in, (arguments, result.stderr)
        assert marker.read_text() == "console sign-in", (arguments, "a refused launch must stop at the sign-in check")
    passed.append("console-login launch without Claude Code's sign-in stops before exec")
    for extra in ({}, {"CLAUDOCK_TEST_REQUIRE_TOKEN": "1"}, {"CLAUDOCK_TEST_MINT": "1"}):
        marker.unlink(missing_ok=True)
        result = run(["run", "team", "--", "x"], {**conflicts, **extra, "CLAUDOCK_TEST_CONSOLE_SIGNED_IN": "1"})
        # The synthetic receiver is unavailable, so the CLI says so and execs Claude directly.
        assert result.returncode == 0 and json.loads(result.stdout)["argv"] == ["x"], (extra, result.stderr)
        assert json.loads(result.stdout)["env"] == {"CLAUDE_CONFIG_DIR": "/synthetic/console team"}, (extra, "console-login launch must inject nothing")
        assert "usage receiver" in result.stderr and marker.read_text() == "credit launch", (extra, result.stderr)
    passed.append("signed-in console-login launch goes to the credit launcher and injects no key or token, whatever the token policy")
    marker.unlink(missing_ok=True)
    result = run(["profile", "login", "smoke", "--console"], conflicts)
    assert result.returncode == 1 and not result.stdout and "subscription" in result.stderr, result.stderr
    assert marker.read_text() == "profile store", "a refused --console sign-in must not launch or change anything"
    passed.append("profile login --console refused for subscription profiles")
    for arguments in (["profile", "setup-token", "team"], ["profile", "set-token", "team"], ["profile", "clear-token", "team"]):
        result = run(arguments)
        assert result.returncode == 1 and "Inference tokens are only for" in result.stderr and not result.stdout, (arguments, result.stderr)
    passed.append("inference-token commands refused for console-login profiles")

    # `profile clear-token` reports the token it deleted, exits 1 when none is saved, and refuses Console and
    # unsupported profiles before Keychain is asked.
    marker.unlink(missing_ok=True)
    result = run(["profile", "clear-token", "smoke"], {"CLAUDOCK_TEST_TOKEN_SAVED": "1"})
    assert result.returncode == 0 and not result.stderr, result.stderr
    assert result.stdout == ("Deleted the inference token saved for smoke from Keychain (service Claudock-inference-fixture). "
                             "Claude Code's own login was not touched.\n"
                             "'claudock run smoke' now starts Claude with the profile's normal login.\n"), result.stdout
    assert marker.read_text() == "inference token"
    result = run(["profile", "clear-token", "smoke"], {"CLAUDOCK_TEST_TOKEN_SAVED": "1", "CLAUDOCK_TEST_REQUIRE_TOKEN": "1"})
    assert result.returncode == 0 and result.stdout.endswith(
        "Claudock requires an inference token to launch, so 'claudock run smoke' is refused until you save one: "
        "claudock profile setup-token smoke, then pbpaste | claudock profile set-token smoke.\n"), result.stdout
    passed.append("profile clear-token reports the token it deleted and what a launch does now")
    result = run(["profile", "clear-token", "smoke"])
    assert result.returncode == 1 and not result.stdout, result.stdout
    assert result.stderr == "claudock: No inference token is saved for 'smoke'.\n", result.stderr
    passed.append("profile clear-token exits 1 when no token is saved")
    for name in ("team", "vertex"):
        marker.unlink(missing_ok=True)
        result = run(["profile", "clear-token", name], {"CLAUDOCK_TEST_TOKEN_SAVED": "1"})
        assert result.returncode == 1 and not result.stdout, (name, result.stderr)
        assert marker.read_text() == "profile store", (name, "a refused clear-token must not reach Keychain")
    passed.append("profile clear-token refuses Console and unsupported profiles before Keychain")

    # `profile remove` keeps the success line, lists the Keychain items that exist in a fixed order with their delete
    # commands, then the config folder and the reminder that keys stay valid until revoked.
    removed = "Removed smoke from Claudock. Claude data, credentials, and your own shell commands were preserved.\n"
    reminder = "Keys and tokens stay valid at Anthropic until they are revoked in the Console or on claude.ai.\n"
    result = run(["profile", "remove", "smoke"], {"CLAUDOCK_TEST_LEFTOVERS": "apiKey,inferenceToken,login"})
    assert result.returncode == 0 and not result.stderr, result.stderr
    assert result.stdout == (removed + "Credentials left in Keychain. To delete one, run its command:\n"
                             "  Fixture login\n    security delete-generic-password -s 'Fixture-service-login'\n"
                             "  Fixture inferenceToken\n    security delete-generic-password -s 'Fixture-service-inferenceToken'\n"
                             "  Fixture apiKey\n    security delete-generic-password -s 'Fixture-service-apiKey'\n"
                             "Config folder: '/synthetic/account space'\n" + reminder), result.stdout
    result = run(["profile", "remove", "smoke"], {"CLAUDOCK_TEST_LEFTOVERS": "consoleKey", "CLAUDOCK_TEST_UNCONFIRMED": "1"})
    assert result.returncode == 0 and result.stdout == (
        removed + "Credentials left in Keychain. To delete one, run its command:\n"
        "  Fixture consoleKey (Keychain could not be checked; it may not exist)\n"
        "    security delete-generic-password -s 'Fixture-service-consoleKey'\n"
        "Config folder: '/synthetic/account space'\n" + reminder), result.stdout
    result = run(["profile", "remove", "smoke"])
    assert result.returncode == 0 and result.stdout == removed + "Config folder: '/synthetic/account space'\n" + reminder, result.stdout
    passed.append("profile remove lists only the Keychain items that exist, then the config folder and the revoke reminder")
    result = run(["profile", "remove", "tabbed"])
    assert result.returncode == 0 and result.stdout == (
        "Removed tabbed from Claudock. Claude data, credentials, and your own shell commands were preserved.\n"
        "Config folder: '/synthetic/tab here' (control characters in the name are shown as spaces)\n" + reminder), result.stdout
    passed.append("profile remove shows a config folder with a control character as spaces and says the name is not exact")
    result = run(["profile", "remove", "team"], {"CLAUDOCK_TEST_LEFTOVERS": "consoleKey"})
    assert result.stdout.startswith("Removed team from Claudock. Claude data, its Console sign-in, and your own shell commands were preserved.\n"), result.stdout
    passed.append("profile remove keeps each kind's success line")

    result = run(["run", "vertex"])
    assert result.returncode == 1 and not result.stdout
    passed.append("unsupported Vertex blocked")

    result = run(["run", "default"])
    assert result.returncode == 1 and "More than one" in result.stderr
    passed.append("ambiguous legacy name blocked")

    result = run(["run", "claude-default"], conflicts)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["env"]["CLAUDE_CONFIG_DIR"] == "/synthetic/legacy"
    passed.append("exact command selects legacy default")

    result = run(["run", "測試"], conflicts)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["env"]["CLAUDE_CONFIG_DIR"] == "/synthetic/unicode"
    passed.append("imported Unicode profile can be selected")

    result = run(["profile", "list"])
    assert result.returncode == 0 and "SELECTOR" in result.stdout and "claude-default" in result.stdout
    assert "team\tclaude-team\tconsole-login\t/synthetic/console team\n" in result.stdout, result.stdout
    passed.append("list exact selectors and the console-login kind")

    # Reproduce the real app layout: the running CLI is a secondary executable,
    # while CFBundleExecutable points at the GUI. Integration must call the CLI.
    bundle = base / "Claudock.app" / "Contents"
    executables = bundle / "MacOS"
    executables.mkdir(parents=True)
    packaged_cli = executables / "claudock"
    shutil.copy2(binary, packaged_cli)
    (executables / "ClaudockApp").write_text("GUI fixture, never executed\n")
    (bundle / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": "ClaudockApp", "CFBundleIdentifier": "test.claudock.fixture",
        "CFBundlePackageType": "APPL", "CFBundleName": "Claudock",
    }))
    shell_marker = base / "shell-executable-receipt"
    result = subprocess.run([str(packaged_cli), "shell", "enable"], cwd=base,
                            env={**environment, "CLAUDOCK_TEST_SHELL_MARK": str(shell_marker)}, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    # Foundation and Python spell /var versus /private/var differently on macOS.
    # The selected executable must be the exact CLI file, never the GUI sibling.
    assert os.path.samefile(shell_marker.read_text(), packaged_cli)
    assert Path(shell_marker.read_text()).name == "claudock"
    passed.append("packaged shell enable selects CLI rather than GUI executable")

    result = run(["usage"])
    assert result.returncode == 0 and "25.00" in result.stdout and "skipped" in result.stderr
    assert result.stdout.startswith("PROFILE\tPLAN\tWINDOW\tUSED_PERCENT\tRESETS_UTC\n")
    assert "Max 20×" in result.stdout
    assert ("claudock: team: skipped; Console login · Fixture Org is billed per token and has no subscription limits. "
            "Set its balance with: claudock profile set-credit team AMOUNT\n") in result.stderr, result.stderr
    passed.append("synthetic quota TSV and skipped unsupported, with the Console organization")

    for flags in (["--fresh"], ["--max-age", "0"], ["--max-age", "86400"]):
        flagged = run(["usage", *flags])
        assert flagged.returncode == 0 and flagged.stdout == result.stdout and flagged.stderr == result.stderr, (flags, flagged.stderr)
    passed.append("usage accepts --fresh and --max-age 0 to 86400 with the same output")

    result = run(["usage"], {"CLAUDOCK_TEST_FAIL_USAGE": "1"})
    assert result.returncode == 1 and "Synthetic quota error" in result.stderr and "25.00" not in result.stdout
    passed.append("quota error returns failure without fabricated readings")

    # README.md must keep telling the truth about the CLI. The commands a reader runs are in its shell code blocks: each
    # `claudock` command runs against these synthetic boundaries, with an empty standard input, and the parser must
    # accept it (no argument error). The usage lines of `claudock help` must appear in them, as the cheat sheet does. Inline
    # code in prose and tables is not run. Relative links, images, and headings they point at must exist.
    text = README.read_text()
    help_text = run(["help"]).stdout
    usage_lines = [" ".join(line.split()) for line in help_text.partition("Usage:\n")[2].partition("\n\n")[0].splitlines()
                   if line.strip().startswith("claudock ")]
    assert usage_lines, "claudock help lists no commands"
    commands, problems = readme_commands(text)
    documented, runs = set(), 0
    for number, words in commands:
        line = " ".join(words)
        documented.add(line)
        forms = ([[PLACEHOLDERS.get(word, word) for word in shlex.split(form)[1:]] for form in expand_syntax(line)]
                 if line in usage_lines else [words[1:]])
        for arguments in forms:
            result = run(arguments, stdin=subprocess.DEVNULL)
            runs += 1
            if result.returncode not in (0, 1) or "Run 'claudock help' for usage." in result.stderr:
                problems.append(f"README.md:{number}: `claudock {shlex.join(arguments)}` is rejected by the CLI (exit {result.returncode}): {result.stderr.strip()}")
    problems += [f"README.md: no shell code block has the `claudock help` line `{line}`" for line in usage_lines if line not in documented]
    problems += [f"README.md: link {problem}" for problem in readme_link_problems(text)]
    assert not problems, "\n" + "\n".join(problems)
    passed.append(f"README commands ({runs} runs), the full help usage list, and relative links are valid")

    return {"passed": len(passed), "checks": passed,
            "source_sha256": {str(source.relative_to(PROJECT)): hashlib.sha256(source.read_bytes()).hexdigest() for source in sources},
            "scope": "Production CLI/Profile/LaunchCommand; synthetic profile, executable discovery, credentials, quota, and shell boundaries. Temporary HOME; no real profiles, credentials, shell startup, or network requests."}


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="claudock-cli-integration-") as temporary:
        receipt = check(Path(temporary).resolve())
    print(json.dumps(receipt, indent=2))
