#!/usr/bin/env python3
"""End-to-end CLI checks against a temporary folder; no user scenes are edited."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().with_name("scenes.sh")


class SceneCLITests(unittest.TestCase):
    def test_folder_conversion(self):
        with tempfile.TemporaryDirectory(prefix="threshold scenes cli ") as temporary:
            root = Path(temporary)
            folder = root / "Scenes with spaces"
            nested = folder / "Nested"
            nested.mkdir(parents=True)
            original = json.dumps({"name": "Scene 🌌", "parameters": [2.75] * 4000}, indent=2).encode()
            first = folder / "First.threshscene"
            second = nested / "Second.THRESHANIM"
            first.write_bytes(original)
            second.write_bytes(original)
            tiny = folder / "Tiny.thresh"
            tiny.write_bytes(b'{"name":"Tiny"}')
            unrelated = folder / "notes.json"
            unrelated.write_bytes(original)
            outside = root / "Outside.thresh"
            outside.write_bytes(original)
            (folder / "Link.thresh").symlink_to(outside)

            def run(*flags):
                return subprocess.run([str(SCRIPT), "compress", str(folder), *flags], capture_output=True, text=True)

            result = run("--recursive", "--dry-run")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("2 would compress", result.stdout)
            self.assertEqual(first.read_bytes(), original)
            self.assertEqual(second.read_bytes(), original)

            result = run()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(first.read_bytes().startswith(b"THRSCN01"))
            self.assertEqual(second.read_bytes(), original)

            damaged = folder / "Damaged.thresh"
            corrupt = bytearray(first.read_bytes())
            corrupt[16] ^= 0xff
            damaged.write_bytes(corrupt)
            invalid = folder / "Invalid.thresh"
            invalid.write_bytes(b"not JSON")
            result = run("--recursive")
            self.assertEqual(result.returncode, 1)
            self.assertTrue(second.read_bytes().startswith(b"THRSCN01"))
            self.assertEqual(damaged.read_bytes(), bytes(corrupt))
            self.assertEqual(invalid.read_bytes(), b"not JSON")
            self.assertIn("2 failed", result.stdout)
            damaged.unlink()
            invalid.unlink()

            before = first.read_bytes(), second.read_bytes()
            result = run("--recursive")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("0 compressed", result.stdout)
            self.assertEqual(before, (first.read_bytes(), second.read_bytes()))
            self.assertEqual(tiny.read_bytes(), b'{"name":"Tiny"}')
            self.assertEqual(unrelated.read_bytes(), original)
            self.assertEqual(outside.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
