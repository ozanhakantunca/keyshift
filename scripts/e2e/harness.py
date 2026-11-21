import contextlib
import json
import os
import random
import re
import shutil
import signal
import subprocess
import time
from pathlib import Path

from vnc import RFB


KEYS = dict(zip("asdfhgzxcvbqwertyuiopljknm", (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 37, 38, 40, 45, 46)))
KEYS.update(dict(zip("1234567890", (18, 19, 20, 21, 23, 22, 26, 28, 25, 29))))
KEYS.update(equal=24, minus=27, right_bracket=30, left_bracket=33, return_=36, tab=48, space=49,
            backspace=51, escape=53, right_cmd=54, left_cmd=55, shift=56, alt=58, ctrl=59, fn=63,
            keypad_enter=76, f2=120, f4=118, f5=96, f13=105, f17=64, f18=79,
            home=115, end=119, delete=117, left=123, right=124, down=125, up=126)
KEYS["return"] = KEYS["return_"]
BRIGHTNESS_KEYS = (120, 122)
MODS = {"cmd": 1 << 20, "ctrl": 1 << 18, "alt": 1 << 19, "shift": 1 << 17, "fn": 1 << 23}
MODKEYS = {"cmd": 55, "right_cmd": 54, "ctrl": 59, "shift": 56, "alt": 58, "fn": 63}
MOD_MASK = sum(v for k, v in MODS.items() if k != "fn")
POSITIONS = dict(KEYS)  # US ANSI positions; KEYS is rewritten for the active layout by adapt_layout()
CHARACTERS = {**{name: name for name in "asdfhgzxcvbqwertyuiopljknm1234567890"},
              "equal": "=", "minus": "-", "right_bracket": "]", "left_bracket": "["}
UNAVAILABLE = {}
TILE_TOLERANCE = 4
LAYOUT_ROWS = []


class Impossible(Exception):
    """The scenario cannot be exercised on this machine; the message is the concrete, verified reason."""


def adapt_layout(rows):
    """Point named character keys at the physical key that types the same character under Command.

    Mirrors KeyLayoutMap.make in Keyshift: a config name such as `i` means the key labelled I. On
    Turkish-PC that is ANSI position 39 (34 types dotless i), and `-` is position 24 (27 types `*`).
    Characters with no unshifted key whose own position now types another shortcut character are
    recorded in UNAVAILABLE with the character that position types instead."""
    LAYOUT_ROWS[:] = rows
    current = {row["key"]: row["cmd"].lower() for row in rows}
    owner = {}
    for code in sorted(current):
        owner.setdefault(current[code], code)
    pending = {}
    for name, character in CHARACTERS.items():
        code = POSITIONS[name]
        if current.get(code) == character:
            KEYS[name] = code
        elif character in owner:
            KEYS[name] = owner[character]
        else:
            pending[name] = code
    claimed = {KEYS[name] for name in CHARACTERS if name not in pending}
    for name, code in pending.items():
        if code in claimed:
            UNAVAILABLE[name] = f"position {code} types {current.get(code)!r} under Command"
        else:
            KEYS[name] = code


TEXTEDIT = "com.apple.TextEdit"
FINDER = "com.apple.finder"
CHROME = "com.google.Chrome"
SAFARI = "com.apple.Safari"
TERMINAL = "com.apple.Terminal"
GHOSTTY = "com.mitchellh.ghostty"
KEYSHIFT_ID = "io.github.ozanhakantunca.keyshift"
SPOTLIGHT = "com.apple.Spotlight"


def steps(combo, *, repeat=0, early=False, delay=12, implicit_fn=True):
    parts = combo.split("+")
    modifiers, key = parts[:-1], parts[-1]
    if key in UNAVAILABLE:
        raise Impossible(f"No key types {CHARACTERS[key]!r} under Command on this layout ({UNAVAILABLE[key]})")
    key = KEYS[key]
    result = []

    def add(code, down, repeated=False):
        step = {"key": code, "down": down, "repeat": repeated}
        if code in BRIGHTNESS_KEYS or not implicit_fn:
            # Quartz flags F-keys with fn, but the HID system turns fn+F1/F2 into the brightness system keys
            # and never delivers the key event. A physical F1/F2 press in standard F-key mode carries no fn flag.
            step["implicitFn"] = False
        result.append(step)
        if delay:
            result.append({"ms": 30 if repeated else delay})

    for modifier in modifiers:
        add(MODKEYS[modifier], True)
    add(key, True)
    for _ in range(repeat):
        add(key, True, repeated=True)
    if not early:
        add(key, False)
    for modifier in reversed(modifiers):
        add(MODKEYS[modifier], False)
    if early:
        add(key, False)
    return result


def flatten(node):
    yield node
    for child in node.get("children", []):
        yield from flatten(child)


def label(node):
    return " ".join(str(node.get(k, "")) for k in ("AXTitle", "AXDescription", "AXValue", "AXIdentifier")).strip()


def check(condition, detail):
    if not condition:
        raise AssertionError(detail)
    return detail


def wait(probe, description, timeout=4):
    until = time.monotonic() + timeout
    previous = None
    while True:
        try:
            previous = probe()
            if previous:
                return previous
        except (RuntimeError, KeyError, IndexError) as error:
            previous = str(error)
        if time.monotonic() >= until:
            raise AssertionError(f"Timed out waiting for {description}; last result {str(previous)[:300]}")
        time.sleep(0.055)


class Session:
    def __init__(self, stage, app, command):
        self.directory = stage / "session"
        self.directory.mkdir()
        self.command = command
        command("/usr/bin/open", "-g", "-n", "-a", app, "--args", "--serve", self.directory)
        ready = self.directory / "ready.json"
        wait(ready.exists, "signed helper and annotated-session tap", timeout=8)
        self.pid = json.loads(ready.read_text())["pid"]
        self.call("pasteboard", save=True)

    def call(self, op, **kwargs):
        response = self.directory / "response.json"
        response.unlink(missing_ok=True)
        staged = self.directory / "request.tmp"
        staged.write_text(json.dumps({"op": op, **kwargs}))
        staged.replace(self.directory / "request.json")
        wait(response.exists, f"signed helper operation {op}", timeout=16)
        result = json.loads(response.read_text())
        if "error" in result:
            raise RuntimeError(result["error"])
        return result["value"]

    def close(self):
        self.call("stop")

    def ax(self, pid=None, *, handle=None, target=None, depth=0, limit=220, full=False):
        return self.call("ax", pid=pid, handle=handle, target=target, depth=depth, limit=limit, full=full)

    def set(self, node, attribute, value):
        self.call("set", handle=node["handle"], attribute=attribute, value=value)

    def action(self, node, name="AXPress"):
        self.call("action", handle=node["handle"], name=name)

    def apps(self, identifier):
        return [x for x in self.call("apps") if x["id"] == identifier]

    def front(self):
        return self.call("front")

    def activate(self, pid):
        if self.front().get("pid") != pid:
            self.call("activate", pid=pid)
            wait(lambda: self.front().get("pid") == pid, f"frontmost PID {pid}")

    def windows(self, pid):
        return self.ax(pid).get("AXWindows", [])

    def window(self, pid, target="AXFocusedWindow", depth=0, limit=220):
        return self.ax(pid, target=target, depth=depth, limit=limit)

    def focused(self, pid):
        return self.ax(pid, target="AXFocusedUIElement")

    def inject(self, combo, **kwargs):
        self.call("inject", steps=steps(combo, **kwargs))

    def hotkeys(self):
        return self.call("hotkeys")

    def type(self, text):
        self.call("inject", steps=[{"text": text}], record=False)

    def click(self, node, count=1):
        node = self.ax(handle=node["handle"])
        if "AXPosition" not in node or "AXSize" not in node:
            raise RuntimeError("Element has no frame (stale handle or off-screen)")
        x, y = node["AXPosition"]
        w, h = node["AXSize"]
        self.call("inject", steps=[{"x": x + w / 2, "y": y + h / 2, "count": count}])

    def close_window(self, window):
        tree = self.ax(handle=window["handle"], depth=1)
        button = next((x for x in flatten(tree) if x.get("AXSubrole") == "AXCloseButton"), None)
        if button:
            self.action(button)
        else:
            raise RuntimeError(f"Close button absent in {label(tree)}")


class Harness:
    def __init__(self, session, root, report, stage, keyshift, config, command, rows):
        self.s = session
        self.root = root
        self.report = report
        self.stage = stage
        self.keyshift = keyshift
        self.config = config
        self.cmd = command
        self.rows = rows
        self.channel = "HID"
        self.vnc_security_type = 30
        self.baseline_front = self.s.front().get("pid")
        self.baseline_windows = {}
        self.owned = {}
        self.created_dirs = []
        self.chrome_pid = None
        self.game_pid = None
        self.rfb = None
        self.route = {}
        self.layout = self.s.call("inputSource")
        adapt_layout(self.s.call("layoutKeys", keys=list(range(51))))
        self.screenshots = set()
        self.trash = set()
        self.original_positions = {}

    def remember(self, pid):
        if pid not in self.baseline_windows:
            self.baseline_windows[pid] = {x["handle"] for x in self.s.windows(pid)}

    def adopt(self, pid, window):
        self.owned.setdefault(pid, set()).add(window["handle"])
        return window

    def new_windows(self, pid, before):
        return [x for x in self.s.windows(pid) if x["handle"] not in before]

    def mark(self):
        return self.s.call("mark")

    def seen(self, start):
        return self.s.call("log", start=start)["events"]

    def fire(self, combo, **kwargs):
        if self.channel != "VNC":
            self.s.inject(combo, **kwargs)
        else:
            self.rfb.combo(combo, self.route)

    def expect(self, start, combo, *, repeat=None, on_pid=None):
        parts = combo.split("+")
        code = KEYS[parts[-1]]
        flags = sum(MODS.get(k, 0) for k in parts[:-1])
        result = wait(lambda: [
            e for e in self.seen(start) if e["type"] == 10
            and e["key"] == code and e["flags"] & MOD_MASK == flags
            and (repeat is None or e["repeat"] == repeat)
            and (on_pid is None or e["pid"] in (0, on_pid))
        ], f"annotated-session {combo}", timeout=1.8)
        return result

    def case(self, scenario, injected, expected, test, *, scope="", baseline=None):
        if self.channel == "VNC":
            scope = f"RFB security type {self.vnc_security_type}" + (f"; {scope}" if scope else "")
        identity = f"{self.channel}:{scenario}:{injected}:{scope}"
        row = next((r for r in self.rows if r.get("case_id") == identity), None)
        if row is None:
            row = next((r for r in self.rows if r["scenario"] == scenario and
                        r["injected"] == (baseline or injected) and r["channel"] == self.channel
                        and not r.get("case_id") and r["result"] != "parent" and
                        (r["result"] == "not run" or not scope or not r["scope"] or r["scope"] == scope
                         or scenario not in ("Terminal interrupt", "Terminal clipboard"))), None)
        if row is None:
            row = {"scenario": scenario, "channel": self.channel, "scope": scope, "injected": injected,
                   "expected": expected, "observed": "", "result": "not run", "evidence": []}
            self.rows.append(row)
        else:
            row.setdefault("config_expected", row["expected"])
            row["expected"] = expected
            row["injected"] = injected
            if scope:
                row["scope"] = scope
        row["case_id"] = identity
        number = self.rows.index(row) + 1
        prior = dict(row) if row["result"] == "pass" else None
        if isinstance(test, tuple):
            setup, action = test
        else:
            setup, action = None, test
        start = self.mark()
        post = self.s.call("postMark")
        rfb_start = len(self.rfb.sent) if self.rfb else 0
        setup_completed = False
        try:
            context = setup() if setup else None
            setup_completed = True
            start = self.mark()
            post = self.s.call("postMark")
            row["observed"] = str(action(context, start))
            row["result"] = "pass"
        except Impossible as error:
            row["observed"] = f"Impossible: {error}"
            row["result"] = "impossible"
        except Exception as error:
            row["observed"] = f"{type(error).__name__}: {error}"
            row["result"] = "fail"
            if prior and isinstance(test, tuple) and not setup_completed:
                prior["latest_setup_error"] = row["observed"]
                row.clear()
                row.update(prior)
                print(f"{number:03d} prior pass retained after setup failed: {row['latest_setup_error']}", flush=True)
                return
        try:
            observed = self.s.call("log", start=start, includePosted=True, postStart=post)
            row["delivery"] = observed["events"][-100:]
            row["posted"] = observed["posted"][:80]
            row["posted_count"] = len(observed["posted"])
            if self.channel == "VNC" and self.rfb:
                row["rfb_keys"] = self.rfb.sent[rfb_start:]
                row["rfb_security_type"] = self.rfb.security_type
            path = self.report / f"{number:03d}-{re.sub(r'[^a-z0-9]+', '-', scenario.lower()).strip('-')}.png"
            window = self.capture_window(scenario)
            try:
                self.s.call("capture", path=str(path), window=window)
            except RuntimeError:
                self.s.call("capture", path=str(path))
            check(path.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n", "Invalid screenshot")
            row["evidence"] = [path.name]
        except Exception as error:
            row["observed"] += f"; evidence error: {error}"
            row["result"] = "fail"
        print(f"{number:03d} {row['result']:6s} {self.channel} {scenario} / {injected}: {row['observed'][:240]}",
              flush=True)

    def capture_window(self, scenario):
        if scenario in ("Windows key", "Windows key chord", "Spotlight", "VNC modifier mapping",
                        "Keyshift menu", "Screen Sharing exclusion", "Close window", "TextEdit close window"):
            return None
        pid = self.s.front().get("pid")
        if pid == self.chrome_pid or pid == self.game_pid or self.owned.get(pid):
            window = next((w for w in self.s.call("windows") if w.get("kCGWindowOwnerPID") == pid
                           and w.get("kCGWindowLayer") in (0, 3, 8) and w["kCGWindowBounds"]["Width"] > 150), None)
            return window.get("kCGWindowNumber") if window else None
        return None

    def open_app(self, identifier, name=None):
        apps = self.s.apps(identifier)
        if not apps:
            self.cmd("/usr/bin/open", "-g", "-a", name or identifier)
            apps = wait(lambda: self.s.apps(identifier), identifier)
        return apps[0]["pid"]

    def open_text(self, name, content="alpha beta gamma\none two three\nlast line", *, rich=True):
        path = self.stage / (name + (".rtf" if rich else ".txt"))
        if rich:
            escaped = content.replace("\\", "\\\\").replace("{", "\\{").replace("}", "\\}").replace("\n", "\\line ")
            path.write_text(r"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}\f0\fs28 " + escaped + "}")
        else:
            path.write_text(content)
        apps = self.s.apps(TEXTEDIT)
        if apps:
            self.remember(apps[0]["pid"])
        self.cmd("/usr/bin/open", "-a", "TextEdit", path)
        app = wait(lambda: self.s.apps(TEXTEDIT), "TextEdit")[0]
        pid = app["pid"]
        self.baseline_windows.setdefault(pid, set())
        self.s.activate(pid)
        window = wait(lambda: next((x for x in self.s.windows(pid) if name in x.get("AXTitle", "")), None),
                      f"TextEdit fixture {name}")
        self.adopt(pid, window)
        field = wait(lambda: self.text_field(pid), "TextEdit text area")
        return pid, window, field

    def text_field(self, pid):
        field = self.s.focused(pid)
        if field["AXRole"] == "AXTextArea":
            return field
        return next((x for x in flatten(self.s.window(pid, depth=5)) if x["AXRole"] == "AXTextArea"), None)

    def prepare_text(self, doc, content, caret, length=0):
        pid, window, _ = doc
        if window["handle"] not in {w["handle"] for w in self.s.windows(pid)}:
            name = str(window["AXTitle"]).removesuffix(".rtf")
            doc = self.open_text(name)
            pid, window, _ = doc
        self.s.activate(pid)
        self.s.action(window, "AXRaise")
        field = wait(lambda: self.text_field(pid), "focused TextEdit document")
        if not self.s.ax(handle=field["handle"]).get("AXFocused"):
            try:
                self.s.set(field, "AXFocused", True)
            except RuntimeError:
                self.s.click(field)
        self.s.set(field, "AXValue", content)
        self.s.set(field, "AXSelectedTextRange", [caret, length])
        return pid, window, field

    def state(self, field):
        current = self.s.ax(handle=field["handle"])
        return current.get("AXValue"), current.get("AXSelectedTextRange")

    def wait_text(self, field, text=None, selection=None):
        return wait(lambda: (lambda v: v if (text is None or v[0] == text) and
                   (selection is None or v[1] == selection) else None)(self.state(field)),
                    f"TextEdit value {text!r}, selection {selection}; initial {self.state(field)!r}")

    def dismiss(self, count=1):
        for _ in range(count):
            self.s.inject("escape")

    def close_owned(self, pid, window):
        if window["handle"] not in self.owned.get(pid, set()):
            return
        if window["handle"] not in {x["handle"] for x in self.s.windows(pid)}:
            self.owned[pid].discard(window["handle"])
            return
        if window["handle"] in self.original_positions:
            try:
                self.s.set(window, "AXPosition", self.original_positions.pop(window["handle"]))
            except RuntimeError:
                pass
        self.s.close_window(window)
        until = time.monotonic() + 3
        while time.monotonic() < until:
            if window["handle"] not in {x["handle"] for x in self.s.windows(pid)}:
                self.owned[pid].discard(window["handle"])
                return
            trees = [self.s.ax(handle=window["handle"], depth=8, limit=180)]
            try:
                target = self.s.window(pid, depth=8, limit=180)
                if target["handle"] == window["handle"] or target.get("AXSubrole") in ("AXDialog", "AXSystemDialog"):
                    trees.append(target)
            except RuntimeError:
                pass
            discard = next((x for tree in trees for x in flatten(tree) if x["AXRole"] == "AXButton" and
                            re.search(r"Don.t Save|Discard|Kaydetme|Saklama|Değişiklikleri Sil|Değişikliklerden Vazgeç", label(x), re.I)), None)
            if discard:
                self.press(discard)
            time.sleep(0.04)

    def adopt_after(self, pid, before):
        # Finder lists its desktop as an AXScrollArea described "masaüstü"; it is not a window anyone opened.
        return [self.adopt(pid, x) for x in self.new_windows(pid, before)
                if x.get("AXRole", "AXWindow") == "AXWindow"
                and not re.fullmatch(r"masaüstü|desktop", x.get("AXTitle", ""), re.I)]

    def solid_pair(self, start, combo):
        observed = self.expect(start, combo)
        key = observed[0]["key"]
        flags = observed[0]["flags"] & MOD_MASK
        wait(lambda: any(e["type"] == 11 and e["key"] == key and e["flags"] & MOD_MASK == flags
                         for e in self.seen(start)), f"matching annotated key-up for {combo}")
        return f"annotated key-down/up {combo}"

    def text_navigation(self, doc):
        content = "alpha beta gamma\none two three\nlast line"
        variants = [
            ("home", "cmd+left", 22, [17, 0], content),
            ("end", "cmd+right", 22, [30, 0], content),
            ("shift+home", "cmd+shift+left", 22, [17, 5], content),
            ("shift+end", "cmd+shift+right", 22, [22, 8], content),
            ("ctrl+home", "cmd+up", 22, [0, 0], content),
            ("ctrl+end", "cmd+down", 22, [40, 0], content),
            ("ctrl+left", "alt+left", 23, [21, 0], content),
            ("ctrl+right", "alt+right", 23, [24, 0], content),
            ("ctrl+shift+left", "alt+shift+left", 23, [21, 2], content),
            ("ctrl+shift+right", "alt+shift+right", 23, [23, 1], content),
            ("ctrl+backspace", "alt+backspace", 24, [21, 0], content[:21] + content[24:]),
            ("ctrl+delete", "alt+delete", 21, [21, 0], content[:21] + content[24:]),
        ]
        if self.channel == "VNC":
            variants = [v for v in variants if v[0] in ("home", "end", "ctrl+backspace")]
        for combo, mapped, caret, selection, value in variants:
            scenario = "Text navigation" if self.channel == "HID" else (
                "TextEdit word deletion" if "backspace" in combo else "TextEdit line navigation")
            baseline = {"shift+home": "shift+home / shift+end", "ctrl+shift+left": "ctrl+shift+left / ctrl+shift+right"}.get(combo)
            if self.channel == "VNC":
                baseline = {"home": "home / end", "ctrl+backspace": "ctrl+backspace"}.get(combo)
            def action(ready, start):
                self.fire(combo)
                result = self.wait_text(ready[2], value, selection)
                return f"{self.solid_pair(start, mapped)}; AXValue {result[0]!r}; AXSelectedTextRange {result[1]}"
            self.case(scenario, combo, f"{mapped}; TextEdit UTF-16 selection {selection}; value {value!r}",
                      (lambda: self.prepare_text(doc, content, caret), action), baseline=baseline)

    def system_hotkeys_for(self, combo):
        """Enabled macOS symbolic hotkeys that match a key combo (arrow and F-keys carry fn implicitly)."""
        parts = combo.split("+")
        code = KEYS[parts[-1]]
        flags = sum(MODS.get(k, 0) for k in parts[:-1] if k != "fn")
        return [h for h in self.s.hotkeys()
                if h["key"] == code and h["flags"] & ~MODS["fn"] & ~(1 << 21) == flags]

    def text_shortcuts(self, doc):
        pid, window, _ = doc
        scenario = "Ctrl shortcuts" if self.channel == "HID" else "TextEdit copy/paste"
        shortcuts = "a c v x z s f g n o p t w b i u y".split() if self.channel == "HID" else ["c", "v"]
        for key in shortcuts:
            combo = f"ctrl+{key}"
            mapped = "shift+cmd+z" if key == "y" else f"cmd+{key}"
            if key == "w":
                setup = lambda: self.open_text(f"E2E-close-{time.time_ns()}")
            else:
                def setup():
                    value = "alpha beta alpha"
                    caret = 0
                    length = 5 if key in "cxbiu" else 0
                    ready = self.prepare_text(doc, value, caret, length)
                    if key in "cvx":
                        self.s.call("pasteboard", text="Pasted E2E" if key == "v" else "E2E sentinel")
                    if key in "zys":
                        self.s.call("pasteboard", text="InsertedE2E ")
                        self.s.inject("ctrl+v")
                        self.wait_text(ready[2], "InsertedE2E " + value)
                        if key == "y":
                            self.s.inject("ctrl+z")
                            self.wait_text(ready[2], value)
                    if key == "g":
                        self.s.inject("ctrl+f")
                        self.set_focused_text(pid, "alpha")
                        self.s.inject("return")
                        self.end_text_find(pid)
                        self.s.set(ready[2], "AXSelectedTextRange", [0, 5])
                    return ready
            def action(ready, start):
                target_pid, target_window, field = ready
                previous = {x["handle"] for x in self.s.windows(target_pid)}
                before_traits = self.s.call("traits", handle=field["handle"], length=5) if key in "biu" else None
                self.fire(combo)
                result = self.solid_pair(start, mapped)
                if key == "a":
                    detail = self.wait_text(field, "alpha beta alpha", [0, 16])
                elif key == "c":
                    detail = wait(lambda: self.s.call("pasteboard") == "alpha" and "clipboard contains alpha", "copied alpha")
                elif key == "v":
                    detail = self.wait_text(field, "Pasted E2Ealpha beta alpha", [10, 0])
                elif key == "x":
                    detail = self.wait_text(field, " beta alpha", [0, 0])
                    check(self.s.call("pasteboard") == "alpha", "Cut did not update clipboard")
                elif key in "zy":
                    detail = self.wait_text(field, "InsertedE2E alpha beta alpha" if key == "y" else "alpha beta alpha")
                elif key == "s":
                    saved = self.stage / "E2E-TextEdit.rtf"
                    detail = wait(lambda: b"InsertedE2E" in saved.read_bytes() and "fixture RTF contains InsertedE2E",
                                  "saved fixture contents")
                elif key in "biu":
                    trait = {"b": "bold", "i": "italic", "u": "underline"}[key]
                    detail = wait(lambda: (lambda v: v if v.get(trait) and v != before_traits else None)(
                        self.s.call("traits", handle=field["handle"], length=5)), f"{trait} AX text attribute")
                elif key == "n":
                    created = wait(lambda: self.adopt_after(target_pid, previous), "new TextEdit document")
                    detail = [label(x) for x in created]
                elif key == "w":
                    detail = wait(lambda: target_window["handle"] not in {x["handle"] for x in self.s.windows(target_pid)}
                                  and "fixture window closed", "TextEdit close")
                elif key in "op":
                    pattern = r"^Aç$|^Open$|Yazdır|Print|Yazıcı"
                    detail = wait(lambda: self.dialog(target_pid, pattern) or self.find_in_window(target_pid, pattern),
                                  "TextEdit open/print controls")
                elif key == "f":
                    detail = wait(lambda: (lambda n: (n["AXRole"], label(n)) if n["AXRole"] in
                                      ("AXTextField", "AXSearchField", "AXComboBox") else None)(
                                      self.s.focused(pid)), "TextEdit focuses its Find field")
                elif key == "g":
                    detail = wait(lambda: (lambda v: v if v[1] == [11, 5] else None)(
                        self.state(field)), "next alpha match")
                else:
                    detail = wait(lambda: self.adopt_after(target_pid, previous) or self.dialog(target_pid, r"Font|Yazı"),
                                  "TextEdit font window")
                return f"{result}; real state {str(detail)[:300]}"
            self.case(scenario, combo, f"{mapped}; TextEdit {dict(a='select all',c='copy',v='paste',x='cut',z='undo',s='save',f='find',g='find next',n='new document',o='open panel',p='print panel',t='font panel',w='close test window',b='bold',i='italic at physical Turkish I position',u='underline',y='redo')[key]}",
                      (setup, action), baseline="ctrl+c / ctrl+v" if self.channel == "VNC" and key == "c" else None,
                      scope="TextEdit")
            if key == "f":
                self.end_text_find(pid)
            if key in "op":
                self.dismiss()
            if key in "nt":
                for created in self.s.windows(pid):
                    if created["handle"] != window["handle"] and created["handle"] in self.owned.get(pid, set()):
                        self.close_owned(pid, created)

    def end_text_find(self, pid):
        button = self.find_in_window(pid, r"^(Done|Bitti)$", depth=10)
        if button:
            self.press(button)

    def find_in(self, tree, pattern, role=None):
        return next((x for x in flatten(tree) if (not role or x["AXRole"] == role)
                     and any(re.search(pattern, v, re.I) for v in [label(x)] +
                             [str(x.get(a, "")) for a in ("AXTitle", "AXDescription", "AXValue", "AXIdentifier")])), None)

    def find_in_window(self, pid, pattern, role=None, depth=7, limit=160):
        return self.find_in(self.s.window(pid, depth=depth, limit=limit), pattern, role)

    def dialog(self, pid, pattern):
        for window in self.s.windows(pid):
            tree = self.s.ax(handle=window["handle"], depth=8, limit=160, full=True)
            found = self.find_in(tree, pattern)
            if found and (tree.get("AXSubrole") in ("AXDialog", "AXSystemDialog", "AXFloatingWindow")
                          or any(x["AXRole"] in ("AXSheet", "AXDialog") for x in flatten(tree))):
                return label(found) or label(tree)
        return None

    def close_test_text(self, start):
        pid, window, field = self.open_text(f"E2E-alt-f4-{time.time_ns()}")
        start = self.mark()
        self.fire("alt+f4")
        detail = self.solid_pair(start, "cmd+w")
        wait(lambda: window["handle"] not in {w["handle"] for w in self.s.windows(pid)}, "test TextEdit window closed")
        return detail + "; fixture AXWindow disappeared"

    def owner_windows(self, pattern):
        return [w for w in self.s.call("windows") if re.search(pattern, w.get("kCGWindowOwnerName", ""), re.I)
                and w["kCGWindowBounds"]["Width"] > 60 and w["kCGWindowBounds"]["Height"] > 15]

    def spotlight(self, combo, start, opening=True):
        before = {w["kCGWindowNumber"] for w in self.owner_windows("Spotlight")}
        self.fire(combo)
        if opening:
            windows = wait(lambda: [w for w in self.owner_windows("Spotlight") if w["kCGWindowNumber"] not in before],
                           "visible Spotlight window")
            return f"Spotlight window {windows[0]['kCGWindowNumber']} {windows[0]['kCGWindowBounds']}"
        self.solid_pair(start, "cmd+c")
        until = time.monotonic() + 0.7
        while time.monotonic() < until:
            check({w["kCGWindowNumber"] for w in self.owner_windows("Spotlight")} == before,
                  "Spotlight opened during Command+C")
        return "Command+C was delivered and Spotlight window set stayed unchanged"

    def screenshot_files(self):
        location = subprocess.run(["/usr/bin/defaults", "read", "com.apple.screencapture", "location"],
                                  text=True, capture_output=True)
        path = Path(location.stdout.strip()).expanduser() if location.returncode == 0 else Path.home() / "Desktop"
        return set(path.glob("*.png"))

    def system_cases(self, doc):
        pid, window, field = doc
        ready = lambda: self.prepare_text(doc, "E2E window sample", 3, 4)
        if self.channel == "VNC":
            self.case("Spotlight", "win tap", "Screen Sharing left Command tap opens Spotlight",
                      (ready, lambda _, start: self.spotlight("cmd", start)))
            if self.owner_windows("Spotlight"):
                self.dismiss()
            return
        for combo in ["left_cmd", "ctrl+escape", "cmd+c"]:
            self.case("Windows key chord" if combo == "cmd+c" else "Windows key", combo,
                      "Spotlight stays closed" if combo == "cmd+c" else "Spotlight window appears",
                      (ready, lambda _, start: self.spotlight(combo, start, combo != "cmd+c")),
                      baseline="left_cmd held in chord" if combo == "cmd+c" else None)
            if self.owner_windows("Spotlight"):
                self.dismiss()
                wait(lambda: not self.owner_windows("Spotlight"), "Spotlight gone")

        for combo, bundle, name in [
            ("cmd+e", FINDER, "Finder"), ("ctrl+shift+escape", "com.apple.ActivityMonitor", "Activity Monitor"),
            ("ctrl+alt+t", TERMINAL, "Terminal"),
        ]:
            def setup():
                ready()
                apps = self.s.apps(bundle)
                if apps:
                    self.remember(apps[0]["pid"])
                return {x["handle"] for x in self.s.windows(apps[0]["pid"])} if apps else set()
            def launch(before, _):
                self.fire(combo)
                app = wait(lambda: (lambda a: a if a.get("id") == bundle else None)(self.s.front()),
                           f"{name} frontmost", timeout=5)
                self.baseline_windows.setdefault(app["pid"], before)
                new = self.adopt_after(app["pid"], before)
                if not before and bundle != FINDER:
                    new = wait(lambda: self.adopt_after(app["pid"], before), f"{name} visible window", timeout=4)
                return f"NSWorkspace frontmost {app['id']} PID {app['pid']}; new AXWindows {[label(x) for x in new]}"
            self.case("Windows key", combo, f"{name} becomes frontmost", (setup, launch))

        def state_window():
            ax = self.s.ax(handle=window["handle"])
            return ax.get("AXPosition"), ax.get("AXSize"), ax.get("AXMinimized")

        initial_position, initial_size, _ = state_window()

        def desktop(_, start):
            active = lambda: [w for w in self.s.call("windows") if w.get("kCGWindowOwnerPID") == pid
                              and w["kCGWindowBounds"]["Width"] > 250]
            before = {w["kCGWindowNumber"]: w["kCGWindowBounds"] for w in active()}
            check(bool(before), "No onscreen fixture window before Show Desktop")
            self.fire("cmd+d")
            try:
                return wait(lambda: (lambda ws: f"TextEdit visible-window IDs/bounds changed from {before} to {ws}"
                    if ws != before else None)({w["kCGWindowNumber"]: w["kCGWindowBounds"] for w in active()}),
                    "Show Desktop window displacement")
            except Exception:
                if {w["kCGWindowNumber"]: w["kCGWindowBounds"] for w in active()} != before:
                    self.fire("cmd+d")
                raise
        self.case("Windows key", "cmd+d", "Show Desktop displaces the test window", (ready, desktop))
        if self.rows and next(r for r in self.rows if r["scenario"] == "Windows key" and r["injected"] == "cmd+d")["result"] == "pass":
            self.fire("cmd+d")
            wait(lambda: any(w.get("kCGWindowOwnerPID") == pid for w in self.s.call("windows")),
                 "test window restored from Show Desktop")

        def area(_, start):
            previous = {(w["kCGWindowOwnerPID"], w["kCGWindowNumber"]) for w in self.owner_windows("screencapture|Ekran Resmi")}
            old_apps = {a["pid"] for a in self.s.call("apps")}
            self.fire("shift+cmd+s")
            seen = wait(lambda: [a for a in self.s.call("apps") if re.search("screencapture", a["path"], re.I)
                                 and a["pid"] not in old_apps] or
                        [w for w in self.owner_windows("screencapture|Ekran Resmi")
                         if (w["kCGWindowOwnerPID"], w["kCGWindowNumber"]) not in previous],
                        "area capture UI (screencaptureui)")
            return str(seen)
        self.case("Windows key", "shift+cmd+s", "Area capture UI starts", (ready, area))
        self.dismiss()

        def full(_, start):
            old = self.screenshot_files()
            self.fire("f13")
            new = wait(lambda: [p for p in self.screenshot_files() - old
                                if re.search(r"Screenshot|Ekran Resmi|Screen Shot", p.name, re.I)],
                       "new system screenshot file", timeout=7)
            self.screenshots.update(new)
            for p in new:
                wait(lambda: p.exists() and p.stat().st_size > 1000, "system capture finished writing")
            return "; ".join(f"{p.name}, {p.stat().st_size} bytes" for p in new)
        self.case("Windows key", "f13", "A full screenshot PNG is written in the configured location", (ready, full))
        for path in self.screenshots:
            path.unlink(missing_ok=True)

        visible = self.s.call("frames")
        for combo, layout in [("cmd+left", "left"), ("cmd+right", "right"),
                              ("cmd+up", "fill"), ("cmd+down", "minimize")]:
            def tile(_, start):
                self.fire(combo)
                wanted = []
                for v in visible:
                    x, y, w, h = (v[field] for field in ("x", "y", "w", "h"))
                    wanted.append(([x + (w // 2 if layout == "right" else 0), y],
                                   [w if layout == "fill" else w // 2, h]))
                def observed():
                    pos, size, minimized = state_window()
                    if layout == "minimize":
                        return (pos, size, minimized) if minimized else None
                    if pos and size and any(all(abs(a - b) <= TILE_TOLERANCE for a, b in zip(pos + size, p + s))
                                            for p, s in wanted):
                        return pos, size, minimized
                    return None
                try:
                    return f"AXPosition, AXSize, AXMinimized {wait(observed, layout, timeout=3)}; visibleFrame {visible}"
                except AssertionError as error:
                    raise AssertionError(f"{error}; actual {state_window()}; expected {wanted}; "
                                         f"visibleFrame {visible}; tolerance {TILE_TOLERANCE} pt") from error
            self.case("Windows key", combo, f"AX window {layout}, checked against NSScreen.visibleFrame "
                      f"(±{TILE_TOLERANCE} pt)", (ready, tile))
            ax = self.s.ax(handle=window["handle"])
            if ax.get("AXMinimized"):
                self.s.set(window, "AXMinimized", False)
            self.restore_window(window, initial_position, initial_size)
        self.restore_window(window, initial_position, initial_size)
        self.space_cases(pid, ready)

    def restore_window(self, window, position, size):
        if size and position:
            self.s.set(window, "AXSize", size)
            self.s.set(window, "AXPosition", position)

    def space_cases(self, pid, ready):
        """Win+Ctrl+arrow must switch macOS Spaces (⌃←/⌃→ with the fn flag that arrows carry)."""
        info = self.s.call("space")
        spaces, origin = info["spaces"], info["active"]
        check(len(spaces) >= 2, f"Spaces cases need two Spaces on the main display, found {spaces}")
        index = spaces.index(origin)
        forward = index + 1 < len(spaces)
        there, back = ("right", "left") if forward else ("left", "right")
        target = spaces[index + 1] if forward else spaces[index - 1]

        def active():
            return self.s.call("space")["active"]

        def fixture_visible():
            return any(w.get("kCGWindowOwnerPID") == pid and w["kCGWindowBounds"]["Width"] > 250
                       for w in self.s.call("windows"))

        def switch(direction, source, destination):
            def action(_, start):
                self.fire(f"ctrl+cmd+{direction}")
                wait(lambda: active() == destination, f"active Space becomes {destination} (was {source})", timeout=4)
                # A second, real state change: the TextEdit fixture lives on the original Space only.
                wait(lambda: fixture_visible() == (destination == origin),
                     f"TextEdit fixture {'visible' if destination == origin else 'hidden'} on Space {destination}",
                     timeout=4)
                time.sleep(1.0)
                check(active() == destination, f"Space bounced from {destination} to {active()}")
                delivered = [e for e in self.seen(start) if e["type"] == 10 and e["key"] == KEYS[direction]]
                tap = (f"annotated tap saw ctrl+{direction} with flags " + ", ".join(hex(e["flags"]) for e in delivered)
                       if delivered else f"ctrl+{direction} was consumed by the macOS Spaces hotkey before the annotated tap")
                return f"CGS active Space {source} → {destination} of {spaces}; fixture window " \
                       f"{'visible' if fixture_visible() else 'hidden'}; {tap}"
            return action

        def setup_first():
            # Start from the app that was frontmost before the run: on a switch macOS activates the destination
            # Space's last-used app, and with TextEdit in front it can bounce straight back to the first Space.
            ready()
            if self.baseline_front and self.baseline_front != pid:
                self.s.activate(self.baseline_front)
                wait(lambda: self.s.front().get("pid") == self.baseline_front, "baseline app frontmost", timeout=4)

        try:
            self.case("Windows key", f"ctrl+cmd+{there}", f"Space switches {there} (CGS active Space {origin} → {target})",
                      (setup_first, switch(there, origin, target)))
            check(active() == target, f"Expected to be on Space {target} after the first switch, active is {active()}")
            self.case("Windows key", f"ctrl+cmd+{back}", f"Space switches back {back} (CGS active Space {target} → {origin})",
                      (None, switch(back, target, origin)))
        finally:
            if active() != origin:
                self.s.inject(f"ctrl+cmd+{back}")
            wait(lambda: active() == origin, "original Space restored", timeout=4)
            self.s.activate(pid)

    def robustness(self, doc):
        seed = 0x4B4559
        rng = random.Random(seed)
        letters = list("abcdehijlmrstuvxyz123")
        navigation = ["left", "right", "up", "down", "backspace", "delete"]
        choices = ([m + k for m in ("", "shift+") for k in letters + navigation] +
                   [m + k for m in ("ctrl+", "ctrl+shift+") for k in
                    ("left", "right", "backspace", "delete")])
        combos = [rng.choice(choices) for _ in range(2000)]
        ready = lambda: self.prepare_text(doc, "stress seed", 4)
        def stress(context, start):
            self.s.call("pasteboard", text="PasteFixture")
            initial = self.s.call("flags")
            before_posts = self.s.call("postMark")
            for i in range(0, len(combos), 100):
                check(self.s.front().get("pid") == context[0], "TextEdit lost focus during stress stream")
                self.s.call("inject", expectedPID=context[0],
                            steps=[e for c in combos[i:i+100] for e in steps(c, delay=1)])
                # Flush callbacks from each burst before issuing the next one.
                self.mark()
            plain = self.mark()
            self.fire("k")
            self.solid_pair(plain, "k")
            state = self.s.call("flags")
            log = self.s.call("log", start=start, includePosted=True, postStart=before_posts)
            posted = {e["time"] for e in log["posted"] if e["type"] == 10}
            check(len(posted) == 2001, f"Expected 2,000 random key-downs and plain K, posted {len(posted)}")
            samples = sorted((e["seen"] - e["time"]) / 1e6 for e in log["events"]
                             if e["type"] == 10 and e["time"] in posted and e["seen"] >= e["time"])
            check(not any(e["type"] == "tap-disabled" for e in log["events"]), "Observer tap was disabled")
            check(state["hid"] & (MOD_MASK | MODS["fn"]) == state["combined"] & (MOD_MASK | MODS["fn"]) == 0,
                  f"Nonempty modifier state {state}")
            check(len(samples) >= 1000, f"Insufficient matched latency samples: {len(samples)}")
            pct = [round(samples[round((len(samples) - 1) * p)], 3) for p in (.50, .95, .99)]
            self.latency = dict(samples=len(samples), p50_ms=pct[0], p95_ms=pct[1], p99_ms=pct[2], seed=seed)
            self.latency["flags_before"] = initial
            self.latency["flags_after"] = state
            return f"2,000 inputs; raw flags {initial} → {state}; modifiers zero; plain K pair; {len(samples)} samples, p50/p95/p99 {pct} ms, seed {seed}"
        self.case("Robustness", "2,000 random inputs", "Zero HID/session modifier flags, plain K and correlated latency",
                  (ready, stress))
        for count, early, baseline in [(6, False, "hold key with 30 ms repeat events"),
                                       (0, True, "release ctrl before letter")]:
            def matching(_, start):
                began = self.mark()
                self.fire("ctrl+c", repeat=count, early=early)
                self.solid_pair(began, "cmd+c")
                events = self.seen(began)
                repeats = [e for e in events if e["type"] == 10 and e["key"] == KEYS["c"] and e["repeat"]]
                check(len(repeats) == count and all(e["flags"] & MOD_MASK == MODS["cmd"] for e in repeats),
                      f"Expected {count} mapped repeats, observed {repeats}")
                if early:
                    offsets = [i for i, e in enumerate(events) if
                               (e["type"] == 12 and e["key"] == KEYS["ctrl"] and not e["flags"] & MODS["ctrl"])
                               or (e["type"] == 11 and e["key"] == KEYS["c"])]
                    check(len(offsets) == 2 and events[offsets[0]]["type"] == 12,
                          "Control-up did not precede Command+C-up")
                self.solid_plain_key()
                return f"Command+C down/up matched; {len(repeats)} repeat events at ~30 ms; plain K after the chord"
            self.case("Robustness", baseline, "Command+C output pair, correct repeats and plain key afterward",
                      (ready, matching))

    def solid_plain_key(self):
        cursor = self.mark()
        self.fire("k")
        self.solid_pair(cursor, "k")

    def vnc_setup(self, doc):
        self.channel = "VNC"
        def discover(_, start):
            self.rfb = RFB(os.environ.get("KEYSHIFT_VNC_USER") or os.environ.get("USER"),
                           security_type=self.vnc_security_type)
            details = {}
            cursor = self.s.call("cursor")
            target = (137, 117) if sum(cursor) != 254 else (227, 217)
            self.rfb.pointer(*target, 0)
            try:
                moved = wait(lambda: (lambda p: p if p != cursor else None)(self.s.call("cursor")),
                             "VNC pointer reaches console", timeout=0.65)
            except AssertionError:
                moved = self.s.call("cursor")
            for name in ("ctrl", "alt", "super", "meta"):
                # Screen Sharing posts a modifier change together with the next key event, so press A with each
                # modifier (select all in the probe document) and keep the flags of the annotated modifier events.
                for attempt in range(3):
                    marker = self.mark()
                    self.rfb.key(name, True)
                    time.sleep(0.06)
                    self.rfb.key("a", True)
                    self.rfb.key("a", False)
                    time.sleep(0.06)
                    self.rfb.key(name, False)
                    try:
                        wait(lambda: any(e["type"] == 12 and e["flags"] & MOD_MASK for e in self.seen(marker)),
                             f"annotated modifier event for {name}", timeout=1.0)
                    except AssertionError:
                        pass
                    observed = [e for e in self.seen(marker) if e["type"] == 12 and e["flags"] & MOD_MASK]
                    details[name] = sorted({(e["key"], e["flags"] & MOD_MASK)
                                           for e in observed if e["flags"] & MOD_MASK in MODS.values()})
                    time.sleep(0.15)
                    if details[name]:
                        break
            for intended in ("ctrl", "alt", "cmd"):
                self.route[intended] = next((name for name, events in details.items()
                    if any(flags == MODS[intended] and (intended != "cmd" or code == 55)
                           for code, flags in events)), intended)
            self.modifier_map = details
            check(all(details[k] for k in ("ctrl", "alt")) and any(details[k] for k in ("super", "meta")),
                  f"Authenticated {self.rfb.server_version} with security type {self.rfb.security_type}; framebuffer {self.rfb.width}×{self.rfb.height}; "
                  f"pointer request {target}, cursor {cursor} → {moved}; annotated modifier delivery {details}")
            return f"{self.rfb.server_version}: Control_L, Alt_L, Super_L, Meta_L as (macOS keycode, aggregate flags): {details}; route {self.route}"
        self.case("VNC modifier mapping", "Control_L / Alt_L / Super_L / Meta_L",
                  "RFB mouse/keyboard connection and empirical sides/modifiers",
                  (lambda: self.prepare_text(doc, "RFB modifier probe", 3), discover))
        return self.rfb is not None

    def vnc_cases(self, doc):
        try:
            if not self.vnc_setup(doc):
                return
            self.text_shortcuts(doc)
            self.text_navigation(doc)
            self.case("TextEdit close window", "alt+f4", "Fixture TextEdit window disappears",
                      lambda _, start: self.close_test_text(start))
            self.system_cases(doc)
            if not hasattr(self, "finder"):
                self.finder_setup()
            self.finder_cases()
        finally:
            self.channel = "HID"
            if self.rfb:
                self.rfb.close()
                self.rfb = None

    def finder_setup(self):
        pid = self.open_app(FINDER, "Finder")
        self.remember(pid)
        before = {x["handle"] for x in self.s.windows(pid)}
        self.s.activate(pid)
        self.s.inject("right_cmd+n")
        window = wait(lambda: self.adopt_after(pid, before), "new Finder-only fixture window")[0]
        folder = self.root / "finder"
        folder.mkdir(exist_ok=True)
        fixture = folder / f"fixture-{time.time_ns()}"
        fixture.mkdir()
        self.created_dirs.append(fixture)
        suffix = f"-{os.getpid()}.txt"
        for name in ("Alpha", "Bravo", "Charlie", "Delete", "Move", "Open", "Renameme"):
            (fixture / (name + suffix)).write_text("Keyshift E2E " + name)
        (fixture / "Subfolder").mkdir()
        self.finder = (pid, window, fixture, suffix)
        position = self.s.ax(handle=window["handle"]).get("AXPosition")
        if position:
            self.s.set(window, "AXPosition", [65, 80])
            self.original_positions[window["handle"]] = position
        self.finder_go(fixture)
        self.s.inject("right_cmd+2")
        return self.finder

    def finder_window(self, depth=0):
        pid, window, _, _ = self.finder
        return self.s.ax(handle=window["handle"], depth=depth, limit=225, full=depth > 0)

    def finder_path(self):
        window = self.finder_window()
        if "AXDocument" in window:
            from urllib.parse import unquote, urlparse
            return unquote(urlparse(window["AXDocument"]).path.rstrip("/"))
        return window.get("AXTitle", "")

    def finder_at(self, path):
        return self.finder_path() in (str(path), path.name)

    def finder_go(self, path):
        pid, window, _, _ = self.finder
        self.s.activate(pid)
        self.s.action(window, "AXRaise")
        if self.finder_at(path):
            return
        self.s.inject("shift+right_cmd+g")
        self.set_focused_text(pid, str(path))
        self.s.inject("return")
        # Completion is presented as a selected location before the sheet can dismiss.
        try:
            wait(lambda: self.finder_at(path), str(path), timeout=1.1)
        except AssertionError:
            self.s.inject("return")
            wait(lambda: self.finder_at(path), str(path))

    def set_focused_text(self, pid, value):
        field = wait(lambda: (lambda x: x if x["AXRole"] in ("AXTextField", "AXTextArea", "AXComboBox") else None)(
            self.s.focused(pid)), f"focused text field in {pid}")
        self.s.inject("right_cmd+a")
        self.s.call("pasteboard", text=value)
        self.s.inject("right_cmd+v")
        return field

    def finder_selection(self):
        collected = {}
        for item in flatten(self.finder_window(8)):
            for key in ("AXSelectedChildren", "AXSelectedRows"):
                for row in item.get(key, []):
                    collected[row["handle"]] = row
        return list(collected.values())

    def finder_node(self, name):
        return self.find_in(self.finder_window(9), re.escape(name))

    def finder_select(self, name):
        node = wait(lambda: self.finder_node(name), f"Finder element {name}")
        # Clicking a name that is already selected starts Finder's inline rename, which is a text field.
        if not (self.finder_selected(name) and len(self.finder_selection()) == 1 and not self.finder_rename()):
            self.s.click(node)
            wait(lambda: self.finder_selected(name), f"Finder selects {name}")
        return node

    def finder_selected(self, name):
        for row in self.finder_selection():
            if name in label(row):
                return True
            if self.find_in(self.s.ax(handle=row["handle"], depth=4, limit=25), re.escape(name)):
                return True
        return False

    def finder_rename(self):
        pid = self.finder[0]
        return next((n for n in flatten(self.finder_window(9)) if n["AXRole"] == "AXTextField"
                     and n.get("AXFocused") and "Renameme" in str(n.get("AXValue"))), None) or (
            lambda x: x if x["AXRole"] == "AXTextField" and isinstance(x.get("AXSelectedTextRange"), list)
            else None)(self.s.focused(pid))

    def finder_cases(self):
        pid, window, folder, suffix = self.finder
        if self.channel == "VNC":
            combos = ["f2"]
        else:
            combos = ["f2", "return", "keypad_enter", "delete", "backspace", "alt+up", "alt+left",
                      "alt+right", "alt+return", "ctrl+shift+v"]
        outputs = dict(f2="return", return_="cmd+o", keypad_enter="cmd+o", delete="cmd+backspace",
                       backspace="cmd+up", **{"alt+up": "cmd+up", "alt+left": "cmd+left_bracket",
                       "alt+right": "cmd+right_bracket", "alt+return": "cmd+i", "ctrl+shift+v": "alt+cmd+v"})
        outputs["return"] = outputs["return_"]
        for combo in combos:
            def setup():
                self.finder_go(folder)
                if combo in ("backspace", "alt+up", "alt+left"):
                    self.finder_go(folder / "Subfolder")
                elif combo == "alt+right":
                    self.finder_go(folder / "Subfolder")
                    self.s.inject("right_cmd+left_bracket")
                    wait(lambda: self.finder_at(folder), "Finder native back")
                elif combo == "ctrl+shift+v":
                    self.finder_select("Move" + suffix)
                    self.s.inject("right_cmd+c")
                    # Go via the folder icon so Go to Folder does not overwrite the file clipboard.
                    self.s.click(wait(lambda: self.finder_node("Subfolder"), "Subfolder"), count=2)
                    wait(lambda: self.finder_at(folder / "Subfolder"), "Finder move destination")
                else:
                    self.finder_select({"delete": "Delete", "f2": "Renameme"}.get(combo, "Open") + suffix)
                apps = self.s.apps(TEXTEDIT)
                return {w["handle"] for w in self.s.windows(apps[0]["pid"])} if apps else set()
            def action(text_before, start):
                old = {w["handle"] for w in self.s.windows(pid)}
                try:
                    system_focus = self.s.ax(target="AXFocusedUIElement")
                    pre = f"{system_focus.get('AXRole')} {system_focus.get('AXSubrole')} {label(system_focus)[:60]!r}"
                except RuntimeError as problem:
                    pre = str(problem)
                self.fire(combo)
                try:
                    mapped = self.solid_pair(start, outputs[combo])
                except AssertionError as error:
                    focus = self.s.focused(pid)
                    raise AssertionError(f"{error}; system focus before key {pre}; front {self.s.front().get('id')}; Finder focus "
                                         f"{focus.get('AXRole')} {focus.get('AXSubrole')} {label(focus)[:80]!r}") from error
                if combo == "f2":
                    field = wait(self.finder_rename, "Finder inline rename field")
                    detail = f"focused AXTextField {field.get('AXValue')!r}, selection {field.get('AXSelectedTextRange')}"
                elif combo in ("return", "keypad_enter"):
                    def open_fixture():
                        apps = self.s.apps(TEXTEDIT)
                        if not apps:
                            return None
                        text_pid = apps[0]["pid"]
                        windows = self.adopt_after(text_pid, text_before)
                        return next(((text_pid, w) for w in windows if "Open" + suffix in label(w)), None)
                    self.finder_opened = wait(open_fixture, "fixture .txt opened in TextEdit")
                    detail = label(self.finder_opened[1])
                elif combo == "delete":
                    trashed = Path.home() / ".Trash" / ("Delete" + suffix)
                    self.trash.add(trashed)
                    wait(lambda: trashed.is_file() and not (folder / trashed.name).exists(), "fixture in ~/.Trash")
                    detail = str(trashed)
                elif combo in ("backspace", "alt+up", "alt+left", "alt+right"):
                    expected = folder / "Subfolder" if combo == "alt+right" else folder
                    wait(lambda: self.finder_at(expected), f"Finder destination {expected}")
                    detail = self.finder_path()
                elif combo == "alt+return":
                    self.finder_info = wait(lambda: self.adopt_after(pid, old) or [
                        self.adopt(pid, w) for w in self.s.windows(pid) if re.search(
                            re.escape("Open" + suffix) + ".*(?:Info|Bilgi)|(?:Info|Bilgi).*" + re.escape("Open" + suffix),
                            label(w), re.I) and w["handle"] not in self.baseline_windows.get(pid, set())],
                        "new Finder Get Info window")
                    detail = [label(w) for w in self.finder_info]
                else:
                    before = folder / ("Move" + suffix)
                    after = folder / "Subfolder" / before.name
                    wait(lambda: after.is_file() and not before.exists(), "fixture file moved")
                    detail = str(after)
                return f"{mapped}; {detail}"
            self.finder_opened = None
            self.finder_info = []
            self.case("Finder" if self.channel == "HID" else "Finder rename", combo,
                      f"{outputs[combo]}; Finder action on the fixture", (setup, action))
            if combo == "f2" and self.finder_rename():
                self.dismiss()
            if self.finder_opened:
                self.close_owned(*self.finder_opened)
            for info in self.finder_info:
                self.close_owned(pid, info)
        if self.channel == "VNC":
            return

        def start_rename():
            self.finder_go(folder)
            self.finder_select("Renameme" + suffix)
            self.s.inject("f2")
            field = wait(self.finder_rename, "inline rename field")
            old = field["AXValue"]
            self.s.set(field, "AXSelectedTextRange", [len("Renameme"), 0])
            return field, old

        for combo in ("backspace", "f2", "return"):
            def rename(context, start):
                field, old = context
                path = self.finder_path()
                if combo == "return":
                    self.s.type("Z")
                    new = "RenamemeZ" + suffix
                    self.fire("return")
                    self.solid_pair(start, "return")
                    wait(lambda: (folder / new).exists() and not (folder / old).exists()
                         and not self.finder_rename(), "committed rename")
                    wait(lambda: self.s.front().get("pid") == pid, "Finder stays frontmost after rename")
                    return f"{old!r} → {new!r}; no TextEdit open; folder {path}"
                self.fire(combo)
                self.solid_pair(start, combo)
                expected = old.replace("Renameme", "Renamem") if combo == "backspace" else old
                observed = wait(lambda: (lambda n: n if n and n.get("AXValue") == expected else None)(self.finder_rename()),
                                f"rename field still editing {expected}")
                check(self.finder_path() == path, "Finder navigated while editing")
                return f"plain {combo}; inline value {observed['AXValue']!r}; folder stayed {path}"
            self.case("Finder rename mode", combo, "Inline rename behavior with the file-list rule inactive",
                      (start_rename, rename), baseline="return / backspace / f2" if combo == "backspace" else None)
            if combo != "return":
                self.dismiss()
            else:
                # The commit renamed the fixture; put its name back for the later cases (VNC F2 selects it).
                renamed = folder / ("RenamemeZ" + suffix)
                if renamed.exists() and not (folder / ("Renameme" + suffix)).exists():
                    renamed.rename(folder / ("Renameme" + suffix))

        def address(_, start):
            self.fire("ctrl+l")
            self.solid_pair(start, "shift+cmd+g")
            field = wait(lambda: (lambda n: n if n["AXRole"] in ("AXTextField", "AXComboBox") else None)(
                self.s.focused(pid)), "Finder Go to Folder address")
            return f"Go to Folder focused {field['AXRole']} {label(field)}"
        self.case("Finder address bar", "ctrl+l", "Go to Folder opens", (lambda: self.finder_go(folder), address))
        self.dismiss()

        def multi(_, start):
            self.finder_select("Alpha" + suffix)
            target = self.s.ax(handle=self.finder_node("Bravo" + suffix)["handle"])
            x, y = target["AXPosition"]
            w, h = target["AXSize"]
            self.s.call("inject", steps=[{"key": 59, "down": True}, {"ms": 20},
                {"x": x + w / 2, "y": y + h / 2}, {"ms": 20}, {"key": 59, "down": False}])
            wait(lambda: self.finder_selected("Alpha" + suffix) and self.finder_selected("Bravo" + suffix),
                 "both Finder rows selected")
            wait(lambda: any(e["type"] == 1 and e["flags"] & MOD_MASK == MODS["cmd"] for e in self.seen(start)),
                 "annotated Command+click")
            check(not re.search("Menu", self.s.focused(pid)["AXRole"]), "Context menu received focus")
            return "AXSelectedChildren contains Alpha and Bravo; annotated Command+left-button down; no context menu"
        self.case("Ctrl+click multi-select", "ctrl+left_click", "Two selected Finder files, no context menu",
                  (lambda: self.finder_go(folder), multi))

    @contextlib.contextmanager
    def config_overlay(self, transform):
        """Run with a modified copy of the installed config; the original bytes always come back."""
        original = self.config.read_bytes()
        mode = self.config.stat().st_mode & 0o777
        changed = transform(original.decode("utf-8"))
        check(changed != original.decode("utf-8"), "Config overlay changed nothing")

        def install(content):
            staged = self.config.with_name(".e2e-overlay.yaml")
            staged.write_bytes(content)
            staged.chmod(mode)
            staged.replace(self.config)
            self.cmd(self.keyshift, "reload")
        try:
            install(changed.encode("utf-8"))
            yield
        finally:
            install(original)

    def chrome_fixture(self, index=0, revision="initial"):
        path = self.stage / f"chrome-{index}.html"
        path.write_text(f"""<!doctype html><meta charset="utf-8"><title>E2E tab {index}</title>
<style>body{{font:22px system-ui;margin:50px}} #editor{{white-space:pre;border:1px solid;padding:20px}}</style>
<h1>Keyshift fixture {index}</h1><p>{revision}</p>
<div id="editor" contenteditable="true" aria-label="E2E editor">alpha beta alpha</div>
<script>
const editor = document.querySelector('#editor');
function report() {{
  document.title = 'E2E tab {index} {revision} | zoom=' + devicePixelRatio +
   ' | text=' + editor.innerText + ' | select=' + getSelection().toString() +
   ' | markup=' + editor.innerHTML;
}}
document.addEventListener('selectionchange', report);
editor.addEventListener('input', report);
window.addEventListener('resize', report);
report();
</script>""", encoding="utf-8")
        return path

    def chrome_processes(self):
        profile = str(self.root / "chrome-profile")
        paths = self.cmd("/bin/ps", "-axww", "-o", "pid=,command=").stdout
        owned = {}
        for line in paths.splitlines():
            fields = line.split(None, 1)
            if len(fields) != 2:
                continue
            pid, command = fields
            if command.startswith("/Applications/Google Chrome.app/Contents/") and re.search(
                    rf"(?:--user-data-dir={re.escape(profile)}(?= |$)|--database={re.escape(profile)}/Crashpad(?= |$))", command):
                owned[int(pid)] = command.startswith("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome ")
        return owned

    def find_chrome(self):
        owned = self.chrome_processes()
        return next((x for x in self.s.apps(CHROME) if owned.get(x["pid"])), None)

    def chrome_start(self):
        profile = self.root / "chrome-profile"
        check(not self.chrome_processes(), "A Chrome process already uses the dedicated test profile")
        check(not profile.exists() or (profile / ".keyshift-e2e-owned").exists(),
              "Dedicated Chrome profile directory exists without harness ownership marker")
        profile.mkdir(exist_ok=True)
        (profile / ".keyshift-e2e-owned").touch()
        self.chrome_profile = profile
        fixture = self.chrome_fixture()
        self.cmd("/usr/bin/open", "-na", "Google Chrome", "--args", f"--user-data-dir={profile}",
                 "--no-first-run", "--no-default-browser-check", fixture.as_uri())
        self.chrome_pid = wait(self.find_chrome, "isolated Chrome process", timeout=10)["pid"]
        self.s.activate(self.chrome_pid)
        wait(lambda: self.chrome_title() and "E2E tab 0" in self.chrome_title(), "Chrome fixture", timeout=8)

    def chrome_focus(self):
        check(self.chrome_pid and self.find_chrome() and self.find_chrome()["pid"] == self.chrome_pid,
              "Refusing to drive a non-fixture Chrome process")
        self.s.activate(self.chrome_pid)

    def chrome_title(self):
        window = self.s.window(self.chrome_pid)
        return window.get("AXTitle", "")

    def chrome_address(self):
        focus = self.s.focused(self.chrome_pid)
        return focus if focus["AXRole"] in ("AXTextField", "AXComboBox") and (
            re.search(r"Search.*address|Address|adres|arama", label(focus), re.I) or not focus.get("AXURL")) else None

    def chrome_go(self, url, new_tab=False):
        self.chrome_focus()
        if new_tab:
            self.s.inject("right_cmd+t")
        self.s.inject("ctrl+l")
        self.set_focused_text(self.chrome_pid, url)
        self.s.inject("return")

    def chrome_wait_title(self, expression):
        return wait(lambda: (lambda title: title if re.search(expression, title, re.I) else None)(self.chrome_title()),
                    f"Chrome AX window title {expression}; initial {self.chrome_title()!r}", timeout=4)

    def chrome_url_field(self):
        nodes = self.s.window(self.chrome_pid, depth=8, limit=140)
        return self.find_in(nodes, r"Address and search bar|Adres ve arama çubuğu|Omnibox", "AXTextField")

    def browser_cases(self):
        pid = self.chrome_pid
        fixture = self.stage / "chrome-0.html"
        def ready():
            self.chrome_focus()
            if "E2E tab 0" not in self.chrome_title():
                self.chrome_go(fixture.as_uri())
                self.chrome_wait_title("E2E tab 0")
        for combo, mapped in [
            ("ctrl+l", "cmd+l"), ("ctrl+r", "cmd+r"), ("f5", "cmd+r"), ("ctrl+d", "cmd+d"),
            ("ctrl+h", "cmd+y"), ("ctrl+j", "shift+cmd+j"),
        ]:
            def action(_, start):
                if combo in ("ctrl+r", "f5"):
                    revision = f"rev{time.time_ns()}"
                    self.chrome_fixture(revision=revision)
                if combo == "ctrl+j":
                    # Chrome's Downloads page is shift+cmd+j (cmd+j is "Jump to Selection").
                    self.fire(combo)
                    pair = self.solid_pair(start, mapped)
                    detail = self.chrome_wait_title(r"Downloads|İndiril|İndirme")
                    self.s.inject("right_cmd+w")
                    return f"{pair}; {detail}"
                self.fire(combo)
                pair = self.solid_pair(start, mapped)
                if combo == "ctrl+l":
                    field = wait(self.chrome_address, "Chrome omnibox focused")
                    detail = label(field)
                    check("chrome-0.html" in detail, f"Omnibox does not show fixture URL: {detail}")
                elif combo in ("ctrl+r", "f5"):
                    detail = self.chrome_wait_title(revision)
                elif combo == "ctrl+d":
                    detail = wait(lambda: self.find_in_window(pid, r"Bookmark added|Yer işareti eklendi|Yer işaretini düzenle|Edit bookmark"),
                                  "Chrome bookmark confirmation")
                    detail = label(detail)
                else:
                    page = r"History|Geçmiş"
                    detail = self.chrome_wait_title(page)
                return f"{pair}; {detail}"
            self.case("Browser downloads" if combo == "ctrl+j" else "Browser shortcuts", combo,
                      f"{mapped}; Chrome live browser state", (ready, action), scope="throwaway Chrome")
            self.dismiss()

        previous = self.s.window(pid)
        self.s.inject("right_cmd+n")
        self.s.call("pasteboard", text=fixture.as_uri())
        self.chrome_go(fixture.as_uri())
        self.chrome_wait_title("E2E tab 0")
        if previous["handle"] != self.s.window(pid)["handle"]:
            self.s.close_window(previous)
        for index in range(1, 9):
            self.chrome_go(self.chrome_fixture(index).as_uri(), new_tab=True)
            self.chrome_wait_title(fr"E2E tab {index} ")
        # Tabs 1--9 select positions 1--8 and the last tab. Use nine identifiable fixture tabs.
        for i in range(1, 10):
            combo = f"ctrl+{i}"
            def tab(_, start):
                self.fire(combo)
                return self.solid_pair(start, f"cmd+{i}") + "; " + self.chrome_wait_title(fr"E2E tab {i-1} ")
            self.case("Browser shortcuts", combo, f"Chrome selects fixture tab {i - 1}",
                      (self.chrome_focus, tab), scope="throwaway Chrome")

        ready()
        def read_zoom():
            return float(re.search(r"zoom=([0-9.]+)", self.chrome_title())[1])
        for key, relation in [("equal", lambda a, b: b > a), ("minus", lambda a, b: b < a), ("0", lambda a, b: a == b)]:
            def zoom_setup():
                self.chrome_focus()
                self.s.inject("right_cmd+0")
                original = wait(lambda: (lambda z: z if abs(z - 1) < 0.001 else None)(read_zoom()),
                                "default fixture devicePixelRatio")
                if key == "equal" and "equal" in UNAVAILABLE:
                    raise Impossible(self.prove_no_zoom_in(read_zoom))
                if key == "0":
                    self.s.inject("right_cmd+minus" if "equal" in UNAVAILABLE else "right_cmd+equal")
                    wait(lambda: read_zoom() != original, "non-default native Chromium zoom")
                return original, read_zoom()
            def zoom(previous, start):
                original, before = previous
                self.fire(f"ctrl+{key}")
                result = self.solid_pair(start, f"cmd+{key}")
                after = wait(lambda: (lambda z: z if relation(original if key == "0" else before, z) else None)(read_zoom()),
                             f"Chromium zoom changes from {before}")
                check(after != before, "Zoom did not change")
                return f"{result}; fixture devicePixelRatio {before} → {after}, default {original}"
            self.case("Browser shortcuts", f"ctrl+{key}", f"Chrome {'resets zoom' if key == '0' else ('zooms in' if key == 'equal' else 'zooms out')} with Turkish layout",
                      (zoom_setup, zoom), scope="throwaway Chrome")

    def prove_no_zoom_in(self, read_zoom):
        """Chrome zooms in on Command+= (or +). Show no key on this layout can send either.

        The layout tables say which key types '=' or '+' in any layer. Press each of those (and the keypad plus)
        with Command, and with Command+Shift, while Keyshift is disabled, except combos that an enabled macOS
        shortcut takes first."""
        wanted = []
        for row in LAYOUT_ROWS:
            for layer, extra in (("plain", ""), ("shift", "shift+"), ("cmd", ""), ("cmdShift", "shift+")):
                if row[layer] in ("=", "+"):
                    wanted.append((row["key"], layer, row[layer]))
        pairs = []
        for code, _, _ in wanted:
            pairs += [("cmd", code), ("cmd+shift", code)]
        pairs += [("cmd", 69), ("cmd+shift", 69)]
        pairs = list(dict.fromkeys(pairs))
        tried, skipped = [], []
        self.cmd(self.keyshift, "disable")
        try:
            for modifiers, code in pairs:
                name = f"code{code}"
                KEYS[name] = code
                if self.system_hotkeys_for(f"{modifiers}+{name}"):
                    skipped.append(f"{modifiers}+{code}")  # a macOS shortcut (e.g. screenshots) takes it first
                    continue
                self.s.inject("right_cmd+0")
                wait(lambda: abs(read_zoom() - 1) < 0.001, "zoom reset for the probe")
                self.s.inject(f"{modifiers.replace('cmd', 'right_cmd')}+{name}")
                tried.append(f"{modifiers}+{code}")
                time.sleep(0.3)
                check(read_zoom() <= 1.0001, f"{modifiers}+key {code} zoomed in; zoom-in is reachable")
        finally:
            self.cmd(self.keyshift, "enable")
            self.s.inject("right_cmd+0")
        typed = ", ".join(f"key {c} ({layer}) types {ch!r}" for c, layer, ch in wanted) or "no key"
        return (f"Chrome zooms in only on Command+'=' or '+'. On this layout {typed}; "
                f"{UNAVAILABLE['equal']}. With Keyshift disabled, Command and Command+Shift presses of those keys and "
                f"the keypad plus ({', '.join(tried)}) never zoomed in; {', '.join(skipped) or 'none'} belong to "
                "enabled macOS shortcuts (screenshot keys) and never reach Chrome. The key that types '-' (position 24) "
                "does zoom out, and ctrl+minus passes")

    def chrome_editor(self, fixture):
        self.chrome_go(fixture.as_uri())
        self.chrome_wait_title("E2E tab 0")
        field = wait(lambda: self.find_in_window(self.chrome_pid, r"E2E editor", depth=10, limit=230),
                     "Chrome fixture contenteditable")
        self.s.click(field)
        current = self.s.focused(self.chrome_pid)
        check(current["AXRole"] in ("AXTextArea", "AXTextField"), f"Chrome fixture focus was {current}")
        return current

    def chrome_ctrl_cases(self):
        pid = self.chrome_pid
        fixture = self.stage / "chrome-0.html"
        for key in "a c v x z s f g n o p t w b i u y".split():
            combo = f"ctrl+{key}"
            mapped = "shift+cmd+z" if key == "y" else f"cmd+{key}"
            def setup():
                self.chrome_focus()
                before = {w["handle"] for w in self.s.windows(pid)}
                if key in "w":
                    self.s.inject("right_cmd+n")
                    wait(lambda: self.adopt_after(pid, before), "Chrome fixture-only window")
                field = self.chrome_editor(fixture)
                if key in "cxbiu":
                    self.s.inject("right_cmd+a")
                if key in "cvx":
                    self.s.call("pasteboard", text="Chrome E2E" if key == "v" else "Chrome sentinel")
                if key in "zy":
                    self.s.type("Z")
                    self.chrome_wait_title(r"text=.*Z")
                    if key == "y":
                        self.s.inject("right_cmd+z")
                        self.chrome_wait_title("text=alpha beta alpha")
                if key == "g":
                    self.s.inject("ctrl+f")
                    self.set_focused_text(pid, "alpha")
                    self.s.inject("escape")
                return field, {w["handle"] for w in self.s.windows(pid)}, self.s.window(pid)
            def action(context, start):
                field, previous, window = context
                self.fire(combo)
                pair = self.solid_pair(start, mapped)
                if key == "a":
                    detail = self.chrome_wait_title("select=alpha beta alpha")
                elif key in "cx":
                    detail = wait(lambda: self.s.call("pasteboard") == "alpha beta alpha" and
                                  "clipboard = alpha beta alpha", "Chrome copies selected editor text")
                    if key == "x":
                        detail += "; " + self.chrome_wait_title(r"text=\s*\|")
                elif key == "v":
                    detail = self.chrome_wait_title("text=.*Chrome E2E")
                elif key in "zy":
                    detail = self.chrome_wait_title("text=.*Z" if key == "y" else "text=alpha beta alpha")
                elif key in "biu":
                    detail = self.chrome_wait_title({"b": r"markup=.*<(b|strong)>",
                                                      "i": r"markup=.*<(i|em)>", "u": r"markup=.*<u>"}[key])
                elif key in "sop":
                    detail = wait(lambda: self.dialog(pid, r"Save|Print|Open|Kaydet|Yazdır|Aç") or
                                  self.find_in_window(pid, r"Print Preview|Yazdır|Önizleme", depth=9),
                                  "Chrome dialog")
                elif key in "fg":
                    detail = wait(lambda: self.chrome_find_state(), "Chrome Find field and match counter")
                elif key == "n":
                    detail = wait(lambda: self.adopt_after(pid, previous), "new Chrome window")
                elif key == "t":
                    detail = self.chrome_wait_title(r"New Tab|Yeni Sekme")
                else:
                    detail = wait(lambda: window["handle"] not in {w["handle"] for w in self.s.windows(pid)}
                                  and "fixture Chrome window closed", "Chrome closes single-tab window")
                return f"{pair}; {str(detail)[:360]}"
            self.case("Ctrl shortcuts in Chrome", combo, f"{mapped}; real Chrome state", (setup, action),
                      scope="throwaway Chrome")
            if key in "sopfg":
                self.dismiss()
            if key == "t" and "E2E tab" not in self.chrome_title():
                self.s.inject("right_cmd+w")

    def chrome_find_state(self):
        tree = self.s.window(self.chrome_pid, depth=10, limit=230)
        nodes = [label(n) for n in flatten(tree) if re.search(r"Find in page|Sayfada bul|\b[12]/2\b|eşleşme", label(n), re.I)]
        return nodes or None

    def chrome_alt_f4(self):
        def setup():
            if not self.find_chrome():
                self.chrome_start()
            self.chrome_focus()
            pid = self.chrome_pid
            before = {w["handle"] for w in self.s.windows(pid)}
            self.s.inject("right_cmd+n")
            target = wait(lambda: self.adopt_after(pid, before), "Chrome test window for Alt+F4")[0]
            self.s.inject("right_cmd+t")
            return target
        def close(window, start):
            self.fire("alt+f4")
            pair = self.solid_pair(start, "shift+cmd+w")
            wait(lambda: window["handle"] not in {w["handle"] for w in self.s.windows(self.chrome_pid)}, "entire Chrome window closed")
            return pair + "; test Chrome window with multiple tabs disappeared"
        self.case("Browser shortcuts", "alt+f4", "Entire multi-tab throwaway Chrome window closes",
                  (setup, close), scope="throwaway Chrome")

    def safari_case(self):
        pid = self.open_app(SAFARI, "Safari")
        self.remember(pid)
        self.s.activate(pid)
        before = {w["handle"] for w in self.s.windows(pid)}
        self.s.inject("shift+right_cmd+n")
        owned = wait(lambda: self.adopt_after(pid, before), "new private Safari-only fixture window")[0]
        filename = f"Keyshift-E2E-Safari-{os.getpid()}.txt"
        downloads = Path.home() / "Downloads"
        configured = subprocess.run(["/usr/bin/defaults", "read", "com.apple.Safari", "DownloadsPath"],
                                    text=True, capture_output=True)
        if configured.returncode == 0:
            downloads = Path(configured.stdout.strip()).expanduser()
        output = downloads / filename

        def prepare():
            # Safari hides its downloads control until a download exists. Use a local fixture in the test window.
            path = self.stage / "safari-download.html"
            path.write_text(f"""<!doctype html><title>Keyshift E2E Safari</title>
            <a href="data:text/plain,Keyshift%20E2E%20fixture" download="{filename}">Download E2E fixture</a>""")
            self.s.activate(pid)
            self.s.action(owned, "AXRaise")
            self.s.inject("ctrl+l")
            self.set_focused_text(pid, path.as_uri())
            self.s.inject("return")
            try:
                confirmation = wait(lambda: (lambda w: w if self.find_in(w, r"Yüklenecek dosyayı onaylayın|Confirm",
                    "AXStaticText") and self.find_in(w, re.escape(path.name)) else None)(
                        self.s.window(pid, depth=13, limit=390)), "Safari's fixture-file confirmation", timeout=1.2)
                button = self.find_in(confirmation, r"^(Aç|Open)$", "AXButton")
                if button and button.get("AXEnabled"):
                    self.press(button)
            except AssertionError:
                # A new window that already loaded the file does not show the confirmation.
                pass
            link = wait(lambda: self.find_in_window(pid, r"Download E2E fixture", "AXLink", depth=11),
                        "local Safari download link")
            self.s.action(link)
            try:
                permission = wait(lambda: (lambda w: w if self.find_in(w, r"allow downloads|indirmelere izin") else None)(
                    self.s.window(pid, depth=12, limit=280)), "private Safari fixture download prompt", timeout=1.2)
                allow = self.find_in(permission, r"^(Allow|İzin Ver)$", "AXButton")
                if allow:
                    self.press(allow)
            except AssertionError:
                pass
            try:
                return wait(lambda: output.exists() and output, "unique Safari fixture download", timeout=2)
            except AssertionError:
                return output

        def action(path, start):
            self.fire("ctrl+j")
            pair = self.solid_pair(start, "alt+cmd+l")
            # Safari lists a data: URL download under its `download` name, or as "Unknown" (20 bytes) on some builds.
            match = wait(lambda: self.find_in_window(pid, re.escape(path.name) + r"|^Unknown\b", depth=13, limit=400),
                         "Safari Downloads popover with the local fixture")
            return f"{pair}; {match['AXRole']} {label(match)}"

        try:
            def exercise(_, start):
                try:
                    path = prepare()
                except (RuntimeError, AssertionError):
                    self.dismiss()
                    self.s.activate(pid)
                    path = output
                return action(path, start)
            self.case("Safari downloads", "ctrl+j", "Safari downloads popover opens and lists the fixture", exercise)
            self.dismiss()
        finally:
            output.unlink(missing_ok=True)
            self.close_owned(pid, owned)

    def terminal_text(self, pid):
        tree = self.s.window(pid, depth=10, limit=180)
        fields = [n for n in flatten(tree) if n["AXRole"] in ("AXTextArea", "AXTextField") and n.get("AXValue")]
        return "\n".join(str(n["AXValue"]) for n in fields)

    def terminal_cases(self, identifier, name):
        pid = self.open_app(identifier, name)
        self.remember(pid)
        self.s.activate(pid)
        before = {w["handle"] for w in self.s.windows(pid)}
        self.s.inject("right_cmd+n")
        window = wait(lambda: self.adopt_after(pid, before), f"new {name}-only test window")[0]
        stamp = "KS" + str(os.getpid())
        self.s.call("pasteboard", text="printf '%s%s\\n' " + stamp + "READY")
        self.s.inject("right_cmd+v")
        self.s.inject("return")
        wait(lambda: stamp + "READY" in self.terminal_text(pid), f"{name} text buffer")
        for combo, mapped in [("ctrl+c", "ctrl+c"), ("ctrl+shift+c", "cmd+c"),
                              ("ctrl+shift+v", "cmd+v"), ("ctrl+backspace", "ctrl+w")]:
            def setup():
                self.s.activate(pid)
                self.s.action(window, "AXRaise")
                if combo == "ctrl+c":
                    self.s.call("pasteboard", text=f"sleep 1000; printf '%s%s\\n' {stamp}INT ERRUPTED")
                    self.s.inject("right_cmd+v")
                    self.s.inject("return")
                    def process():
                        output = self.cmd("/bin/ps", "-axo", "pid=,command=").stdout
                        seen = [int(x.split()[0]) for x in output.splitlines() if re.match(r"^\s*\d+\s+sleep 1000$", x)]
                        return next((x for x in seen if x not in sleep_pids), None)
                    return wait(process, "fixture sleep 1000 process")
                if combo == "ctrl+shift+c":
                    self.s.inject("right_cmd+a")
                    self.s.call("pasteboard", text="terminal copy sentinel")
                if combo == "ctrl+shift+v":
                    self.s.call("pasteboard", text=f"printf '%s%s\\n' {stamp}PAS TED")
                if combo == "ctrl+backspace":
                    self.s.call("pasteboard", text=f"printf '%s%s\\n' {stamp}WORD removeThis")
                    self.s.inject("right_cmd+v")
                return None
            sleep_pids = {int(x.split()[0]) for x in self.cmd("/bin/ps", "-axo", "pid=,command=").stdout.splitlines()
                          if re.match(r"^\s*\d+\s+sleep 1000$", x)}
            def action(process, start):
                self.fire(combo)
                pair = self.solid_pair(start, mapped)
                if combo == "ctrl+c":
                    wait(lambda: not self.pid_exists(process), f"fixture sleep PID {process} exits on SIGINT")
                    detail = f"sleep 1000 PID {process} exited after Control+C; terminal buffer tail {self.terminal_text(pid)[-130:]!r}"
                elif combo == "ctrl+shift+c":
                    detail = wait(lambda: (lambda value: value[-140:] if stamp + "READY" in value else None)(
                        self.s.call("pasteboard")), "terminal clipboard includes fixture output")
                else:
                    self.s.inject("return")
                    marker = stamp + ("PASTED" if combo == "ctrl+shift+v" else "WORD")
                    detail = wait(lambda: (lambda value: value[-160:] if re.search(rf"(?m)^{marker}\s*$", value)
                                           else None)(self.terminal_text(pid)), f"shell output {marker}")
                    if combo == "ctrl+backspace":
                        check("removeThis" not in detail.splitlines()[-2] if len(detail.splitlines()) >= 2 else True,
                              "Terminated command retained delete target")
                return f"{pair}; {detail!r}"
            self.case("Terminal interrupt" if combo == "ctrl+c" else "Terminal clipboard", combo,
                      f"{name} produces {mapped} with observable shell or clipboard state", (setup, action), scope=name)
            if combo == "ctrl+c":
                tail = self.terminal_text(pid)
                if f"{stamp}INT ERRUPTED" in tail:
                    self.s.inject("ctrl+c")
        self.close_owned(pid, window)

    @staticmethod
    def pid_exists(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        return True

    def exclusion_cases(self, helper_app):
        import plistlib
        game = self.root / "steamapps/common/FakeGame/FakeGame.app"
        binary = game / "Contents/MacOS/FakeGame"
        marker = game / "Contents/Info.plist"
        game_id = "io.github.ozanhakantunca.keyshift.fixture.game"
        if game.exists():
            check(marker.exists() and plistlib.loads(marker.read_bytes()).get("CFBundleIdentifier") == game_id,
                  "FakeGame path already occupied by another app")
        binary.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(helper_app / "Contents/MacOS/KeyshiftE2E", binary)
        marker.write_bytes(plistlib.dumps({"CFBundleIdentifier": game_id, "CFBundleName": "FakeGame",
                                           "CFBundleExecutable": "FakeGame", "CFBundlePackageType": "APPL"}))
        self.cmd("/usr/bin/codesign", "--force", "--sign", "-", game)
        logfile = self.stage / "game-events.log"
        logfile.touch()
        self.cmd("/usr/bin/open", "-n", "-a", game, "--args", "--game", logfile)
        self.game_pid = wait(lambda: self.s.apps(game_id), "FakeGame process")[0]["pid"]
        for combo in ("ctrl+c", "home", "left_cmd"):
            def setup():
                self.s.activate(self.game_pid)
                return len(logfile.read_text().splitlines())
            def action(after, start):
                self.fire(combo)
                if combo == "left_cmd":
                    flags = wait(lambda: [e for e in self.seen(start)
                                          if e["type"] == 12 and e["key"] == 55], "FakeGame left Command flags")
                    check(len(flags) >= 2, f"Incomplete FakeGame modifier pair: {flags}")
                    time.sleep(0.35)
                    check(not self.owner_windows("Spotlight"), "Spotlight appeared in excluded FakeGame")
                else:
                    self.solid_pair(start, combo)
                code = KEYS[combo.split("+")[-1]]
                logged = wait(lambda: [line for line in logfile.read_text().splitlines()[after:]
                                       if int(line.split()[1]) == code], "FakeGame NSEvent log")
                mods = int(logged[0].split()[2]) & MOD_MASK
                check(mods == (MODS["ctrl"] if combo == "ctrl+c" else MODS["cmd"] if combo == "left_cmd" else 0),
                      f"FakeGame delivered wrong modifiers: {logged}")
                return f"FakeGame at {game}; app NSEvent log {logged}; Spotlight stayed closed"
            self.case("Fake game", combo, "Unchanged direct NSEvent delivery and no Spotlight",
                      (setup, action), baseline="ctrl+c / home / left_cmd tap" if combo == "ctrl+c" else None)
        self.cleanup_game()
        self.fake_browser_cases(helper_app)

        identifier = "com.apple.ScreenSharing"
        def setup_remote():
            apps = self.s.apps(identifier)
            if apps:
                self.remember(apps[0]["pid"])
            self.cmd("/usr/bin/open", "-b", identifier)
            remote = wait(lambda: self.s.apps(identifier), "Screen Sharing application")[0]["pid"]
            self.baseline_windows.setdefault(remote, set())
            self.s.activate(remote)
            self.adopt_after(remote, self.baseline_windows[remote])
            return remote
        def remote_action(pid, start):
            check(self.s.front().get("id") == identifier, "Screen Sharing not frontmost at injection")
            self.fire("ctrl+c")
            return self.solid_pair(start, "ctrl+c") + f"; NSWorkspace frontmost {identifier}, PID {pid}"
        self.case("Screen Sharing exclusion", "ctrl+c", "Screen Sharing receives unchanged Control+C",
                  (setup_remote, remote_action))

    def fake_browser_cases(self, helper_app):
        """Firefox and Opera are not installed. Their rules scope on the frontmost bundle ID, so run a signed
        fixture copy of the helper under each ID and check the real NSEvents it receives (CFBundleIdentifier
        only; the fixture registers nothing else and is unregistered and deleted afterwards)."""
        import plistlib
        lsregister = ("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework"
                      "/Support/lsregister")
        for scenario, bundle, name, mapped in [
            ("Firefox downloads", "org.mozilla.firefox", "FakeFirefox", "shift+cmd+y"),
            ("Opera downloads", "com.operasoftware.Opera", "FakeOpera", "cmd+j"),
        ]:
            app = self.root / "fake-browsers" / f"{name}.app"
            marker = app / "Contents/Info.plist"
            if app.exists():
                check(marker.exists() and plistlib.loads(marker.read_bytes()).get("CFBundleName") == name,
                      f"{app} already occupied by another app")
            check(not self.s.apps(bundle), f"A real app with bundle ID {bundle} is running; refusing to impersonate it")
            binary = app / "Contents/MacOS" / name
            binary.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(helper_app / "Contents/MacOS/KeyshiftE2E", binary)
            marker.write_bytes(plistlib.dumps({"CFBundleIdentifier": bundle, "CFBundleName": name,
                                               "CFBundleExecutable": name, "CFBundlePackageType": "APPL"}))
            self.cmd("/usr/bin/codesign", "--force", "--sign", "-", app)
            logfile = self.stage / f"{name}-events.log"
            logfile.touch()
            pid = None
            try:
                self.cmd("/usr/bin/open", "-n", "-a", app, "--args", "--game", logfile)
                pid = wait(lambda: self.s.apps(bundle), f"{name} process")[0]["pid"]
                def setup():
                    self.s.activate(pid)
                    wait(lambda: self.s.front().get("id") == bundle, f"{name} frontmost", timeout=4)
                    return len(logfile.read_text().splitlines())
                def action(after, start):
                    self.fire("ctrl+j")
                    pair = self.solid_pair(start, mapped)
                    code = KEYS[mapped.split("+")[-1]]
                    want = sum(MODS[m] for m in mapped.split("+")[:-1])
                    logged = wait(lambda: [line for line in logfile.read_text().splitlines()[after:]
                                           if int(line.split()[1]) == code and int(line.split()[2]) & MOD_MASK == want],
                                  f"{name} received {mapped}")
                    return f"{pair}; frontmost {bundle} PID {pid} received NSEvent {logged[0]}"
                self.case(scenario, "ctrl+j", mapped, (setup, action), scope=f"fixture app with bundle ID {bundle}")
            finally:
                if pid:
                    os.kill(pid, signal.SIGTERM)
                    wait(lambda: not self.s.apps(bundle), f"{name} exited", timeout=5)
                self.cmd(lsregister, "-u", app)
                shutil.rmtree(app.parent, ignore_errors=True)

    def cleanup_game(self):
        if self.game_pid and any(a["pid"] == self.game_pid
                for a in self.s.apps("io.github.ozanhakantunca.keyshift.fixture.game")):
            os.kill(self.game_pid, signal.SIGTERM)
        self.game_pid = None

    def cleanup(self):
        if getattr(self, "onboarding_pid", None):
            self.finish_onboarding()
        if self.rfb:
            self.rfb.close()
            self.rfb = None
        self.cleanup_game()
        errors = []
        for pid, handles in self.owned.items():
            for handle in list(handles):
                try:
                    self.close_owned(pid, {"handle": handle})
                    if handle in handles:
                        errors.append(f"Owned AX window {handle} remains for PID {pid}")
                except Exception as error:
                    errors.append(f"AX window {handle} PID {pid}: {error}")
        if getattr(self, "chrome_profile", None):
            for pid in sorted(self.chrome_processes()):
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            try:
                wait(lambda: not self.chrome_processes(), "isolated Chrome process tree exits", timeout=6)
            except AssertionError:
                for pid in self.chrome_processes():
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                wait(lambda: not self.chrome_processes(), "isolated Chrome process tree stopped")
            self.chrome_pid = None
        for path in self.screenshots | self.trash:
            path.unlink(missing_ok=True)
        for directory in self.created_dirs:
            shutil.rmtree(directory)
        if getattr(self, "chrome_profile", None):
            shutil.rmtree(self.chrome_profile)
        if self.baseline_front and self.pid_exists(self.baseline_front):
            try:
                self.s.activate(self.baseline_front)
            except Exception as error:
                errors.append(f"Restore prior front app {self.baseline_front}: {error}")
        return errors

    def ui_tree(self, full=False):
        return self.s.window(self.ui_pid, depth=14, limit=500) if not full else self.s.ax(
            self.ui_pid, target="AXFocusedWindow", depth=14, limit=500, full=True)

    def ui_find(self, pattern, role=None, *, tree=None):
        return self.find_in(tree or self.ui_tree(), pattern, role)

    def ui_press(self, pattern, role=None, *, tree=None):
        item = wait(lambda: self.ui_find(pattern, role, tree=tree), f"Keyshift control {pattern}")
        self.press(item)
        return item

    def press(self, item):
        try:
            self.s.action(item)
        except RuntimeError:
            self.s.click(item)

    def ui_window(self, section=None):
        before = {w["handle"] for w in self.s.windows(self.ui_pid)}
        args = ("open", section) if section else ("open",)
        self.cmd(self.keyshift, *args)
        titles = {"rules": "Rules|Kurallar", "presets": "Presets|Hazır Ayarlar", "apps": "App Groups|Uygulama Grupları",
                  "conflicts": "Conflicts|Çakışmalar", "events": "Event Viewer|Olay Görüntüleyici",
                  "general": "General|Genel", "about": "About|Hakkında"}
        window = wait(lambda: (lambda w: w if not section or re.search(titles[section], label(w), re.I) else None)(
            self.s.window(self.ui_pid)), f"Keyshift settings window {section or 'rules'}")
        baseline = getattr(self, "ui_baseline", before)
        self.adopt_after(self.ui_pid, baseline)
        if window["handle"] in self.owned.get(self.ui_pid, ()) and window["handle"] not in self.original_positions:
            position = window.get("AXPosition")
            if position and position[0] > 200:
                try:
                    self.s.set(window, "AXPosition", [70, 80])
                    self.original_positions[window["handle"]] = position
                except RuntimeError:
                    pass
        return window

    def menu_items(self, pid, pattern, root=None):
        pools = []
        if root:
            try:
                pools.append(self.s.ax(handle=root["handle"], depth=6, limit=135, full=True))
            except RuntimeError:
                pass
        for target in ("AXFocusedUIElement", "AXExtrasMenuBar", "AXFocusedWindow"):
            try:
                pools.append(self.s.ax(pid, target=target, depth=10, limit=250, full=True))
            except RuntimeError:
                pass
        for pool in pools:
            item = self.find_in(pool, pattern, "AXMenuItem")
            if item:
                return item
        return None

    def choose_menu(self, parent, pattern, *, status=False, click=False):
        if status:
            self.s.click(parent)
        else:
            self.press(parent)
        def menu_item():
            node = self.menu_items(self.ui_pid, pattern, parent)
            if not node:
                return None
            return self.s.ax(handle=node["handle"])
        try:
            node = wait(menu_item, f"visible menu item {pattern}", timeout=2)
        except AssertionError:
            if status:
                self.s.action(parent, "AXPress")
            else:
                self.s.click(parent)
            node = wait(menu_item, f"opened menu item {pattern}", timeout=3)
        width, height = node.get("AXSize", [0, 0])
        y = node.get("AXPosition", [0, 2000])[1]
        if (status or click) and width > 0 and height > 0 and 0 <= y < 1380:
            self.s.click(node)
        else:
            self.press(node)
        return node

    def click_on_menu(self, pattern):
        extras = self.s.ax(self.ui_pid, target="AXExtrasMenuBar", depth=4, limit=30)
        item = next((x for x in flatten(extras) if x["AXRole"] == "AXMenuBarItem"
                     and re.search(r"Keyshift", label(x), re.I)), None)
        if not item:
            item = next((x for x in flatten(extras) if x["AXRole"] == "AXMenuBarItem"), None)
        check(item, f"Keyshift status item under AXExtrasMenuBar not found: {extras}")
        return self.choose_menu(item, pattern, status=True)

    def ui_cases(self, doc):
        self.ui_pid = wait(lambda: self.s.apps(KEYSHIFT_ID), "Keyshift GUI PID")[0]["pid"]
        self.remember(self.ui_pid)
        self.ui_baseline = set(self.baseline_windows[self.ui_pid])
        profile = "Profilim" if self.layout.endswith("Turkish-QWERTY-PC") else "My profile"
        rule_name = "Yeni kural" if self.layout.endswith("Turkish-QWERTY-PC") else "New rule"
        original = self.config.read_bytes()

        def pause(_, start):
            self.click_on_menu(r"^(Enabled|Etkin)$")
            try:
                wait(lambda: "Remapping: disabled" in self.cmd(self.keyshift, "status").stdout, "menu pause")
                ready = self.prepare_text(doc, "menu fixture", 0, 4)
                self.s.call("pasteboard", text="menu sentinel")
                phase = self.mark()
                self.fire("ctrl+c")
                paused = self.solid_pair(phase, "ctrl+c")
                check(self.s.call("pasteboard") == "menu sentinel", "Paused Ctrl+C modified clipboard")
                self.click_on_menu(r"^(Enabled|Etkin)$")
                wait(lambda: "Remapping: enabled" in self.cmd(self.keyshift, "status").stdout, "menu resume")
                self.prepare_text(doc, "menu fixture", 0, 4)
                phase = self.mark()
                self.fire("ctrl+c")
                resumed = self.solid_pair(phase, "cmd+c")
                wait(lambda: self.s.call("pasteboard") == "menu", "clipboard responds after menu resume")
                return f"AXExtrasMenuBar toggled pause/resume; paused {paused}, resumed {resumed}; clipboard contains menu"
            finally:
                if "Remapping: enabled" not in self.cmd(self.keyshift, "status").stdout:
                    self.cmd(self.keyshift, "enable")
        self.case("Keyshift menu", "pause / resume; ctrl+c", "Menu toggles live TextEdit copy behavior", pause)
        self.dismiss()

        sections = [
            ("rules", r"Add Rule|Kural Ekle"), ("presets", r"Start from a preset|Hazır ayardan başla"),
            ("apps", r"App Groups|Uygulama Grupları"), ("conflicts", r"macOS|Çakışmalar"),
            ("events", r"You pressed|Press keys|Bastığın tuş|tuşlarla ne yaptığını"),
            ("general", r"Remap keys|Tuşları eşle"), ("about", r"GNU|Keyshift on GitHub|GitHub.da Keyshift"),
        ]
        for section, expected in sections:
            def section_case(_, start):
                window = self.ui_window(section)
                found = wait(lambda: self.ui_find(expected), f"{section} localized AX controls")
                return f"{section} window {label(window)!r}, localized AX element {label(found)!r}"
            self.case("Keyshift settings section", section, "Localized section is visible and captured", section_case)

        def conflicts(_, start):
            self.ui_window("conflicts")
            items = wait(lambda: [label(n) for n in flatten(self.ui_tree())
                              if re.search(r"Move Left a Space|Move Right a Space|also assigned|atanmış", label(n), re.I)
                              and n["AXRole"] == "AXStaticText"], "four informational macOS conflicts")
            items = list(dict.fromkeys(items))
            check(len(items) == 4 and sum("←" in n for n in items) == 2 and sum("→" in n for n in items) == 2,
                  f"Expected four informational Control-arrow rows; found {items}")
            # Spaces moved off Command+arrows, so Home/End (Command+arrows) no longer conflict with them.
            check(not any("⌘" in n or re.search(r"\bcmd\b|command", n, re.I) for n in items),
                  f"Command-arrow conflicts should be gone; found {items}")
            return "; ".join(items)
        self.case("Keyshift conflicts", "open conflicts", "Four informational Control-arrow items (Spaces); none for Command arrows", conflicts)

        def events(_, start):
            self.ui_window("events")
            self.prepare_text(doc, "event fixture", 0, 5)
            self.fire("ctrl+c")
            self.solid_pair(start, "cmd+c")
            self.ui_window("events")
            def output():
                nodes = list(flatten(self.ui_tree()))
                return next(([label(x) for x in flatten(node)] for node in nodes if node["AXRole"] == "AXRow"
                             and "Ctrl shortcuts" in " ".join(label(x) for x in flatten(node))
                             and "⌃" in " ".join(label(x) for x in flatten(node))
                             and "⌘" in " ".join(label(x) for x in flatten(node))), None)
            return f"Event Viewer AXRow {wait(output, 'Ctrl+C → Command+C row')}"
        self.case("Keyshift event viewer and screenshots", "open sections / onboarding / inject",
                  "Event Viewer lists Control+C → Command+C", events)

        def profile_picker():
            return wait(lambda: next((n for n in flatten(self.ui_tree())
                        if n["AXRole"] in ("AXPopUpButton", "AXMenuButton")
                        and re.search(r"Windows|Profilim|My profile", label(n))), None), "profile picker")

        def profile_menu(pattern):
            popup = wait(lambda: next((n for n in flatten(self.ui_tree(full=True))
                        if re.search(r"Profile actions|Profil eylemleri", str(n.get("AXHelp", "")), re.I)), None),
                        "profile actions menu")
            return self.choose_menu(popup, pattern)

        def profiles_create(_, start):
            nonlocal profile
            self.ui_window("rules")
            before = self.config.read_text()
            profile_menu(r"New Empty Profile|Yeni Boş Profil")
            self.ui_press(r"^(Save|Kaydet)$", "AXButton")
            selected = wait(lambda: (lambda match: match[1] if match and match[1] != "Windows" else None)(
                re.search(r"(?m)^profile: (.+)$", self.config.read_text())), "new empty profile selected")
            check(selected not in before and re.search(r"Profilim|My profile", selected, re.I),
                  f"New fixture profile name unexpected: {selected}")
            profile = selected
            return f"AX Save created and selected the fixture profile {profile!r}"
        self.case("Keyshift profiles and presets", "create profile", "AX creates and selects a separate profile",
                  profiles_create, baseline="create / switch / delete / apply")

        def profiles_switch(_, start):
            check(profile in self.config.read_text(), "Fixture profile was not created")
            self.choose_menu(profile_picker(), r"^Windows$")
            wait(lambda: "Profile: Windows" in self.cmd(self.keyshift, "status").stdout, "switch to Windows")
            self.choose_menu(profile_picker(), re.escape(profile))
            wait(lambda: f"Profile: {profile}" in self.cmd(self.keyshift, "status").stdout, "switch to fixture profile")
            return f"AX picker switched Windows → {profile}; Keyshift status confirmed each transition"
        self.case("Keyshift profiles and presets", "switch profile", "AX picker switches both ways", profiles_switch)

        def profiles_delete(_, start):
            check(f"Profile: {profile}" in self.cmd(self.keyshift, "status").stdout,
                  "Refusing to delete a profile other than the fixture")
            profile_menu(rf"(Delete|sil).*(?:{re.escape(profile)})|{re.escape(profile)}.*sil")
            button = wait(lambda: self.ui_find(r"^(Delete Profile|Profili Sil)$", "AXButton"),
                          "fixture profile confirmation button")
            self.s.click(button)
            wait(lambda: profile not in self.config.read_text() and
                 "Profile: Windows" in self.cmd(self.keyshift, "status").stdout, "fixture deleted; Windows active")
            return "Only the fixture profile disappeared from YAML; Windows is active"
        self.case("Keyshift profiles and presets", "delete profile", "Fixture profile disappears, Windows selected", profiles_delete)
        self.dismiss()
        if self.cmd(self.keyshift, "status").stdout.find("Profile: Windows\n") == -1:
            self.cmd(self.keyshift, "profile", "Windows")

        def rule_scope(_, start):
            self.ui_window("rules")
            self.ui_press(r"^(Add Rule|Kural Ekle)$", "AXButton")
            self.ui_press(r"Only in these apps|Yalnızca bu uygulamalarda", "AXRadioButton")
            chooser = wait(lambda: self.ui_find(r"^(Add App|Uygulama Ekle)$"), "Add App menu")
            self.press(chooser)
            picked = wait(lambda: self.menu_items(self.ui_pid, r"^TextEdit$", chooser), "TextEdit in Running Apps")
            item = self.s.ax(handle=picked["handle"])
            if item.get("AXSize", [0, 0])[0] > 0 and item.get("AXPosition", [0, 1480])[1] < 1450:
                self.s.click(item)
            try:
                wait(lambda: not self.ui_find(r"No apps chosen yet|Henüz uygulama seçilmedi"), "TextEdit scope chip", timeout=0.7)
            except AssertionError:
                # Keyboard type selection is available while the SwiftUI menu is tracking.
                for key in "tex":
                    self.s.inject(key, delay=4)
                self.s.inject("return")
                wait(lambda: not self.ui_find(r"No apps chosen yet|Henüz uygulama seçilmedi"), "TextEdit selected from Running Apps")
            self.ui_press(r"^(Create Rule|Kural Oluştur)$", "AXButton")
            wait(lambda: (lambda y: rule_name in y and TEXTEDIT.lower() in y.split(rule_name, 1)[1].lower())(
                self.config.read_text()), f"scoped rule in YAML; tail {self.config.read_text().split(rule_name)[-1][-160:]}")
            return f"Running Apps → {label(picked)!r}; YAML contains {rule_name!r} scoped to {TEXTEDIT}"
        self.case("Keyshift rule editor", "choose running-app scope", "TextEdit selected from Running Apps and saved", rule_scope)

        def rule_button(pattern, role):
            tree = self.s.ax(self.ui_pid, target="AXFocusedWindow", depth=15, limit=1450, full=True)
            for node in flatten(tree):
                if node["AXRole"] != "AXRow":
                    continue
                members = list(flatten(node))
                if not any(rule_name == n.get("AXValue") or rule_name == n.get("AXTitle") for n in members):
                    continue
                return next((child for child in members if child["AXRole"] in role and
                             re.search(pattern, label(child) + " " + str(child.get("AXHelp", "")), re.I)), None)
            return None

        def scroll_to_rule():
            self.s.activate(self.ui_pid)
            focused = self.s.window(self.ui_pid)
            try:
                self.s.action(focused, "AXRaise")
            except RuntimeError:
                pass
            bounds = next((w["kCGWindowBounds"] for w in self.s.call("windows")
                           if w["kCGWindowOwnerPID"] == self.ui_pid and w["kCGWindowBounds"]["Width"] >= 740
                           and w["kCGWindowBounds"]["Height"] >= 500), None)
            check(bounds, "Keyshift Rules window has no visible frame")
            x, y, w, h = (bounds[k] for k in ("X", "Y", "Width", "Height"))
            self.s.call("scroll", x=x + w - 80, y=y + h - 110, delta=-7200)

        def rule_record(_, start):
            current = self.config.read_text()
            if rule_name not in current or TEXTEDIT.lower() not in current.split(rule_name, 1)[1].lower():
                self.dismiss(2)
                try:
                    cancel = self.ui_find(r"^(Cancel|İptal|Vazgeç)$", "AXButton")
                    if cancel:
                        self.press(cancel)
                except RuntimeError:
                    pass
                restore = self.stage / "rule-fixture-restore.yaml"
                restore.write_bytes(original)
                restore.chmod(self.config.stat().st_mode & 0o777)
                restore.replace(self.config)
                self.cmd(self.keyshift, "reload")
                self.ui_window("rules")
                self.ui_press(r"^(Add Rule|Kural Ekle)$", "AXButton")
                self.ui_press(r"^(Create Rule|Kural Oluştur)$", "AXButton")
                wait(lambda: rule_name in self.config.read_text(), "created fixture rule in YAML")
            recorders = lambda: [n for n in flatten(self.ui_tree()) if n["AXRole"] == "AXButton"
                                 and re.search(r"Record keys|Tuşları kaydet", label(n), re.I)]
            try:
                rr = wait(lambda: (lambda v: v if len(v) >= 2 else None)(recorders()), "two recorder buttons", timeout=1.5)
            except AssertionError:
                scroll_to_rule()
                item = wait(lambda: rule_button(r"^(Add Shortcut|Kısayol Ekle)\b", ("AXButton",)), "fixture Add Shortcut")
                self.press(item)
                rr = wait(lambda: (lambda v: v if len(v) >= 2 else None)(recorders()), "two recorder buttons")
            self.press(rr[0])
            raw = self.mark()
            self.fire("ctrl+c")
            self.expect(raw, "ctrl+c")
            wait(lambda: "⌃" in label(recorders()[0]), "recorder captured physical Control+C")
            self.press(recorders()[0])
            self.fire("ctrl+k")
            wait(lambda: "K" in label(recorders()[0]), "Control+K recorded")
            self.press(recorders()[1])
            self.fire("right_cmd+c")
            self.ui_press(r"^(Add|Ekle)$", "AXButton")
            wait(lambda: re.search(r"(?m)^\s*ctrl\+k: cmd\+c$", self.config.read_text()), "mapping written to YAML")
            self.prepare_text(doc, "recorded fixture", 0, 8)
            self.s.call("pasteboard", text="recorder sentinel")
            live = self.mark()
            self.fire("ctrl+k")
            mapped = self.solid_pair(live, "cmd+c")
            wait(lambda: self.s.call("pasteboard") == "recorded", "new live remap copies selection")
            return f"Recorder delivered raw Control+C; YAML ctrl+k: cmd+c; live {mapped} and clipboard recorded"
        self.case("Keyshift rule editor", "record mapping", "Recorder passthrough, YAML write and live scoped copy",
                  rule_record, baseline="record / toggle / choose app")

        def rule_toggle(_, start):
            check(rule_name in self.config.read_text() and re.search(r"(?m)^\s*ctrl\+k: cmd\+c$", self.config.read_text()),
                  "Scoped fixture mapping absent")
            self.ui_window("rules")
            scroll_to_rule()
            disabled = lambda: "enabled: false" in self.config.read_text().split(rule_name, 1)[1]

            def fixture_toggle():
                return rule_button(r"Turn this rule off|Bu kuralı kapat|Etkin|Enabled",
                                   ("AXCheckBox", "AXSwitch", "AXToggle"))

            toggle = fixture_toggle()
            if toggle:
                try:
                    self.s.set(toggle, "AXValue", 0)
                except RuntimeError:
                    pass
                try:
                    wait(disabled, "AX toggle updates saved rule", timeout=0.7)
                except AssertionError:
                    toggle = fixture_toggle()
                    if toggle:
                        try:
                            self.s.click(toggle)
                        except (KeyError, RuntimeError):
                            pass

            if not disabled():
                # SwiftUI can leave lazily rebuilt switches without actionable AX handles.
                # Locate the unique fixture title in the rendered settings window before clicking its switch.
                visible = wait(lambda: next((w for w in self.s.call("windows")
                    if w["kCGWindowOwnerPID"] == self.ui_pid and w["kCGWindowBounds"]["Width"] >= 740
                    and w["kCGWindowBounds"]["Height"] >= 500), None), "visible Rules window")
                image = self.stage / "rule-toggle-fixture.png"

                def title_on_screen():
                    self.s.call("capture", path=str(image), window=visible["kCGWindowNumber"])
                    titles = [row for row in self.s.call("ocr", path=str(image))
                              if " ".join(row["text"].split()).casefold() == rule_name.casefold()]
                    if not titles:
                        scroll_to_rule()
                        return None
                    check(len(titles) == 1, f"Multiple visible rules have the fixture title {rule_name!r}")
                    return titles[0]

                title = wait(title_on_screen, f"scroll to fixture rule {rule_name!r}", timeout=12)
                frame = visible["kCGWindowBounds"]
                if not disabled():
                    self.s.call("inject", steps=[{"x": frame["X"] + frame["Width"] * title["x"] - 60,
                                                  "y": frame["Y"] + frame["Height"] * title["y"] + 12}])
            wait(disabled, "fixture rule enabled: false in YAML")
            self.prepare_text(doc, "disabled fixture", 0, 8)
            self.s.call("pasteboard", text="disabled sentinel")
            phase = self.mark()
            self.fire("ctrl+k")
            self.solid_pair(phase, "ctrl+k")
            check(self.s.call("pasteboard") == "disabled sentinel", "Disabled mapping still copied")
            return "Rule enabled: false in YAML; Control+K delivered unchanged; clipboard unchanged"
        self.case("Keyshift rule editor", "toggle rule", "Disable fixture rule and verify real passthrough", rule_toggle)

        def preset(_, start):
            self.ui_window("presets")
            original_profiles = self.cmd(self.keyshift, "profile").stdout
            self.ui_press(r"^(Add as Profile|Profil Olarak Ekle|Add Again|Yeniden Ekle)$", "AXButton")
            after = wait(lambda: (lambda v: v if v != original_profiles else None)(
                self.cmd(self.keyshift, "profile").stdout), "preset generated a new profile")
            return f"Profile list changed from {original_profiles.strip()!r} to {after.strip()!r}"
        self.case("Keyshift profiles and presets", "apply preset", "Preset adds a new profile through AX", preset)

        def importer(_, start):
            source = Path(os.environ.get("KEYSHIFT_E2E_KARABINER_JSON",
                                         str(Path.home() / ".config/karabiner/karabiner.json"))).expanduser()
            check(source.is_file(), "No karabiner.json to import (set KEYSHIFT_E2E_KARABINER_JSON)")
            chooser_directory = Path.home() / ".config/karabiner"
            check(chooser_directory.is_dir(), "Default chooser directory is unavailable")
            copy = chooser_directory / f"KS-E2E-{os.getpid()}.json"
            original_bytes = source.read_bytes()
            try:
                with copy.open("xb") as stream:
                    stream.write(original_bytes)
                self.ui_window("presets")
                self.ui_press(r"Choose File|Dosya Seç", "AXButton")
                panel = wait(lambda: (lambda w: w if w.get("AXIdentifier") == "open-panel" or
                    self.find_in(w, r"^Vazgeç$|^Cancel$", "AXButton") else None)(
                        self.s.window(self.ui_pid, depth=4)), "file chooser focused")
                try:
                    candidate = wait(lambda: self.find_in_window(self.ui_pid, re.escape(copy.name), depth=14, limit=500),
                                     "unique import copy in AX chooser", timeout=1.1)
                    self.s.click(candidate, count=2)
                except AssertionError:
                    # NSOpenPanel can expose its file columns through a remote view without AX rows.
                    # The cropped chooser confirms the unique fixture filename before clicking.
                    surfaces = [w for w in self.s.call("windows") if w["kCGWindowOwnerPID"] == self.ui_pid
                                and w["kCGWindowBounds"]["Width"] > 400 and w["kCGWindowBounds"]["Height"] > 250]
                    image = self.stage / "karabiner-chooser.png"
                    match = None
                    text = []
                    for window in surfaces:
                        self.s.call("capture", path=str(image), window=window["kCGWindowNumber"])
                        text = self.s.call("ocr", path=str(image))
                        match = next((entry for entry in text if copy.name.lower() in
                                      entry["text"].lower().replace(" ", "")), None)
                        if match:
                            break
                    check(match, f"Exact fixture filename absent from chooser OCR: {[t['text'] for t in text]}")
                    frame = window["kCGWindowBounds"]
                    self.s.call("inject", steps=[{"x": frame["X"] + frame["Width"] * match["x"],
                        "y": frame["Y"] + frame["Height"] * match["y"], "count": 2}])
                summary = wait(lambda: self.ui_find(r"\d+ imported|\d+ içe aktarıldı"), "Karabiner import result")
                check(source.read_bytes() == original_bytes, "Backup changed")
                return f"Imported copy {copy.name}; AX report {label(summary)}; backup byte-identical"
            finally:
                copy.unlink(missing_ok=True)
        self.case("Keyshift Karabiner import", "import copied backup", "Chooser imports copy and reports diagnostics", importer)
        for pattern in (r"Show Rules|Kuralları Göster", r"Cancel|Vazgeç|İptal"):
            try:
                candidate = self.ui_find(pattern, "AXButton")
                if candidate:
                    self.press(candidate)
            except RuntimeError:
                pass
        self.dismiss()

        # Keep onboarding isolated from the running profile and the login-item configuration.
        mode = self.config.stat().st_mode & 0o777
        restore = self.stage / "ui-restore.yaml"
        restore.write_bytes(original)
        restore.chmod(mode)
        restore.replace(self.config)
        self.cmd(self.keyshift, "reload")
        self.s.call("flags")
        try:
            self.case("Keyshift onboarding", "launch with an absent temporary config", "Actual onboarding window and Turkish text",
                      lambda _, start: self.onboarding())
        finally:
            if getattr(self, "onboarding_pid", None):
                self.finish_onboarding()
                self.onboarding_pid = None

    def onboarding(self):
        check(not self.ui_baseline, "Existing user-owned Keyshift settings windows prevent a clean onboarding launch")
        old_pid = self.ui_pid
        for _ in range(3):
            windows = self.s.windows(old_pid)
            if not windows:
                break
            for window in windows:
                if window["handle"] in self.ui_baseline:
                    raise AssertionError("Keyshift has an existing settings window")
                tree = self.s.ax(handle=window["handle"], depth=8, limit=250)
                cancel = self.find_in(tree, r"^(Cancel|Vazgeç|İptal|Show Rules|Kuralları Göster)$", "AXButton")
                if cancel:
                    self.press(cancel)
                try:
                    self.close_owned(old_pid, self.adopt(old_pid, window))
                except RuntimeError:
                    pass
        check(not self.s.windows(old_pid), "Keyshift fixture windows still open after closing the modal and settings")
        app = Path(self.keyshift).parents[2]
        empty = self.stage / "onboarding" / "config.yaml"
        empty.parent.mkdir(exist_ok=True)
        self.click_on_menu(r"Quit Keyshift|Keyshift.ten Çık|Keyshift’i Kapat|Keyshift.*Çık")
        wait(lambda: not self.s.apps(KEYSHIFT_ID), "Keyshift cleanly quits before onboarding")
        self.onboarding_pid = -1
        try:
            self.cmd("/usr/bin/open", "-n", "-a", app, "--env", f"KEYSHIFT_CONFIG={empty}")
            fresh = wait(lambda: self.s.apps(KEYSHIFT_ID), "isolated Keyshift onboarding instance")[0]["pid"]
            self.ui_pid = fresh
            window = wait(lambda: next((w for w in self.s.windows(fresh) if re.search(
                r"Welcome|Hoş Geldin|Hoş geldin", label(w), re.I)), None) or
                (lambda w: w if not w.get("AXTitle") or w.get("AXIdentifier") == "onboarding" else None)(
                    self.s.window(fresh)), "actual onboarding AXWindow")
            self.adopt(fresh, window)
            contents = [label(n) for n in flatten(self.s.ax(handle=window["handle"], depth=12, limit=180))
                        if n["AXRole"] == "AXStaticText"]
            check(contents, "Onboarding has no AX text")
            self.onboarding_pid = fresh
            return f"Temporary config {empty}; real onboarding AX window {label(window)!r}; text {contents[:7]}"
        except Exception:
            self.finish_onboarding()
            self.onboarding_pid = None
            raise

    def finish_onboarding(self):
        for app in self.s.apps(KEYSHIFT_ID):
            self.ui_pid = app["pid"]
            try:
                self.click_on_menu(r"Quit Keyshift|Keyshift.ten Çık|Keyshift’i Kapat|Keyshift.*Çık")
            except (RuntimeError, AssertionError):
                os.kill(self.ui_pid, signal.SIGTERM)
        wait(lambda: not self.s.apps(KEYSHIFT_ID), "isolated onboarding process exits")
        self.cmd("/usr/bin/open", "-g", "-a", Path(self.keyshift).parents[2])
        wait(lambda: "Profile: Windows" in self.cmd(self.keyshift, "status").stdout, "original Keyshift restarts")
