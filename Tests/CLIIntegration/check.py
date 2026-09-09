#!/usr/bin/env python3
"""Exercise the production CLI without accessing real profiles, shell files, or APIs.

Builds the exact CLI, Profile, and LaunchCommand sources with synthetic I/O
boundaries, then checks the real execve process handoff. Requires macOS + Xcode.
"""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile


PROJECT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).resolve().parent


def check(base):
    environment = os.environ.copy()
    if "DEVELOPER_DIR" not in environment and Path("/Applications/Xcode.app/Contents/Developer").is_dir():
        environment["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"

    def compile_swift(arguments):
        result = subprocess.run(["xcrun", "swiftc", *arguments], cwd=base, env=environment, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr)

    sources = [PROJECT / "Sources/ClaudockCLI/main.swift", PROJECT / "Sources/UsageCore/Profile.swift", PROJECT / "Sources/UsageCore/LaunchCommand.swift"]
    compile_swift(["-emit-library", "-emit-module", "-module-name", "UsageCore", "-o", str(base / "libUsageCore.dylib"),
                   str(FIXTURES / "UsageCoreFixture.swift"), str(sources[1]), str(sources[2])])
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

    def run(arguments, extra=None):
        return subprocess.run([str(binary), *arguments], cwd=base, env={**environment, **(extra or {})}, capture_output=True, text=True)

    cases = [([], 0), (["help"], 0), (["--help"], 0), (["version"], 0), (["--version"], 0),
             (["nonsense"], 2), (["run"], 2), (["run", "smoke", "--resume"], 2), (["profile", "add"], 2),
             (["profile", "add", "bad name"], 2), (["profile", "add", "work", "--directory", "relative"], 2),
             (["profile", "add", "default"], 2), (["profile", "add", "a" * 41], 2),
             (["shell", "enable", "extra"], 2), (["usage", "extra"], 2)]
    for arguments, expected_status in cases:
        marker.unlink(missing_ok=True)
        result = run(arguments)
        assert result.returncode == expected_status, (arguments, result.returncode, result.stderr)
        assert not marker.exists(), (arguments, "unexpected profile store access")
        if arguments in (["version"], ["--version"]):
            assert result.stdout.strip() == "Claudock 1.3.1"
        passed.append("parser " + repr(arguments))

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
    passed.append("list exact selectors")

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
    assert shell_marker.read_text() == str(packaged_cli.resolve())
    passed.append("packaged shell enable selects CLI rather than GUI executable")

    result = run(["usage"])
    assert result.returncode == 0 and "25.00" in result.stdout and "skipped" in result.stderr
    passed.append("synthetic quota TSV and skipped unsupported")

    result = run(["usage"], {"CLAUDOCK_TEST_FAIL_USAGE": "1"})
    assert result.returncode == 1 and "Synthetic quota error" in result.stderr and "25.00" not in result.stdout
    passed.append("quota error returns failure without fabricated readings")

    return {"passed": len(passed), "checks": passed,
            "source_sha256": {str(source.relative_to(PROJECT)): hashlib.sha256(source.read_bytes()).hexdigest() for source in sources},
            "scope": "Production CLI/Profile/LaunchCommand; synthetic profile, executable discovery, credentials, quota, and shell boundaries. No live credentials, shell startup, HOME override, or network requests."}


if __name__ == "__main__":
    build = PROJECT / ".build"
    build.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="cli-integration-", dir=build) as temporary:
        receipt = check(Path(temporary).resolve())
    print(json.dumps(receipt, indent=2))
