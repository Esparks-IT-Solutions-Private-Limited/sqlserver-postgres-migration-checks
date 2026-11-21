import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "compare", "compare_rowcounts.py")
sys.path.insert(0, os.path.join(HERE, "..", "compare"))
from compare_rowcounts import snake  # noqa: E402


def run(src, tgt, *args):
    with tempfile.TemporaryDirectory() as d:
        s, t = os.path.join(d, "s.csv"), os.path.join(d, "t.csv")
        with open(s, "w") as f:
            f.write(src)
        with open(t, "w") as f:
            f.write(tgt)
        p = subprocess.run([sys.executable, SCRIPT, s, t, *args], capture_output=True, text=True)
        return p.returncode, p.stdout


class SnakeCase(unittest.TestCase):
    def test_names(self):
        for given, want in [("OrderItems", "order_items"), ("HTTPLog", "http_log"),
                            ("customerID", "customer_id"), ("SKU", "sku"), ("already_snake", "already_snake")]:
            self.assertEqual(snake(given), want)


class Compare(unittest.TestCase):
    def test_match_exits_zero(self):
        code, out = run("dbo,orders,10\ndbo,customers,5\n", "public,orders,10\npublic,customers,5\n",
                        "--schema-map", "dbo=public")
        self.assertEqual(code, 0, out)
        self.assertIn("0 with a problem", out)

    def test_difference_and_missing_exit_one(self):
        code, out = run("dbo,orders,10\ndbo,customers,5\n", "public,orders,9\n", "--schema-map", "dbo=public")
        self.assertEqual(code, 1)
        self.assertIn("DIFF -1", out)
        self.assertIn("MISSING on target", out)

    def test_snake_case_and_extra_tables(self):
        code, out = run("dbo,OrderItems,3\n", "public,order_items,3\npublic,audit_log,1\n",
                        "--snake-case", "--schema-map", "dbo=public")
        self.assertEqual(code, 0, out)
        self.assertIn("(target only) public.audit_log", out)

    def test_ignores_headers_and_footers(self):
        code, _ = run("schema_name,table_name,row_count\ndbo,t,1\n\n(1 rows affected)\n", "public,t,1\n",
                      "--schema-map", "dbo=public")
        self.assertEqual(code, 0)


class Safety(unittest.TestCase):
    def test_failed_source_export_exits_two(self):
        code, _ = run("Sqlcmd: Error: Login failed for user 'x'.\n", "public,t,1\n")
        self.assertEqual(code, 2)

    def test_empty_target_exits_two(self):
        code, _ = run("dbo,t,1\n", "")
        self.assertEqual(code, 2)

    def test_schema_map_is_case_insensitive(self):
        code, out = run("dbo,t,1\n", "public,t,1\n", "--schema-map", "DBO=public")
        self.assertEqual(code, 0, out)

    def test_bad_schema_map_is_a_usage_error(self):
        code, _ = run("dbo,t,1\n", "public,t,1\n", "--schema-map", "dbo")
        self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()
