"""The parts of the benchmark and chart code that don't need the engine or a screen."""
import importlib.util
import json
import sys
import unittest
import xml.dom.minidom
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STATE = """Window: "Calculator", App: Calculator.
\t\t\t6 button Description: Delete, Help: Delete the last digit
\t\t\t7 button Clear
\t\t\t8 button Percent
\t\t\t18 button Description: 1, ID: One
\t\t\t21 button Add
\t\t\t24 button Description: Point, ID: Decimal
\t\t\t25 button Equals
"""


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / f"benchmarks/{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class BenchmarkTest(unittest.TestCase):
    def test_finds_buttons_in_the_engines_text(self):
        button = load("run").Engine.button
        self.assertEqual([button(STATE, label) for label in ("Clear", "1", "Add", "Point", "Equals")], [7, 18, 21, 24, 25])
        self.assertEqual(button(STATE.replace("button Clear", "button Description: All Clear, ID: AllClear"), "Clear"), 7)

    def test_finds_buttons_in_agent_desktops_json(self):
        tree = {"role": "window", "children": [{"role": "button", "name": "Add", "ref_id": "@s:e1"},
                                               {"role": "group", "children": [{"role": "button", "name": "1", "ref_id": "@s:e2"}]}]}
        found = load("run").Desktop.buttons(json.dumps({"data": {"tree": tree}}))
        self.assertEqual(found, {"Add": "@s:e1", "1": "@s:e2"})

    def test_draws_valid_charts_from_the_committed_results(self):
        chart = load("chart")
        results = json.loads((ROOT / "benchmarks/results.json").read_text())
        for title, subtitle, rows in chart.charts(results).values():
            self.assertLessEqual(len(rows), 3)
            svg = chart.draw(title, subtitle, rows, "Footer", "dark")
            xml.dom.minidom.parseString(svg)
            for _, _, bars in rows:
                self.assertEqual(sorted({bar[0] for bar in bars}), ["Codex engine", "agent-desktop", "ucu"])

    def test_formats_values(self):
        chart = load("chart")
        self.assertEqual((chart.ms(61.3), chart.ms(1488), chart.count(2264.7)), ("61 ms", "1.5 s", "2,265"))


if __name__ == "__main__":
    unittest.main()
