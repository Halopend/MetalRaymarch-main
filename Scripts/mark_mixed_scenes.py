#!/usr/bin/env python3
"""Validate or stamp `"mixedModeScene": true` in Threshold/Examples/Mixed.

Xcode's synchronized folders flatten bundled resources into the app-bundle
root, so the runtime can't tell which folder a .threshscene shipped in. The
Mixed browse section instead keys off the `mixedModeScene` field in the file.
Scenes SAVED while Mixed immersion is active get the flag automatically; run
this script after dropping older scene files into Examples/Mixed:

    python3 Scripts/mark_mixed_scenes.py
    python3 Scripts/mark_mixed_scenes.py --check
"""
import argparse
import json
import pathlib
import sys

parser = argparse.ArgumentParser()
parser.add_argument(
    "--check",
    action="store_true",
    help="report unmarked scenes without modifying them",
)
args = parser.parse_args()

root = pathlib.Path(__file__).resolve().parent.parent / "Threshold" / "Examples" / "Mixed"
if not root.is_dir():
    sys.exit(f"missing folder: {root}")

changed = 0
unmarked = []
for path in sorted(root.rglob("*.threshscene")):
    data = json.loads(path.read_text())
    if data.get("mixedModeScene") is True:
        continue
    if args.check:
        unmarked.append(path.relative_to(root.parent.parent.parent))
        continue
    data["mixedModeScene"] = True
    path.write_text(json.dumps(data, indent=2, sort_keys=False) + "\n")
    changed += 1
    print(f"marked {path.name}")

if unmarked:
    print("Mixed scenes missing `mixedModeScene: true`:", file=sys.stderr)
    for path in unmarked:
        print(f"  {path}", file=sys.stderr)
    sys.exit(1)

if args.check:
    print("all mixed scenes are marked")
    sys.exit(0)

print(f"{changed} file(s) updated")
