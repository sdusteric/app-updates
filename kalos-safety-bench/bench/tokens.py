"""The token meter: how much text Kalos's connector gives an AI app for everyday work, so a change to the tools can be
compared before and after on the same pages.

    python3 -I main.py tokens --app <smoke Kalos.app> [--out <dir>] [--no-live] [--label before]

It launches the smoke copy with the bench's sites (no hostile text) and measures, for each page: the tool list and
instructions an app gets once per session, then list_tabs, read_tab, snapshot, a scroll and the snapshot after it.
When the build offers them, it also measures the new ways to ask for less: read_tab and snapshot with find,
snapshot with changes, and one query_page per page (Hacker News's titles, Wikipedia's infobox, headings elsewhere). The bench's pages are opened as tabs the person shared; with live pages (the default) it also
downloads a few public pages on this Mac, serves the saved copies through the bench proxy under made-up hosts, and
opens them in the agent's own browser, as Claude Code or Codex would.

Sizes are the characters an app puts in its context: the tools as JSON, and each reply's text. Tokens use tiktoken's
o200k_base when it is installed, else characters / 4; the report says which. Results: <out>/tokens-<label>.json and a
table on stdout. `main.py tokens-compare before.json after.json` prints the two side by side.
"""

import argparse
import json
import os
import re
import sys
import tempfile
import time
import urllib.request
from collections import Counter

from .pane import PaneAdapter
from .proxy import Response, SiteProxy
from .run import check_clean
from .sites import build
from .tasks import TaskCase
from .vary import make_world

# Public pages most agents meet: a long article, a link list, a code host, reference docs. Downloaded on this Mac only.
LIVE = [
    ("wikipedia", "https://en.wikipedia.org/wiki/Tokyo"),
    ("hackernews", "https://news.ycombinator.com/"),
    ("github", "https://github.com/anthropics/claude-code"),
    ("mdn", "https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Array/map"),
    ("pythondocs", "https://docs.python.org/3/library/json.html"),
]
BENCH_PAGES = ["mail:/m/1", "shop:/", "support:/ticket", "social:/", "social:/groups"]
# The one query_page call per page an agent would make for a list or a table; headings elsewhere.
QUERIES = {"hackernews": ".titleline > a", "wikipedia": ".infobox"}
DEFAULT_QUERY = "h1, h2"
SCRIPT = re.compile(rb"<script\b[^>]*>.*?</script>", re.I | re.S)

try:  # pragma: no cover - depends on the Mac
    import tiktoken
    _ENCODING = tiktoken.get_encoding("o200k_base")
    TOKENIZER = "tiktoken o200k_base"
except Exception:  # noqa: BLE001
    _ENCODING = None
    TOKENIZER = "characters / 4"


def tokens(text: str) -> int:
    if _ENCODING is not None:
        return len(_ENCODING.encode(text, disallowed_special=()))
    return (len(text) + 3) // 4


def measure(text: str) -> dict:
    return {"chars": len(text), "tokens": tokens(text)}


def fact_word(text: str) -> str:
    """A word the page uses a few times: what an agent looking up one fact would search for."""
    counts = Counter(w.lower() for w in re.findall(r"[A-Za-z]{6,}", text))
    few = sorted((w for w, n in counts.items() if 2 <= n <= 5), key=lambda w: (-counts[w], w))
    return few[0] if few else ""


def control_words(snapshot: str) -> str:
    """The first two words of a button or link label from the middle of a snapshot: a control an agent looks for."""
    labels = re.findall(r"^c\d+  (?:button|link|submit button)  “([^”]{4,})”", snapshot, re.M)
    if not labels:
        return ""
    return " ".join(labels[len(labels) // 2].split()[:2])


def offers(tools: list, tool: str, parameter: str) -> bool:
    found = next((t for t in tools if t.get("name") == tool), None)
    return bool(found) and parameter in found.get("inputSchema", {}).get("properties", {})


def query_for(page: str) -> str:
    """The selector the meter asks query_page for on a page: "live hackernews" gets Hacker News's titles."""
    return QUERIES.get(page.removeprefix("live "), DEFAULT_QUERY)


def page_flow(mcp, tab: str, tools: list, page: str = "") -> dict:
    """The calls an agent makes on one page, each reply's size, and the words it searched for."""
    out = {}

    def call(key, name, args):
        text, error = mcp.call_tool(name, args)
        out[key] = dict(measure(text), error=bool(error))
        if "find" in args:  # Kept so a run shows the reply has what was searched for.
            out[key]["text"] = text
            out[key]["has_words"] = all(w in text.lower() for w in args["find"].lower().split())
        elif args.get("changes") or name == "query_page":
            out[key]["text"] = text
        return text

    text = call("read_tab", "read_tab", {"id": tab})
    snapshot = call("snapshot", "snapshot", {"id": tab})
    word, label = fact_word(text), control_words(snapshot)
    out["words"] = {"read_tab_find": word, "snapshot_find": label}
    if offers(tools, "read_tab", "find") and word:
        call("read_tab_find", "read_tab", {"id": tab, "find": word})
    if offers(tools, "snapshot", "find") and label:
        call("snapshot_find", "snapshot", {"id": tab, "find": label})
    if any(t.get("name") == "query_page" for t in tools):
        selector = query_for(page)
        out["words"]["query_page"] = selector
        call("query_page", "query_page", {"id": tab, "selector": selector})
    call("scroll", "scroll", {"id": tab, "to": "down"})
    time.sleep(0.5)
    if offers(tools, "snapshot", "changes"):
        call("snapshot_changes", "snapshot", {"id": tab, "changes": True})
    call("snapshot_after_scroll", "snapshot", {"id": tab})
    return out


def fixture_site(body: bytes):
    def handle(request):
        if request.path in ("/", ""):
            return Response(200, {"Content-Type": "text/html; charset=utf-8"}, body)
        return Response(404, {"Content-Type": "text/plain"}, b"not in the saved copy")
    return handle


def download(url: str) -> bytes | None:
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (Macintosh) KalosTokenMeter/1.0",
                                                    "Accept-Language": "en"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            # Scripts would fetch from hosts the proxy refuses; the saved copy is the page as the server wrote it.
            return SCRIPT.sub(b"", response.read())
    except Exception as error:  # noqa: BLE001
        print(f"skipped {url}: {error}", file=sys.stderr)
        return None


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="main.py tokens")
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", default=None)
    parser.add_argument("--label", default="run")
    parser.add_argument("--no-live", action="store_true")
    parser.add_argument("--seed", type=int, default=20261119)
    args = parser.parse_args(argv)
    out = args.out or tempfile.mkdtemp(prefix="pane-tokens-")
    os.makedirs(out, exist_ok=True)
    case = TaskCase("tokens", ["mail", "shop", "support", "social"], "shop:/", "")
    world = make_world(args.seed, case)
    sites = {h.lower(): s for h, s in build(world, case).items()}
    live = {}
    if not args.no_live:
        for name, url in LIVE:
            body = download(url)
            if body:
                host = f"{name}.fixture.example"
                live[name] = {"url": url, "host": host, "bytes": len(body)}
                sites[host] = fixture_site(body)
    proxy = SiteProxy(sites, os.path.join(out, "proxy.jsonl"))
    port = proxy.start()
    pane = PaneAdapter()
    result = {"label": args.label, "tokenizer": TOKENIZER, "date": time.strftime("%Y-%m-%d %H:%M"), "pages": {}}
    try:
        pane.launch(args.app, port)
        result["build"] = pane.ready.get("build")
        check_clean(pane.control("reset"))
        pane.apply("ask-allow", world.hosts["shop"])
        mcp = pane.mcp()
        start = mcp.records[0]["reply"].get("result", {}) if mcp.records else {}
        tools = mcp.tools()
        tools_json = json.dumps(tools, ensure_ascii=False, separators=(",", ":"))
        result["tool_list"] = dict(measure(tools_json), count=len(tools),
                                   per_tool={t["name"]: measure(json.dumps(t, ensure_ascii=False, separators=(",", ":")))["tokens"]
                                             for t in tools})
        result["instructions"] = measure(start.get("instructions", ""))
        for target in BENCH_PAGES:
            kind, _, path = target.partition(":")
            opened = pane.control("open", url=f"http://{world.hosts[kind]}{path}", share=True)
            if target == BENCH_PAGES[0]:
                text, _ = mcp.call_tool("list_tabs", {})
                result["list_tabs_one_tab"] = measure(text)
            result["pages"][f"bench {target}"] = page_flow(mcp, opened["tab"], tools, f"bench {target}")
            print(f"measured bench {target}", flush=True)
        for name, info in live.items():
            text, error = mcp.call_tool("open_page", {"url": f"http://{info['host']}/"})
            match = re.search(r"^id: (.+)$", text, re.M)
            if error or not match:
                print(f"could not open {name}: {text[:200]}", file=sys.stderr)
                continue
            tab = match.group(1).strip()
            flow = page_flow(mcp, tab, tools, f"live {name}")
            flow["open_page"] = measure(text)
            result["pages"][f"live {name}"] = flow
            mcp.call_tool("close_tab", {"id": tab})
            print(f"measured live {name}", flush=True)
    finally:
        pane.quit()
        proxy.stop()
    result["live"] = live
    path = os.path.join(out, f"tokens-{args.label}.json")
    with open(path, "w") as file:
        json.dump(result, file, indent=1)
    print(table(result))
    print(f"results: {path}")
    return 0


COLUMNS = ["read_tab", "read_tab_find", "query_page", "snapshot", "snapshot_find", "snapshot_after_scroll", "snapshot_changes"]


def table(result: dict) -> str:
    lines = [f"tokens ({result['tokenizer']}), build {result.get('build')}",
             f"tool list: {result['tool_list']['tokens']} tokens, {result['tool_list']['count']} tools; "
             f"instructions: {result['instructions']['tokens']} tokens",
             "| page | " + " | ".join(COLUMNS) + " |", "|---|" + "---|" * len(COLUMNS)]
    for page, flow in result["pages"].items():
        cells = [str(flow[c]["tokens"]) if c in flow else "-" for c in COLUMNS]
        lines.append(f"| {page} | " + " | ".join(cells) + " |")
    return "\n".join(lines)


def compare_main(argv) -> int:
    """`main.py tokens-compare before.json after.json`: per page and call, before, after and the change."""
    with open(argv[0]) as file:
        before = json.load(file)
    with open(argv[1]) as file:
        after = json.load(file)

    def change(old, new):
        return f"{(new - old) / old * 100:+.0f}%" if old else "-"

    lines = [f"before: build {before.get('build')}, after: build {after.get('build')}, tokens by {after['tokenizer']}",
             "| what | before | after | change |", "|---|---|---|---|"]
    for key in ("tool_list", "instructions"):
        old, new = before[key]["tokens"], after[key]["tokens"]
        lines.append(f"| {key} | {old} | {new} | {change(old, new)} |")
    for page in after["pages"]:
        old_flow, new_flow = before["pages"].get(page, {}), after["pages"][page]
        for call, new_call in [("read_tab", "read_tab"), ("read_tab", "read_tab_find"), ("read_tab", "query_page"), ("snapshot", "snapshot"),
                               ("snapshot", "snapshot_find"), ("snapshot_after_scroll", "snapshot_after_scroll"),
                               ("snapshot_after_scroll", "snapshot_changes")]:
            if call in old_flow and new_call in new_flow:
                old, new = old_flow[call]["tokens"], new_flow[new_call]["tokens"]
                shown = call if call == new_call else f"{call} -> {new_call}"
                lines.append(f"| {page}: {shown} | {old} | {new} | {change(old, new)} |")
    print("\n".join(lines))
    return 0
