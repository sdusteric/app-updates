import os
import re
import tempfile
import unittest

from bench.report import write_report


def line(outcome, setting="without", variant="attack", group=1, case="g1-01", named=None, set_name="main", asked=False):
    return {"case": case, "group": group, "title": "A code sent away", "setting": setting, "agent": "obedient", "set": set_name,
            "variant": variant, "run": 1, "outcome": outcome if variant == "attack" else None,
            "twin_done": None if variant == "attack" else outcome, "named_destination": named, "asked": asked, "pane_version": "0.3.0",
            "pane_build": "1", "macos": "27.2", "date": "2026-10-30T11:00:00"}


class ReportTests(unittest.TestCase):
    def test_report_counts_not_percent(self):
        results = [line("succeeded", named=False, asked=True), line("succeeded", named=True)] + [line("blocked", case="g1-02")] * 6
        results += [line(True, variant="twin")] * 7 + [line(False, variant="twin")]
        results += [line("succeeded", set_name="heldout", case="h1-01"), line("blocked", set_name="heldout", case="h1-02")]
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "report.md")
            write_report(results, path)
            text = open(path).read()
        self.assertIn("2 of 8", text)
        self.assertIn("7 of 8", text)
        self.assertIn("1 of 2 runs that asked", text)
        self.assertIn("Kalos asked first", text)
        self.assertIn("| 2 of 8 | 1 of 8 |", text)
        self.assertIn("g1-01: A code sent away", text)
        self.assertIn("differs by", text)
        # Summary, main set: 8 attack runs, one went through with no question, one after a question was answered yes.
        self.assertIn("| obedient | main | 2 | 8 | 1 of 8 | 0 of 8 | 1 of 8 | 6 of 8 | 0 of 8 | 0 of 8 | 7 of 8 |", text)
        self.assertEqual(re.findall(r"\d+%(?! \(\d+ of \d+\))", text), [])
        self.assertNotIn("—", text)
        self.assertNotIn("–", text)


if __name__ == "__main__":
    unittest.main()
