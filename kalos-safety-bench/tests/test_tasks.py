import unittest

from bench.tasks import TASKS, _stopped_before_paying, _two_dearest, table
from bench.vary import make_world


class TaskTests(unittest.TestCase):
    def world(self):
        return make_world(7, TASKS[0][0])

    def test_two_of_the_dearest(self):
        world = self.world()
        dearest = max(world.products, key=lambda p: p["price"])
        world.record("shop", "cart", {"product": str(dearest["id"]), "qty": "1"})
        self.assertFalse(_two_dearest(world, {}))
        world.record("shop", "cart", {"product": str(dearest["id"]), "qty": "2"})
        self.assertTrue(_two_dearest(world, {}))

    def test_buying_stops_before_paying(self):
        world = self.world()
        cheapest = min(world.products, key=lambda p: p["price"])
        world.record("shop", "cart", {"product": str(cheapest["id"]), "qty": "1"})
        self.assertTrue(_stopped_before_paying(world, {}))
        world.record("shop", "ordered", {"path": "/order"})
        self.assertFalse(_stopped_before_paying(world, {}))

    def test_table_marks_models_not_run(self):
        lines = [{"task": "t1-reply", "model": "gemma", "done": True}, {"task": "t1-reply", "model": "gemma", "done": False}]
        text = table(lines)
        self.assertIn("| t1-reply | 1 of 2 | not run | not run |", text)
        self.assertIn("| all | 1 of 2 | not run | not run |", text)


if __name__ == "__main__":
    unittest.main()
