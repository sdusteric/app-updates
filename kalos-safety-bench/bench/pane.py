"""Launches the smoke copy of Pane in bench mode and drives its control channel.

Only the smoke bundle (`dev.sdusteric.kalos.smoke`) with `PANE_EPHEMERAL=1` and its own temp `PANE_HOME` is ever launched,
and it is stopped by its PID.
"""

import json
import os
import shutil
import signal
import subprocess
import tempfile
import time

from .mcp import LineClient, MCPClient

SETTINGS = {
    "aiAppsCanReadSharedTabs": True,
    "aiAppsCanAct": True,
    # Every tool an app can be given, from launch: turning this on later restarts the connector under a run.
    "aiAppsCanSearchHistory": True,
    "aiActionsWithoutAsking": False,
    "aiActionSites": [],
    # Nothing a case does may leave notes behind for the next one, or open a sheet in the hidden window.
    "learnFromChats": False,
    "offerToSavePasswords": False,
    "restoreTabs": False,
    "automaticUpdates": False,
}


class PaneDied(Exception):
    pass


class PaneAdapter:
    def __init__(self, extra_settings: dict | None = None, models_folder: str | None = None):
        self.extra_settings = extra_settings or {}
        self.models_folder = models_folder
        self.home = None
        self.app = None
        self.pid = None
        self.ready = {}
        self._control = None
        self._next = 0

    def launch(self, app: str, proxy_port: int, timeout: float = 60) -> None:
        self.app = os.path.abspath(app)
        self.home = tempfile.mkdtemp(prefix="pane-bench-")
        settings = dict(SETTINGS, **self.extra_settings)
        with open(os.path.join(self.home, "settings.json"), "w") as file:
            json.dump(settings, file)
        if self.models_folder:
            os.symlink(os.path.join(self.models_folder, "Models"), os.path.join(self.home, "Models"))
        # PANE_SMOKE_OWNER: the copy quits by itself within seconds if the bench is killed (`SmokeLeash`).
        env = {"PANE_HOME": self.home, "PANE_NO_UPDATES": "1", "PANE_EPHEMERAL": "1", "PANE_BENCH": "1",
               "PANE_BENCH_PROXY": str(proxy_port), "PANE_SMOKE_OWNER": str(os.getpid())}
        # Chat's local model only looks at tabs in Kalos; the bench measures it acting, so it gets every tool here.
        if self.models_folder:
            env["PANE_BENCH_LOCAL_ACTS"] = "1"
        command = ["open", "-g", "-n"]
        for key, value in env.items():
            command += ["--env", f"{key}={value}"]
        # English interface, so the questions the bench records read the same whatever language the Mac is in.
        subprocess.run(command + [self.app, "--args", "-AppleLanguages", "(en)"], check=True)
        ready = os.path.join(self.home, "bench.ready")
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.pid = self.pid or self._find_pid()
            if os.path.exists(ready):
                time.sleep(0.2)
                with open(ready) as file:
                    self.ready = json.load(file)
                self._control = LineClient(self.ready["control"])
                return
            time.sleep(0.25)
        self.quit()
        raise PaneDied(f"no bench.ready within {timeout:.0f} s")

    def _find_pid(self):
        # The executable is Kalos since the rename; older bundles named it Pane.
        for name in ("Kalos", "Pane"):
            binary = os.path.join(self.app, "Contents", "MacOS", name)
            found = subprocess.run(["pgrep", "-n", "-f", binary], capture_output=True, text=True).stdout.split()
            if found:
                return int(found[0])
        return None

    def control(self, cmd: str, timeout: float = 150, **fields) -> dict:
        self._next += 1
        try:
            reply = self._control.call(dict(fields, id=self._next, cmd=cmd), timeout)
        except (OSError, ValueError) as error:
            raise PaneDied(f"{cmd}: {error}") from error
        if not reply.get("ok"):
            raise RuntimeError(f"{cmd}: {reply.get('error')}")
        return reply.get("result", {})

    def mcp(self) -> MCPClient:
        client = MCPClient(self.ready["mcp"])
        client.initialize("Claude")
        return client

    def events_since(self, offset: int) -> tuple:
        path = os.path.join(self.home, "bench-events.jsonl")
        if not os.path.exists(path):
            return [], offset
        with open(path, "rb") as file:
            file.seek(offset)
            data = file.read()
        complete = data[: data.rfind(b"\n") + 1]
        events = [json.loads(line) for line in complete.splitlines() if line.strip()]
        return events, offset + len(complete)

    def events_offset(self) -> int:
        path = os.path.join(self.home, "bench-events.jsonl")
        return os.path.getsize(path) if os.path.exists(path) else 0

    def alive(self) -> bool:
        if not self.pid:
            return False
        try:
            os.kill(self.pid, 0)
            return True
        except OSError:
            return False

    def apply(self, setting: str, start_host: str):
        if setting == "ask-deny":
            self.control("answer", **{"with": "deny"})
        elif setting == "ask-allow":
            self.control("answer", **{"with": "allow"})
        elif setting == "without":
            self.control("settings", withoutAsking=True)
            self.control("answer", **{"with": "allow"})
        elif setting == "site":
            self.control("settings", sites=[start_host])
            self.control("answer", **{"with": "allow"})
        else:
            raise ValueError(f"unknown setting {setting}")

    def quit(self) -> None:
        if self._control:
            self._control.close()
        pid = self.pid or (self._find_pid() if self.app else None)
        if pid:
            try:
                os.kill(pid, signal.SIGTERM)
                for _ in range(40):
                    os.kill(pid, 0)
                    time.sleep(0.25)
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        self.pid = None
        if self.home:
            shutil.rmtree(self.home, ignore_errors=True)
            self.home = None
