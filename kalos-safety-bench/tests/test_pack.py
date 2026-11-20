import os
import tarfile
import tempfile
import unittest

from bench.pack import ROOT, build, files, leaks


# Built from parts, so this file holds none of the text the pack refuses.
HOME, TEMP, KEY, NAMED = "/Users" + "/someone", "/var" + "/folders/a", "sk-ant" + "-api03-abcdefgh", "ANTHROPIC_API_KEY" + "=abcdef123456"


class PackTests(unittest.TestCase):
    def test_held_out_cases_and_evidence_stay_out(self):
        chosen = files()
        self.assertIn("METHOD.md", chosen)
        self.assertIn("bench/pack.py", chosen)
        self.assertTrue(any(name.startswith("cases/") for name in chosen))
        self.assertFalse(any(name.startswith("heldout/") or "__pycache__" in name for name in chosen))

    def test_private_text_is_found(self):
        self.assertEqual(leaks(f"ran in {HOME}/Library and {TEMP}b/T/x"), [HOME, TEMP])
        self.assertEqual(leaks("ANTHROPIC_API_KEY=... from the shell"), [])
        self.assertEqual(leaks(f"export {NAMED}"), [NAMED])
        self.assertEqual(leaks(f"a key such as {KEY}"), [KEY])
        self.assertEqual(leaks("Results go to build/safety-bench/<date>/"), [])

    def test_archive_is_stable_and_refuses_private_results(self):
        with tempfile.TemporaryDirectory() as folder:
            results = os.path.join(folder, "results.jsonl")
            with open(results, "w") as file:
                file.write('{"case": "g1-01", "outcome": "blocked"}\n')
            first, second = os.path.join(folder, "a.tar.gz"), os.path.join(folder, "b.tar.gz")
            self.assertEqual(build(first, [results]), [])
            self.assertEqual(build(second, [results]), [])
            self.assertEqual(open(first, "rb").read(), open(second, "rb").read())
            with tarfile.open(first) as tar:
                names = tar.getnames()
            self.assertIn("kalos-safety-bench/results/results/results.jsonl", names)
            self.assertIn("kalos-safety-bench/METHOD.md", names)
            with open(results, "a") as file:
                file.write('{"app": "' + HOME + '/Kalos.app"}\n')
            self.assertTrue(build(os.path.join(folder, "c.tar.gz"), [results]))
            self.assertFalse(os.path.exists(os.path.join(folder, "c.tar.gz")))
            self.assertTrue(os.path.isdir(ROOT))


if __name__ == "__main__":
    unittest.main()
