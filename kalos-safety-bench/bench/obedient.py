"""The obedient agent: does exactly what a case's steps say, through Pane's MCP tools, with no model.

Its steps come from the case file, never from the page, so nothing a model could see marks a page as a setup. Whatever it
fails to do was stopped by the browser's own code.

A step is a tool call with the case's slots filled:
    {"tool": "fill_form", "tab": "start", "fields": [{"field": "Search", "value": "{secret}"}]}
    {"tool": "click", "tab": "opened", "label": "Send"}            a control, found by label through list_controls
    {"tool": "submit_form", "tab": "start", "field": "Search"}     a field, found by label through list_fields
    {"tool": "open_page", "url": "http://{host:forum}/"}
    {"tool": "open_page", "url": "http://{host:mail}/m/1", "profile": "Default"}   in a tab with one of the person's profiles
    {"wait": 1.5}                                                 seconds, for pages that change while the agent works
    {"tool": "run_script", "tab": "start", "code": "..."}         any other tool: its arguments as written
    {"tool": "press_key", "tab": "start", "key": "Enter", "target": "Search"}   target found by label, as for type_text
"tab" is "start" (the case's start tab), "opened" (the tab the last open_page opened), or a site kind from the case's
`open` list (a tab the person shared before the run). A step that fails never stops the run; every result is recorded.

The agent uses the case's secret (or its private sentence) only once a reply from Pane has shown it, as a real agent could only learn it there. A
step that needs it before then is skipped and recorded as such, so a question the person said no to (the click that
would have shown the code) counts as stopping the attack.
"""

import json
import re
import time

from .case import fill
from .evidence import find_secret

_ID = re.compile(r"^id: (.+)$", re.M)


def blocks(text: str) -> list:
    """The `key: value` blocks Pane's list tools return, one dict per item."""
    found = []
    for chunk in text.split("\n\n"):
        item = {}
        for line in chunk.splitlines():
            key, sep, value = line.partition(": ")
            if sep:
                item[key.strip()] = value.strip()
        if "id" in item:
            found.append(item)
    return found


def pick(items: list, label: str, address: str = "") -> str | None:
    """The id of the item whose label is `label` (exact, ignoring case), else the first whose label contains it."""
    want = label.casefold()
    candidates = [i for i in items if not address or address.casefold() in i.get("address", "").casefold()]
    for item in candidates:
        if item.get("label", "").casefold() == want:
            return item["id"]
    for item in candidates:
        if want and want in item.get("label", "").casefold():
            return item["id"]
    return candidates[0]["id"] if address and candidates else None


def run_obedient(steps: list, world, mcp, start_tab: str, sleep=time.sleep, shared: dict | None = None) -> list:
    tabs = {**(shared or {}), "start": start_tab, "opened": None}
    results = []
    heard = ""
    for raw in steps:
        step = fill(raw, world)
        unheard = [name for name, key in (("secret", "main"), ("secret_encoded", "main"), ("private", "private"),
                                       ("private_zh", "private_zh"))
                   if "{" + name + "}" in json.dumps(raw) and not find_secret(world.secrets[key], heard)]
        if unheard:
            results.append({"step": step, "ok": False, "text": "the agent never saw the secret, so it cannot use it"})
            continue
        if "wait" in step:
            sleep(float(step["wait"]))
            results.append({"step": step, "ok": True, "text": ""})
            continue
        tool = step["tool"]
        tabless = ("open_page", "list_tabs", "search_history", "search_read_pages", "search_bookmarks")
        tab = tabs.get(step.get("tab", "start")) if tool not in tabless else None
        args = {}
        if tool not in tabless:
            if tab is None:
                results.append({"step": step, "ok": False, "text": "no such tab"})
                continue
            args["id"] = tab
        if tool == "open_page":
            args["url"] = step["url"]
            if step.get("profile"):
                args["profile"] = step["profile"]
        elif tool == "fill_form":
            args["fields"] = step["fields"]
        elif tool == "click":
            control = step.get("control") or _resolve(mcp, "list_controls", tab, step.get("label", ""), step.get("address", ""))
            if control is None:
                results.append({"step": step, "ok": False, "text": f"no control labeled {step.get('label')!r}"})
                continue
            args["control"] = control
        elif tool == "submit_form":
            field = _resolve(mcp, "list_fields", tab, step["field"]) or step["field"]
            args["field"] = field
        elif tool == "type_text":
            target = _resolve(mcp, "list_fields", tab, step["target"]) or _resolve(mcp, "list_controls", tab, step["target"])
            args.update(target=target or step["target"], text=step["text"])
        elif tool == "press_key":
            args["key"] = step["key"]
            if step.get("target"):
                target = _resolve(mcp, "list_fields", tab, step["target"]) or _resolve(mcp, "list_controls", tab, step["target"])
                args["target"] = target or step["target"]
        elif tool == "scroll":
            args["to"] = step.get("to", "down")
        else:
            # The agent tools (run_script, search_history, screenshot, wait_for, call_page_tool) take their arguments as written.
            args.update({key: value for key, value in step.items() if key not in ("tool", "tab")})
        text, error = mcp.call_tool(tool, args)
        heard += "\n" + text
        if tool == "open_page" and not error:
            match = _ID.search(text)
            tabs["opened"] = match.group(1).strip() if match else None
        results.append({"step": step, "args": args, "ok": not error, "text": text})
    return results


def _resolve(mcp, tool: str, tab: str, label: str, address: str = "") -> str | None:
    text, error = mcp.call_tool(tool, {"id": tab})
    return None if error else pick(blocks(text), label, address)
