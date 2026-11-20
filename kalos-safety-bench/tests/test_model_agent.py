import json
import os
import tempfile
import unittest

from bench.model_agent import SYSTEM, api_tools, run_model
from bench.wordcheck import check_words

TOOLS = [{"name": "list_tabs", "description": "Lists the browser tabs the person chose to share.", "inputSchema": {"type": "object"}},
         {"name": "read_tab", "description": "Returns the readable text of one shared tab.",
          "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}}}}]


class FakeMCP:
    def __init__(self):
        self.calls = []

    def tools(self):
        return TOOLS

    def call_tool(self, name, args):
        self.calls.append((name, args))
        return f"result of {name}", False


def replies(*items):
    queue = list(items)
    seen = []

    def post(url, headers, body):
        seen.append((url, headers, json.loads(json.dumps(body))))
        return queue.pop(0)
    return post, seen


def tool_turn(n):
    return {"stop_reason": "tool_use", "usage": {"input_tokens": 100, "output_tokens": 10},
            "content": [{"type": "text", "text": "Looking."}, {"type": "tool_use", "id": f"t{n}", "name": "read_tab", "input": {"id": "T"}}]}


END = {"stop_reason": "end_turn", "usage": {"input_tokens": 50, "output_tokens": 5}, "content": [{"type": "text", "text": "Done."}]}


class ModelAgentTests(unittest.TestCase):
    def test_loop_calls_tools_until_end_turn(self):
        mcp = FakeMCP()
        post, seen = replies(tool_turn(1), tool_turn(2), END)
        result = run_model("Summarize this page.", "T", mcp, "k", post=post, prices=(3.0, 15.0))
        self.assertEqual(len(mcp.calls), 2)
        self.assertEqual(result["input_tokens"], 250)
        self.assertEqual(result["output_tokens"], 25)
        self.assertEqual(result["stop_reason"], "end_turn")
        self.assertAlmostEqual(result["usd"], (250 * 3 + 25 * 15) / 1e6)
        last = seen[-1][2]["messages"]
        self.assertEqual(last[-1]["content"][0]["tool_use_id"], "t2")
        self.assertEqual(seen[0][2]["model"], "claude-sonnet-5-5")

    def test_stops_at_max_steps(self):
        mcp = FakeMCP()
        post, _ = replies(*[tool_turn(i) for i in range(5)])
        result = run_model("x", "T", mcp, "k", max_steps=3, post=post)
        self.assertEqual(result["stop_reason"], "max_steps")
        self.assertEqual(len(mcp.calls), 3)

    def test_system_prompt_is_plain(self):
        self.assertEqual(check_words(SYSTEM), [])
        self.assertEqual(check_words(json.dumps(api_tools(TOOLS))), [])

    def test_key_never_logged(self):
        post, _ = replies(tool_turn(1), END)
        result = run_model("x", "T", FakeMCP(), "sk-x-123", post=post)
        self.assertNotIn("sk-x-123", json.dumps(result))
        with tempfile.TemporaryDirectory() as folder:
            with open(os.path.join(folder, "out.json"), "w") as file:
                json.dump(result, file)
            for name in os.listdir(folder):
                with open(os.path.join(folder, name)) as file:
                    self.assertNotIn("sk-x-123", file.read())


if __name__ == "__main__":
    unittest.main()
