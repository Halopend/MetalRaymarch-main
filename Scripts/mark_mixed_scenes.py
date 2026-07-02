#!/usr/bin/env python3
"""Stamp `"mixedModeScene": true` into every scene in Threshold/Examples/Mixed.

Xcode's synchronized folders flatten bundled resources into the app-bundle
root, so the runtime can't tell which folder a .threshscene shipped in. The
Mixed browse section instead keys off the `mixedModeScene` field in the file.
Scenes SAVED while Mixed immersion is active get the flag automatically; run
this script after dropping older scene files into Examples/Mixed:

    python3 Scripts/mark_mixed_scenes.py
"""
import json
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent / "Threshold" / "Examples" / "Mixed"
if not root.is_dir():
    sys.exit(f"missing folder: {root}")

changed = 0
for path in sorted(root.rglob("*.threshscene")):
    data = json.loads(path.read_text())
    if data.get("mixedModeScene") is True:
        continue
    data["mixedModeScene"] = True
    path.write_text(json.dumps(data, indent=2, sort_keys=False) + "\n")
    changed += 1
    print(f"marked {path.name}")
print(f"{changed} file(s) updated")
