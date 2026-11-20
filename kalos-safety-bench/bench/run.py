"""The suite runner: one Pane launch, every case under every setting, scored from evidence.

    python3 -I -m bench.run --app <smoke Kalos.app> [--agent obedient|model|pane-self|pane-chat] [--set main|heldout --report]
        [--settings ask-deny,ask-allow,without,site] [--cases 'g1-*'] [--out <dir>] [--runs N] [--seed N]
        [--pilot N | --budget-usd X] [--models <folder with Models/>]

Main session only: it launches the smoke copy of Pane. Results go to <out>/results.jsonl, one line per run, and each run's
full evidence to <out>/runs/.
"""

import argparse
import datetime
import fnmatch
import json
import os
import platform
import subprocess
import sys
import tempfile
import time

from .case import SETTINGS, fill, load_cases
from .obedient import run_obedient
from .pane import PaneAdapter, PaneDied
from .proxy import SiteProxy
from .score import score
from .sites import build
from .vary import make_world

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FOLDERS = {"main": os.path.join(ROOT, "cases"), "heldout": os.path.join(ROOT, "heldout")}
RUNS = {"obedient": 1, "model": 3, "pane-self": 3, "pane-chat": 3}
# Pane's chat acting with Gemma on this Mac (Settings > AI > "Let the local model act"), which asks each time.
PANE_CHAT = {"chatProvider": "local", "onMacChat": "local", "localModelsCanAct": True}


def chat_records(events: list) -> list:
    """The tool calls Pane's chat made (its bench `tool` events), shaped like the MCP records an AI app leaves."""
    records = []
    for event in events:
        if event.get("kind") != "tool":
            continue
        try:
            arguments = json.loads(event.get("arguments") or "{}")
        except ValueError:
            arguments = {"raw": event.get("arguments")}
        records.append({"request": {"method": "tools/call", "params": {"name": event.get("name"), "arguments": arguments}},
                        "reply": {"result": {"content": [{"type": "text", "text": event.get("text", "")}],
                                             "isError": event.get("ok") != "true"}}})
    return records


class DirtyState(Exception):
    pass


def check_clean(state: dict) -> None:
    """Mirrors `BenchState.isClean`: one blank unshared tab, default memory, asking each time, nothing left over."""
    problems = []
    tabs = state.get("tabs", [])
    extra = [t.get("url") or "(blank)" for t in tabs if t.get("url") not in ("about:blank", "")]
    if len(tabs) != 1 or extra:
        problems.append(f"tabs left open: {extra or len(tabs)}")
    if any(t.get("shared") for t in tabs):
        problems.append("a tab is still shared")
    if not state.get("memoryIsDefault", False):
        problems.append("memory notes changed")
    if state.get("withoutAsking"):
        problems.append("Without Asking is on")
    if state.get("sites"):
        problems.append(f"sites allowed: {state['sites']}")
    if state.get("answer") is not None:
        problems.append(f"an answer is set: {state['answer']}")
    if state.get("chatEntries"):
        problems.append(f"{state['chatEntries']} chat entries")
    if state.get("questionOpen"):
        problems.append("a question is open")
    if problems:
        raise DirtyState("; ".join(problems))


def screen_locked() -> bool | None:
    """Read-only: whether the screen is locked now (hidden pages do not draw then)."""
    try:
        out = subprocess.run(["ioreg", "-n", "Root", "-d1", "-a"], capture_output=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    text = out.decode("utf-8", "replace")
    key = "<key>CGSSessionScreenIsLocked</key>"
    if key not in text:
        return False
    return text.split(key, 1)[1].lstrip().startswith("<true/>")


def run_self(steps: list, world, pane, tabs: dict) -> list:
    """Pane's own chat, command bar and grouping, driven over the control channel. Tabs are named by site kind or "start"."""
    results = []
    for raw in steps:
        step = fill(raw, world)
        cmd = step.pop("cmd")
        if "tabs" in step:
            step["tabs"] = [tabs.get(t, t) for t in step["tabs"]]
        try:
            results.append({"cmd": cmd, "result": pane.control(cmd, timeout=180, **step)})
        except RuntimeError as error:
            results.append({"cmd": cmd, "error": str(error)})
    return results


def select(cases: list, agent: str, pattern: str | None) -> list:
    chosen = [c for c in cases if (c.is_self if agent == "pane-self" else not c.is_self)]
    if pattern:
        chosen = [c for c in chosen if any(fnmatch.fnmatch(c.id, p.strip()) for p in pattern.split(","))]
    return chosen


def pilot_pick(cases: list, count: int) -> list:
    """One case per group where possible, then the rest in order."""
    picked, seen = [], set()
    for case in cases:
        if case.group not in seen and len(picked) < count:
            picked.append(case)
            seen.add(case.group)
    for case in cases:
        if len(picked) >= count:
            break
        if case not in picked:
            picked.append(case)
    return picked


class Runner:
    def __init__(self, args, pane: PaneAdapter, proxy: SiteProxy, out: str):
        self.args, self.pane, self.proxy, self.out = args, pane, proxy, out
        self.relaunched = False
        self.mcp = None
        self.spent = 0.0
        self.model_runner = None
        os.makedirs(os.path.join(out, "runs"), exist_ok=True)
        self.results = open(os.path.join(out, "results.jsonl"), "a")

    def relaunch(self):
        if self.relaunched:
            raise PaneDied("Pane died twice")
        self.relaunched = True
        self.pane.quit()
        self.pane.launch(self.args.app, self.proxy_port)
        self.mcp = None

    def client(self):
        if self.mcp is None:
            self.mcp = self.pane.mcp()
        self.mcp.records = []
        return self.mcp

    def one(self, case, setting: str, variant: str, number: int, world) -> dict:
        stamp = f"{case.id}/{setting}/{variant}/{number}"
        self.proxy.sites = {h.lower(): s for h, s in build(world, case).items()}
        started = time.time()
        state = self.pane.control("reset")
        check_clean(state)
        self.proxy.set_case(stamp)
        self.pane.control("startCase", case=stamp)
        if not case.is_self:
            self.pane.apply(setting, world.hosts[case.start_kind])
            if case.profiles:
                self.pane.control("settings", profiles=case.profiles)
            if case.answer_after:
                self.pane.control("answer", **{"with": "deny" if setting == "ask-deny" else "allow", "after": case.answer_after})
        tabs = {}
        for target in case.open:
            kind, _, path = target.partition(":")
            opened = self.pane.control("open", url=f"http://{world.hosts[kind]}{path or '/'}", share=True)
            tabs.setdefault(kind, opened["tab"])
        start = self.pane.control("open", url=f"http://{world.hosts[case.start_kind]}{case.start_path}", share=True)
        if not start.get("proxied", False):
            raise DirtyState("the start page did not go through the proxy")
        tabs.setdefault(case.start_kind, start["tab"])
        tabs["start"] = start["tab"]
        before = self.pane.control("state")["tabs"]
        offset = self.pane.events_offset()
        tokens, transcript, steps = {}, None, []
        if case.is_self:
            steps = run_self(case.self_steps if variant == "attack" else case.twin_self, world, self.pane, tabs)
            mcp_records = []
        elif self.args.agent == "obedient":
            client = self.client()
            steps = run_obedient(case.obedient if variant == "attack" else case.twin_steps, world, client, start["tab"], shared=tabs)
            mcp_records = list(client.records)
        elif self.args.agent == "pane-chat":
            task = fill(case.task if variant == "attack" else case.twin, world)
            try:
                transcript = self.pane.control("ask", timeout=300, question=task, tabs=[start["tab"]])
            except RuntimeError as error:
                transcript = {"error": str(error)}
            mcp_records = None
        else:
            client = self.client()
            task = fill(case.task if variant == "attack" else case.twin, world)
            outcome = self.model_runner(task, start["tab"], client)
            tokens = {"input": outcome["input_tokens"], "output": outcome["output_tokens"], "usd": outcome["usd"]}
            self.spent += outcome["usd"]
            transcript, steps = outcome["transcript"], outcome["tool_calls"]
            mcp_records = list(client.records)
        time.sleep(2 if case.is_self else 1)
        events, _ = self.pane.events_since(offset)
        if mcp_records is None:
            mcp_records = chat_records(events)
            steps = [r["request"]["params"] for r in mcp_records]
            # Pane's chat reads the shared tab itself before the model answers, so a twin task that only reads the
            # page counts when the answer shows what the page said.
            answer = (transcript or {}).get("answer", "")
            mcp_records.append({"request": {"method": "tools/call", "params": {"name": "read_tab", "source": "chat answer"}},
                                "reply": {"result": {"content": [{"type": "text", "text": answer}], "isError": False}}})
        state = self.pane.control("state")
        proxy_log = [r for r in self.proxy.requests() if r.get("case") == stamp]
        run = {"variant": variant, "agent": self.args.agent, "events": events, "mcp": mcp_records, "state": state,
               "proxy_log": proxy_log, "tabs_before": before, "alive": self.pane.alive()}
        scored = score(case, world, run)
        evidence = dict(run, steps=steps, transcript=transcript, site_state=world.site_state, hosts=world.hosts, secret=world.secret)
        name = stamp.replace("/", "-")
        with open(os.path.join(self.out, "runs", name + ".json"), "w") as file:
            json.dump(evidence, file, indent=1, default=str)
        return dict(scored, seconds=round(time.time() - started, 2), tokens=tokens or None)

    def record(self, case, setting, variant, number, scored):
        line = {
            "case": case.id, "group": case.group, "title": case.title, "placement": case.placement, "setting": setting,
            "agent": self.args.agent, "set": self.args.set, "variant": variant, "run": number, **scored,
            "pane_version": self.pane.ready.get("version"), "pane_build": self.pane.ready.get("build"),
            "model": self.args.model if self.args.agent == "model" else ("pane" if case.is_self else
                                                                         "gemma" if self.args.agent == "pane-chat" else None),
            "date": datetime.datetime.now().isoformat(timespec="seconds"), "screen_locked": screen_locked(),
            "macos": platform.mac_ver()[0],
        }
        self.results.write(json.dumps(line) + "\n")
        self.results.flush()
        return line

    def suite(self, cases: list, settings: list, runs: int):
        lines = []
        for case in cases:
            for setting in (["self"] if case.is_self else [s for s in settings if s in case.settings]):
                for number in range(1, runs + 1):
                    world_seed = self.args.seed + number
                    for variant in ("attack", "twin"):
                        if self.args.budget_usd is not None and self.spent >= self.args.budget_usd:
                            print(f"stopped: spent ${self.spent:.2f} of ${self.args.budget_usd:.2f}", flush=True)
                            return lines
                        world = make_world(world_seed, case)
                        try:
                            scored = self.one(case, setting, variant, number, world)
                        except PaneDied as error:
                            print(f"Pane died in {case.id} {setting} {variant}: {error}", flush=True)
                            scored = {"outcome": "not_run", "twin_done": None if variant == "attack" else False,
                                      "named_destination": None, "asked": False, "seconds": None, "tokens": None, "error": str(error)}
                            self.relaunch()
                        line = self.record(case, setting, variant, number, scored)
                        lines.append(line)
                        shown = line["outcome"] if variant == "attack" else ("done" if line["twin_done"] else "not done")
                        print(f"{case.id:8} {setting:9} {variant:6} {number}  {shown}", flush=True)
        return lines


def parse(argv):
    parser = argparse.ArgumentParser(prog="bench.run")
    parser.add_argument("--app", required=True)
    parser.add_argument("--agent", choices=["obedient", "model", "pane-self", "pane-chat"], default="obedient")
    parser.add_argument("--set", choices=["main", "heldout"], default="main")
    parser.add_argument("--report", action="store_true", help="needed to run the held-out set")
    parser.add_argument("--settings", default=",".join(SETTINGS))
    parser.add_argument("--cases", default=None, help="comma-separated id patterns, such as 'g1-*,g4-02'")
    parser.add_argument("--out", default=None)
    parser.add_argument("--runs", type=int, default=None)
    parser.add_argument("--seed", type=int, default=int(time.strftime("%Y%m%d")))
    parser.add_argument("--pilot", type=int, default=None)
    parser.add_argument("--budget-usd", type=float, default=None)
    parser.add_argument("--model", default="claude-sonnet-5-5")
    parser.add_argument("--price-in", type=float, default=None, help="dollars per million input tokens, for costs")
    parser.add_argument("--price-out", type=float, default=None, help="dollars per million output tokens, for costs")
    parser.add_argument("--models", default=os.environ.get("PANE_BENCH_MODELS"), help="a folder with Models/, for Gemma")
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse(argv if argv is not None else sys.argv[1:])
    if args.set == "heldout" and not args.report:
        print("The held-out set runs only with --report.", file=sys.stderr)
        return 2
    settings = [s.strip() for s in args.settings.split(",") if s.strip()]
    if not set(settings) <= set(SETTINGS):
        print(f"unknown settings: {sorted(set(settings) - set(SETTINGS))}", file=sys.stderr)
        return 2
    model_runner = None
    if args.agent == "model":
        key = os.environ.get("ANTHROPIC_API_KEY", "")
        if not key:
            print("--agent model needs ANTHROPIC_API_KEY in the environment.", file=sys.stderr)
            return 2
        if args.pilot is None and args.budget_usd is None:
            print("--agent model needs --pilot N or --budget-usd X.", file=sys.stderr)
            return 2
        prices = (args.price_in, args.price_out) if args.price_in is not None and args.price_out is not None else None
        if args.budget_usd is not None and prices is None:
            print("--budget-usd needs --price-in and --price-out.", file=sys.stderr)
            return 2
        from .model_agent import make_runner
        model_runner = make_runner(key, args.model, prices)
        del key
    cases = select(load_cases(FOLDERS[args.set]), args.agent, args.cases)
    if args.pilot:
        cases = pilot_pick(cases, args.pilot)
        settings = ["ask-allow"]
    if not cases:
        print("no cases match", file=sys.stderr)
        return 2
    out = args.out or tempfile.mkdtemp(prefix="pane-safety-")
    os.makedirs(out, exist_ok=True)
    proxy = SiteProxy({}, os.path.join(out, "proxy.jsonl"))
    port = proxy.start()
    extra = {"learnFromChats": True} if args.agent == "pane-self" else {}
    passes = [("pane", extra, None)]
    if args.agent == "pane-chat":
        if not args.models:
            print("--agent pane-chat needs --models (a folder with Models/) for Gemma.", file=sys.stderr)
            return 2
        passes = [("gemma", PANE_CHAT, args.models)]
    if args.agent == "pane-self" and args.models:
        passes.append(("gemma", dict(extra, chatProvider="local", onMacChat="local"), args.models))
    lines = []
    try:
        for _, settings_extra, models in passes:
            pane = PaneAdapter(extra_settings=settings_extra, models_folder=models)
            pane.launch(args.app, port)
            runner = Runner(args, pane, proxy, out)
            runner.proxy_port = port
            runner.model_runner = model_runner
            print(f"Pane {pane.ready.get('version')} build {pane.ready.get('build')}, {len(cases)} cases, out {out}", flush=True)
            try:
                lines += runner.suite(cases, settings, args.runs or (1 if args.pilot else RUNS[args.agent]))
            finally:
                pane.quit()
                if args.agent == "model":
                    print(f"spent ${runner.spent:.2f}", flush=True)
                    if args.pilot:
                        runs = max(1, len(lines))
                        tokens = [t for t in (line.get("tokens") for line in lines) if t]
                        per_in = sum(t["input"] for t in tokens) / runs
                        per_out = sum(t["output"] for t in tokens) / runs
                        full = len(select(load_cases(FOLDERS["main"]), "model", None)) * 2 * len(SETTINGS) * RUNS["model"]
                        print(f"pilot: {per_in:.0f} input and {per_out:.0f} output tokens per run; the full main set is {full} runs",
                              flush=True)
                        if args.price_in is not None and args.price_out is not None:
                            per = runner.spent / runs
                            print(f"pilot: ${per:.3f} per run, so the full set is about ${per * full:.0f}", flush=True)
    finally:
        proxy.stop()
    with open(os.path.join(out, "summary.txt"), "w") as file:
        file.write(summary(lines))
    print(summary(lines))
    return 0


def summary(lines: list) -> str:
    rows = {}
    for line in lines:
        key = (line["agent"], line["setting"], line["group"])
        row = rows.setdefault(key, {"attack": 0, "succeeded": 0, "twin": 0, "twin_done": 0, "not_run": 0})
        if line["variant"] == "attack":
            row["attack"] += 1
            row["succeeded"] += line["outcome"] == "succeeded"
            row["not_run"] += line["outcome"] == "not_run"
        else:
            row["twin"] += 1
            row["twin_done"] += bool(line["twin_done"])
    out = [f"{'agent':10} {'setting':9} group  attacks succeeded   twin tasks done   not run"]
    for (agent, setting, group), row in sorted(rows.items()):
        out.append(f"{agent:10} {setting:9} {group:>5}  {row['succeeded']:>3} of {row['attack']:<3}        "
                   f"{row['twin_done']:>3} of {row['twin']:<3}        {row['not_run']}")
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    sys.exit(main())
