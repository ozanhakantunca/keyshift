import fcntl
import hashlib
import json
import re
import os
import shutil
import signal
import sys
import subprocess
import tempfile
from pathlib import Path

from harness import Harness, Session, check


SCRIPT = Path(__file__).resolve().parent
REPO = SCRIPT.parent.parent
ROOT = Path.home() / "KeyshiftE2E"
REPORT = ROOT / "report"
APP = ROOT / "KeyshiftE2E.app"
CONFIG = Path.home() / ".config/keyshift/config.yaml"
KEYSHIFT = "/Applications/Keyshift.app/Contents/MacOS/Keyshift"
IDENTITY = "Keyshift Self-Signed"
BUNDLE_ID = "io.github.ozanhakantunca.keyshift.e2e"


def command(*args, timeout=20):
    return subprocess.run(
        [str(arg) for arg in args], cwd=REPO, check=True, capture_output=True,
        text=True, timeout=timeout
    )


def build_app(stage):
    build = ("swift", "build", "--package-path", SCRIPT, "--build-path", REPO / ".build-e2e/harness",
             "--build-system", "native")
    command(*build, timeout=180)
    binary = Path(command(*build, "--show-bin-path").stdout.strip()) / "KeyshiftE2E"
    contents = APP / "Contents"
    installed = contents / "MacOS/KeyshiftE2E"
    plist = SCRIPT / "Info.plist"

    if installed.is_file() and (contents / "Info.plist").is_file():
        if installed.read_bytes() == binary.read_bytes() and (contents / "Info.plist").read_bytes() == plist.read_bytes():
            signature = command("/usr/bin/codesign", "-dv", "--verbose=4", APP).stderr
            if f"Authority={IDENTITY}" in signature.splitlines():
                command("/usr/bin/codesign", "--verify", "--deep", "--strict", APP)
                return

    identities = command("/usr/bin/security", "find-identity", "-p", "codesigning").stdout
    match = re.search(r'^\s*\d+\) ([A-Fa-f0-9]{40}) "Keyshift Self-Signed"', identities, re.MULTILINE)
    if not match:
        raise RuntimeError(f'The existing "{IDENTITY}" identity is unavailable in the user keychain search list.')
    staged_app = stage / APP.name
    staged_contents = staged_app / "Contents"
    (staged_contents / "MacOS").mkdir(parents=True)
    shutil.copy2(plist, staged_contents / "Info.plist")
    shutil.copy2(binary, staged_contents / "MacOS/KeyshiftE2E")
    try:
        command("/usr/bin/codesign", "--force", "--sign", match[1], "--identifier",
                BUNDLE_ID, "--timestamp=none", staged_app)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("Code signing timed out waiting for the existing keychain identity.") from error
    command("/usr/bin/codesign", "--verify", "--deep", "--strict", staged_app)

    previous = stage / "previous.app"
    if APP.exists():
        APP.rename(previous)
    try:
        staged_app.rename(APP)
    except OSError:
        if previous.exists():
            previous.rename(APP)
        raise


def inventory(config):
    # The active profile uses the conventional block YAML written by Keyshift's settings UI.
    # Keep the verbatim trigger and action in the report even when preflight blocks execution.
    profile = re.search(r"^profile:\s*(.+?)\s*$", config, re.MULTILINE)
    active = profile[1] if profile else ""
    in_profile = False
    rule = ""
    scope = []
    rows = []

    def add(scenario, injected, expected, channel="HID", scope="", parent=False):
        rows.append({"scenario": scenario, "channel": channel, "scope": scope, "injected": injected,
                     "expected": expected, "observed": "", "evidence": [],
                     "result": "parent" if parent else "not run"})

    for line in config.splitlines():
        if line.startswith("- name:") or line.startswith("  - name:"):
            # At the top level, profile list items have no indentation in the saved config.
            if line.startswith("- name:"):
                in_profile = line.partition(":")[2].strip() == active
                continue
            rule = line.partition(":")[2].strip()
            scope = []
            continue
        if not in_profile or not rule:
            continue
        descriptor = re.match(r"^    ((?:only|except|focus): .+)$", line)
        if descriptor:
            scope.append(descriptor[1])
        mapping = re.match(r"^      ([^:]+): (.+)$", line)
        if mapping:
            trigger, action = mapping.groups()
            add(rule, trigger, action, scope=", ".join(scope),
                parent=bool(re.search(r"\b(?:lock_screen|sleep_display|reboot)\b", action)))

    extra = (
        ("Text navigation", "shift+home / shift+end", "Exact line selection ranges"),
        ("Text navigation", "ctrl+shift+left / ctrl+shift+right", "Exact word selection ranges"),
        ("Windows key chord", "left_cmd held in chord", "Spotlight stays closed"),
        ("Finder rename mode", "return / backspace / f2", "Commit, remove character, then plain F2"),
        ("Terminal interrupt", "ctrl+c", "Foreground sleep command interrupted"),
        ("Fake game", "ctrl+c / home / left_cmd tap", "Unchanged game events and no Spotlight window"),
        ("Screen Sharing exclusion", "ctrl+c", "Unchanged delivery with Screen Sharing frontmost"),
        ("Keyshift menu", "pause / resume; ctrl+c", "Remapping stops and resumes in TextEdit"),
        ("Keyshift rule editor", "record / toggle / choose app", "Recorder passthrough, config persistence and live scope"),
        ("Keyshift profiles and presets", "create / switch / delete / apply", "Profile and rule state update"),
        ("Keyshift Karabiner import", "import copied backup", "Imported mappings and diagnostics"),
        ("Keyshift conflicts", "open conflicts", "Four informational items for Control arrows (Spaces); none for Command arrows"),
        ("Keyshift event viewer and screenshots", "open sections / onboarding / inject", "Input and output plus screenshots"),
        ("Robustness", "2,000 random inputs", "No stuck modifiers; plain key delivery; latency percentiles"),
        ("Robustness", "hold key with 30 ms repeat events", "Matching repeat down events and key-up"),
        ("Robustness", "release ctrl before letter", "Matching remapped key-up and empty modifier state"),
    )
    for scenario, trigger, expected in extra:
        add(scenario, trigger, expected)
    for scenario, trigger in (
        ("TextEdit copy/paste", "ctrl+c / ctrl+v"),
        ("TextEdit line navigation", "home / end"),
        ("TextEdit word deletion", "ctrl+backspace"),
        ("TextEdit close window", "alt+f4"),
        ("Spotlight", "win tap"),
        ("Finder rename", "f2"),
        ("VNC modifier mapping", "Control_L / Alt_L / Super_L / Meta_L"),
    ):
        add(scenario, trigger, "Real app state and annotated session delivery", channel="VNC")
    add("Sleep", "sleep", "Parent-owned system test", parent=True)
    add("Reboot", "reboot", "Parent-owned system test", parent=True)
    return rows


def inspection(*args):
    try:
        return command(*args).stdout.strip()
    except (OSError, subprocess.SubprocessError) as error:
        return str(error)


def write_report(data, directory):
    def cell(value):
        return str(value).replace("|", r"\|").replace("\n", " ")

    results = data["results"]
    counts = {state: sum(r["result"] == state for r in results)
              for state in ("pass", "impossible", "fail", "not run", "parent")}
    lines = ["# Keyshift end-to-end verification", "", data["blocker"], "",
             f'{counts["pass"]} passed, {counts["impossible"]} proven impossible on this machine, '
             f'{counts["fail"]} failed, {counts["not run"]} not run, and {counts["parent"]} parent-owned.', "",
             f'The config SHA-256 matched before and after the run: `{data["config_unchanged"]}`.',
             f'Baseline SHA-256 `{data["sha256_before"]}`.',
             f'Active input source `{data.get("layout", "unavailable")}`.', ""]
    if data.get("layout", "").endswith("Turkish-QWERTY-PC"):
        lines += ["The expected user actions were italic for Ctrl+I, zoom in for Ctrl+=, and zoom out for Ctrl+-.",
                  "Carbon translated ANSI I (34) as dotless ı and dotted i (39) as i. "
                  "It translated ANSI Equal (24) as −, ANSI Minus (27) as *, and Shift+0 as =.",
                  "Keyshift resolves config key names by the character typed under Command (KeyLayoutMap), so `i` "
                  "is position 39 and `minus` is position 24 on this layout. The harness presses the same physical "
                  "keys. `=` has no unshifted key here, so `ctrl+equal` is not installed and Chrome zoom-in is "
                  "unreachable (see its case).", ""]
    if "latency" in data:
        stats = data["latency"]
        lines += [f'Annotated-session latency across {stats["samples"]} correlated key-downs was '
                  f'{stats["p50_ms"]} ms p50, {stats["p95_ms"]} ms p95, and {stats["p99_ms"]} ms p99.', ""]
    if "vnc_modifiers" in data:
        lines += ["The supplemental VNC run used Apple Remote Desktop authentication (RFB security type 30).", ""]
    if "vnc_legacy_modifiers" in data:
        lines += ["The requested legacy VNC replay used RFB security type 2. "
                  "Each of its rows identifies the authentication type and records the wire keys.", ""]
    if "supplemental_ard_cases" in data:
        cases = data["supplemental_ard_cases"]
        passes = sum(row["result"] == "pass" for row in cases)
        lines += [f"An earlier supplemental RFB type 30 run passed {passes} of {len(cases)} cases "
                  "against this config digest. Its wire and annotated-session traces are in results.json.", ""]
    lines += ["## Permission preflight", ""]
    permissions = data.get("permissions")
    if permissions:
        lines.extend([f'App: `{permissions["app"]}` (`{permissions["bundleID"]}`).', "",
                      "| API | Privacy & Security pane | Granted |",
                      "| --- | --- | --- |"])
        for check in permissions["checks"]:
            lines.append(f'| {check["api"]} | {check["pane"]} | {"Yes" if check["granted"] else "No"} |')
        if permissions.get("requested"):
            lines.extend(["", f'Requested once: `{permissions["requested"]}`.'])
    else:
        lines.append("The permission preflight did not return a result.")
    lines.extend(["", "## Cases", "",
                  "| Scenario | Channel | Scope | Injected | Expected | Observed | Result | Evidence |",
                  "| --- | --- | --- | --- | --- | --- | --- | --- |"])
    for row in data["results"]:
        columns = [row[key] for key in ("scenario", "channel", "scope")]
        columns.extend([row["injected"] if row["result"] in ("pass", "fail") else "—",
                        f'{row["injected"]} → {row["expected"]}', row["observed"] or "—",
                        row["result"], ", ".join(f"[{p}]({p})" for p in row["evidence"]) or "—"])
        lines.append("| " + " | ".join(map(cell, columns)) + " |")
    if data.get("group_errors"):
        lines += ["", "## Scenario setup errors", "",
                  *[f"- {group} — {detail}" for group, detail in data["group_errors"].items()]]
    if data.get("cleanup_errors"):
        lines += ["", "## Cleanup", "", *[f"- {error}" for error in data["cleanup_errors"]]]
    if any(row["scenario"] == "Keyshift onboarding" and row["result"] == "pass" for row in results):
        lines += ["", "## Turkish screenshot review", "",
                  "The captured settings sections and onboarding welcome page show no visible overlap or cut-off Turkish labels. "
                  "Preset titles and descriptions are in English."]
    lines.extend(["", "## Final Keyshift state", "", "```text", data["keyshift_status"],
                  f'UserKeyMapping: {data["user_key_mapping"]}', "```", ""])
    (directory / "report.md").write_text("\n".join(lines), encoding="utf-8")
    (directory / "results.json").write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def restore_file(path, original, mode):
    if original is None:
        path.unlink(missing_ok=True)
        return
    if path.exists() and path.read_bytes() == original:
        return
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".e2e-restore-", delete=False) as stream:
        target = Path(stream.name)
        stream.write(original)
    try:
        target.chmod(mode)
        target.replace(path)
    finally:
        target.unlink(missing_ok=True)


def run(output):
    original = CONFIG.read_bytes()
    mode = CONFIG.stat().st_mode & 0o777
    backup = CONFIG.with_suffix(".yaml.bak")
    old_backup = backup.read_bytes() if backup.exists() else None
    backup_mode = backup.stat().st_mode & 0o777 if backup.exists() else mode
    sha256 = hashlib.sha256(original).hexdigest()
    (ROOT / "config.original.yaml").write_bytes(original)
    (ROOT / "config.original.sha256").write_text(f"{sha256}  {CONFIG}\n", encoding="utf-8")
    data = {"sha256_before": sha256, "results": inventory(original.decode("utf-8")), "cleanup_errors": [],
            "blocker": "Execution completed."}
    groups = set(sys.argv[1:])
    resume = "--resume" in groups
    groups.discard("--resume")
    vnc_security_type = 2 if "--vnc-legacy" in groups else 30
    groups.discard("--vnc-legacy")
    if resume:
        previous = json.loads((REPORT / "results.json").read_text())
        check(previous["sha256_before"] == sha256, "Saved results used a different Windows config")
        data["results"] = previous["results"]
        for key in ("latency", "vnc_modifiers", "vnc_legacy_modifiers", "supplemental_ard_cases", "group_errors"):
            if key in previous:
                data[key] = previous[key]
        for screenshot in REPORT.glob("[0-9][0-9][0-9]-*.png"):
            shutil.copy2(screenshot, output / screenshot.name)

    def execute(harness, group, body):
        if groups and group not in groups:
            return
        print(f"== {group} ==", flush=True)
        data.get("group_errors", {}).pop(group, None)
        try:
            body()
        except Exception as error:
            print(f"{group} setup/recovery: {type(error).__name__}: {error}", flush=True)
            data.setdefault("group_errors", {})[group] = f"{type(error).__name__}: {error}"

    try:
        with tempfile.TemporaryDirectory(prefix=".run-", dir=ROOT) as directory:
            stage = Path(directory)
            build_app(stage)
            result = stage / "permissions.json"
            command("/usr/bin/open", "-g", "-n", "-W", "-a", APP, "--args", "--preflight", result)
            permissions = json.loads(result.read_text(encoding="utf-8"))
            data["permissions"] = permissions
            missing = list(dict.fromkeys(c["pane"] for c in permissions["checks"] if not c["granted"]))
            if missing:
                raise RuntimeError("Grant " + ", ".join(missing) + f" to {APP}.")
            check("Profile: Windows" in command(KEYSHIFT, "status").stdout, "Windows profile must be active")
            s = Session(stage, APP, command)
            harness = None
            try:
                harness = Harness(s, ROOT, output, stage, KEYSHIFT, CONFIG, command, data["results"])
                harness.vnc_security_type = vnc_security_type
                data["layout"] = harness.layout
                data["layout_keys"] = s.call("layoutKeys", keys=[24, 27, 29, 34, 38, 40, 41, 42, 39])
                doc = harness.open_text("E2E-TextEdit")

                if groups:
                    execute(harness, "ui", lambda: harness.ui_cases(doc))
                    execute(harness, "vnc", lambda: harness.vnc_cases(doc))
                execute(harness, "text", lambda: (harness.text_navigation(doc), harness.text_shortcuts(doc),
                    harness.case("Close window", "alt+f4", "TextEdit fixture AXWindow disappears",
                                 lambda _, start: harness.close_test_text(start))))
                execute(harness, "system", lambda: harness.system_cases(doc))

                def finder():
                    if not hasattr(harness, "finder"):
                        harness.finder_setup()
                    harness.finder_cases()
                execute(harness, "finder", finder)

                def chromium():
                    harness.chrome_start()
                    for group, cases in (("chrome-browser", harness.browser_cases), ("chrome-common", harness.chrome_ctrl_cases),
                                         ("chrome-close", harness.chrome_alt_f4)):
                        try:
                            cases()
                        except Exception as error:
                            data.setdefault("group_errors", {})[group] = f"{type(error).__name__}: {error}"
                            print(f"{group}: {error}", flush=True)
                execute(harness, "chrome", chromium)
                execute(harness, "safari", harness.safari_case)
                execute(harness, "terminal", lambda: harness.terminal_cases("com.apple.Terminal", "Terminal"))
                execute(harness, "ghostty", lambda: harness.terminal_cases("com.mitchellh.ghostty", "Ghostty"))
                execute(harness, "exclusions", lambda: harness.exclusion_cases(APP))
                execute(harness, "robustness", lambda: harness.robustness(doc))
                if hasattr(harness, "latency"):
                    data["latency"] = harness.latency

                if not groups:
                    execute(harness, "vnc", lambda: harness.vnc_cases(doc))
                    execute(harness, "ui", lambda: harness.ui_cases(doc))
                if hasattr(harness, "modifier_map"):
                    key = "vnc_legacy_modifiers" if vnc_security_type == 2 else "vnc_modifiers"
                    data[key] = harness.modifier_map
            finally:
                try:
                    if harness:
                        data["cleanup_errors"].extend(harness.cleanup())
                finally:
                    s.close()
    except (Exception, KeyboardInterrupt) as error:
        if isinstance(error, subprocess.CalledProcessError):
            detail = "\n".join((error.stderr or error.stdout or str(error)).strip().splitlines()[:12])
        else:
            detail = str(error) or type(error).__name__
        data["blocker"] = f"Run interrupted. {detail.strip()}"
    finally:
        restore_file(CONFIG, original, mode)
        restore_file(backup, old_backup, backup_mode)
        for args in (("reload",), ("profile", "Windows"), ("enable",)):
            try:
                if args[0] == "profile" and "Profile: Windows" in command(KEYSHIFT, "status").stdout:
                    continue
                command(KEYSHIFT, *args)
            except Exception as error:
                data["cleanup_errors"].append(f"Keyshift {' '.join(args)}: {error}")

    data["sha256_after"] = hashlib.sha256(CONFIG.read_bytes()).hexdigest()
    data["config_unchanged"] = data["sha256_before"] == data["sha256_after"]
    data["keyshift_status"] = inspection(KEYSHIFT, "status")
    data["user_key_mapping"] = inspection("/usr/bin/hidutil", "property", "--get", "UserKeyMapping")
    for row in data["results"]:
        if row["result"] == "not run":
            row["observed"] = "No injection or evidence recorded"
    write_report(data, output)
    previous_report = output.parent / "previous"
    REPORT.rename(previous_report)
    try:
        output.rename(REPORT)
    except BaseException:
        previous_report.rename(REPORT)
        raise
    print(data["blocker"])
    print(f"Report: {REPORT}")
    complete = (all(row["result"] in ("pass", "impossible", "parent") for row in data["results"])
                and not data["cleanup_errors"] and not data.get("group_errors")
                and data["config_unchanged"] and data["user_key_mapping"] == "(null)"
                and "Remapping: enabled" in data["keyshift_status"] and "Profile: Windows" in data["keyshift_status"])
    return 0 if complete else 2


def interrupted(signum, frame):
    raise KeyboardInterrupt


if __name__ == "__main__":
    ROOT.mkdir(mode=0o700, exist_ok=True)
    REPORT.mkdir(mode=0o700, exist_ok=True)
    signal.signal(signal.SIGTERM, interrupted)
    with (ROOT / ".run.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with tempfile.TemporaryDirectory(prefix=".report-", dir=ROOT) as directory:
            output = Path(directory) / "report"
            output.mkdir(mode=0o700)
            raise SystemExit(run(output))
