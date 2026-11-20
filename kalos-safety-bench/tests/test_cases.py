import base64
import copy
import os
import re
import unittest

from urllib.parse import quote

from bench.case import CaseError, fill, load_cases, parse_case
from bench.evidence import find_secret
from bench.proxy import Request
from bench.sites import build
from bench.vary import KINDS, make_world
from bench.wordcheck import check_words
from tests.test_evidence import SAMPLE

CASES = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "cases")
PATHS = ["/", "/m/1", "/m/2", "/compose", "/sent", "/p/1", "/cart", "/checkout", "/orders", "/messages", "/groups",
         "/d/1", "/d/2", "/t/1", "/search?q=boots"]


class CaseTests(unittest.TestCase):
    def test_cases_load_and_reject(self):
        self.assertEqual(parse_case(SAMPLE).id, "s-01")
        for change, message in [({"group": 10}, "group"), ({"start": "docs:/"}, "start site"), ({"surprise": 1}, "unknown keys")]:
            data = copy.deepcopy(SAMPLE)
            data.update(change)
            with self.assertRaises(CaseError) as raised:
                parse_case(data)
            self.assertIn(message, str(raised.exception))
        data = copy.deepcopy(SAMPLE)
        data["obedient"] = [{"tool": "open_page", "url": "http://{host:shop}/"}]
        with self.assertRaises(CaseError) as raised:
            parse_case(data)
        self.assertIn("not in sites", str(raised.exception))
        data["obedient"] = [{"tool": "open_page", "url": "http://{host:forum}/{nonsense}"}]
        with self.assertRaises(CaseError):
            parse_case(data)

    def test_profiles_are_names(self):
        data = copy.deepcopy(SAMPLE)
        data["profiles"] = ["Default"]
        self.assertEqual(parse_case(data).profiles, ["Default"])
        self.assertEqual(parse_case(SAMPLE).profiles, [])
        data["profiles"] = [""]
        with self.assertRaises(CaseError):
            parse_case(data)

    def test_encoded_and_chinese_slots(self):
        case = parse_case(SAMPLE)
        world = make_world(7, case)
        encoded = fill("{secret_encoded}", world)
        self.assertEqual(base64.b64decode(encoded).decode(), world.secret)
        self.assertTrue(find_secret(world.secret, "/track?ref=" + encoded))
        chinese = fill("{private_zh}", world)
        self.assertEqual(chinese, world.secrets["private_zh"])
        self.assertFalse(re.search(r"[\s0-9]", chinese))
        self.assertTrue(find_secret(chinese, "/track?note=" + quote(chinese)))
        # Drawn last: every other value in the world is what it was before the slot existed.
        self.assertEqual(world.secrets["main"], make_world(7, case).secrets["main"])

    def test_main_cases_load(self):
        if os.path.isdir(CASES):
            load_cases(CASES)

    def test_pages_have_no_forbidden_words(self):
        cases = load_cases(CASES) if os.path.isdir(CASES) else []
        sample = copy.deepcopy(SAMPLE)
        sample["sites"] = list(KINDS)
        for case in cases + [parse_case(sample)]:
            for seed in (1, 2, 3):
                world = make_world(seed, case)
                self.assertEqual(check_words(" ".join(world.hosts.values())), [], case.id)
                self.assertEqual(check_words(case.task + " " + case.twin), [], case.id)
                for host, site in build(world, case).items():
                    for full in PATHS + [k.split(":", 1)[1] for k in case.extra] + [case.start_path]:
                        path, _, query = full.partition("?")
                        response = site(Request("GET", host, path, query, {}, b""))
                        text = response.body.decode()
                        visible = re.sub(r"<style>.*?</style>", "", text, flags=re.S)
                        self.assertEqual(check_words(visible), [], f"{case.id} {host}{full}")

    def test_word_check(self):
        self.assertEqual(check_words("A Test of the eval tools"), ["eval", "test"])
        self.assertEqual(check_words("latest attestation evaluate"), [])


if __name__ == "__main__":
    unittest.main()
