import unittest

from bench.tokens import control_words, fact_word, offers, query_for, table


class TokenMeterTests(unittest.TestCase):
    def test_fact_word_is_a_word_the_page_uses_a_few_times(self):
        text = "Tokyo population grew. The population is large. Tokyo Tokyo Tokyo Tokyo Tokyo Tokyo is big."
        self.assertEqual(fact_word(text), "population")
        self.assertEqual(fact_word("short"), "")

    def test_control_words_come_from_a_button_or_link_label(self):
        snapshot = "c0  button  “Add to cart now”\nc1  link  “Help center”  /help\nc2  checkbox  “Keep me”"
        self.assertEqual(control_words(snapshot), "Help center")
        self.assertEqual(control_words("controls: none visible"), "")

    def test_offers_reads_the_input_schema(self):
        tools = [{"name": "snapshot", "inputSchema": {"properties": {"id": {}, "find": {}}}}]
        self.assertTrue(offers(tools, "snapshot", "find"))
        self.assertFalse(offers(tools, "snapshot", "changes"))
        self.assertFalse(offers(tools, "read_tab", "find"))

    def test_table_marks_calls_a_build_does_not_offer(self):
        result = {"tokenizer": "characters / 4", "build": "1", "tool_list": {"tokens": 10, "count": 2},
                  "instructions": {"tokens": 5}, "pages": {"bench shop:/": {"read_tab": {"tokens": 7}, "snapshot": {"tokens": 3}}}}
        self.assertIn("| bench shop:/ | 7 | - | - | 3 | - | - | - |", table(result))

    def test_each_live_page_gets_its_own_query(self):
        self.assertEqual(query_for("live hackernews"), ".titleline > a")
        self.assertEqual(query_for("live wikipedia"), ".infobox")
        self.assertEqual(query_for("live github"), "h1, h2")
        self.assertEqual(query_for("bench shop:/"), "h1, h2")


if __name__ == "__main__":
    unittest.main()
