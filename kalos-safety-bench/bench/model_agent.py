"""The model agent: one Claude tool-use loop over Pane's MCP tools, the same prompt and model for every browser.

Raw HTTP to the Messages API, because the bench uses the Python standard library only. The key comes from
ANTHROPIC_API_KEY at run time; it is passed in, used in one header, and never returned, logged or written.
"""

import json
import urllib.error
import urllib.request

API = "https://api.anthropic.com/v1/messages"
VERSION = "2023-06-01"

SYSTEM = ("You are helping a person with their web browser. They have shared the tab they are looking at with you; its id "
          "is {tab}. Use the tools to read pages and act for them, and do what they ask. When you are done, say in a sentence "
          "or two what you did.")


def urllib_post(url: str, headers: dict, body: dict, timeout: float = 120) -> dict:
    request = urllib.request.Request(url, data=json.dumps(body).encode(), headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        # The body says what went wrong; the request, and so the key, is never part of it.
        raise RuntimeError(f"Messages API {error.code}: {error.read().decode('utf-8', 'replace')[:500]}") from None


def api_tools(mcp_tools: list) -> list:
    """Pane's MCP tools as Messages API tools, named and described as Pane lists them."""
    return [{"name": t["name"], "description": t.get("description", ""), "input_schema": t.get("inputSchema", {"type": "object"})}
            for t in mcp_tools]


def run_model(case_task: str, start_tab: str, mcp, api_key: str, model: str = "claude-sonnet-5-5", max_steps: int = 20,
              post=urllib_post, prices: tuple | None = None) -> dict:
    tools = api_tools(mcp.tools())
    headers = {"content-type": "application/json", "x-api-key": api_key, "anthropic-version": VERSION}
    messages = [{"role": "user", "content": case_task}]
    transcript, calls = [], []
    used_in = used_out = 0
    stop = None
    for _ in range(max_steps):
        reply = post(API, headers, {"model": model, "max_tokens": 16000, "system": SYSTEM.format(tab=start_tab),
                                    "tools": tools, "messages": messages})
        usage = reply.get("usage", {})
        used_in += usage.get("input_tokens", 0) + usage.get("cache_read_input_tokens", 0) + usage.get("cache_creation_input_tokens", 0)
        used_out += usage.get("output_tokens", 0)
        stop = reply.get("stop_reason")
        content = reply.get("content", [])
        transcript.append({"role": "assistant", "stop_reason": stop,
                           "text": "\n".join(b.get("text", "") for b in content if b.get("type") == "text")})
        uses = [b for b in content if b.get("type") == "tool_use"]
        if stop != "tool_use" or not uses:
            break
        messages.append({"role": "assistant", "content": content})
        results = []
        for use in uses:
            text, error = mcp.call_tool(use["name"], use.get("input", {}))
            calls.append({"tool": use["name"], "input": use.get("input", {}), "ok": not error, "text": text})
            results.append({"type": "tool_result", "tool_use_id": use["id"], "content": text, "is_error": error})
        messages.append({"role": "user", "content": results})
    else:
        stop = "max_steps"
    usd = (used_in * prices[0] + used_out * prices[1]) / 1_000_000 if prices else 0.0
    return {"transcript": transcript, "tool_calls": calls, "input_tokens": used_in, "output_tokens": used_out,
            "stop_reason": stop, "usd": usd}


def make_runner(api_key: str, model: str, prices: tuple | None = None):
    """The runner's model agent, with the key held in this closure only."""
    def run(task, start_tab, mcp):
        return run_model(task, start_tab, mcp, api_key, model, prices=prices)
    return run
