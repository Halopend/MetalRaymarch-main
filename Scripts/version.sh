#!/usr/bin/env bash
# Single build-number / marketing-version counter for ALL Threshold targets.
#
# WHY THIS EXISTS: App Store Connect requires a unique, increasing build number
# (CURRENT_PROJECT_VERSION) for every uploaded build, and for a multiplatform
# app every platform upload (macOS / iOS / visionOS) consumes one. The two Quick
# Look appexes must carry the SAME number as their host app. This repo therefore
# keeps ONE number shared by every configuration in Threshold.xcodeproj; the QL
# targets inherit it from the project defaults.
#
# History that motivated this tool: the last committed bump was to build 24,
# while App Store Connect already had builds up to 28 (uploads that never
# touched the pbxproj). `Scripts/version.sh` exists so the counter lives in
# exactly one place and is bumped with one command instead of hand-edits.
#
# Usage:
#   Scripts/version.sh show               # table: build number + marketing version per target
#   Scripts/version.sh check              # CI: exit 1 if configs disagree (drift detection)
#   Scripts/version.sh bump [n]           # ALL configs -> max(current)+n   (default 1)
#   Scripts/version.sh set <n>            # ALL configs -> n (e.g. after ASC says "build N exists")
#   Scripts/version.sh marketing <x.y.z>  # ALL configs -> new MARKETING_VERSION
#
# Release flow (manual Organizer uploads):
#   1. Scripts/version.sh bump
#   2. Archive + Distribute App for each platform from Xcode.
#   If App Store Connect ever rejects "build N already exists", run
#   `Scripts/version.sh set <latest-known+1>` and archive again.
#
# Note: `PipelineBinaryArchive` keys its PSO cache file on CFBundleVersion, so
# every bump costs one cold Metal compile per machine. That is expected.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PBXPROJ="$REPO_ROOT/Threshold.xcodeproj/project.pbxproj"

[[ -f "$PBXPROJ" ]] || { echo "ERROR: $PBXPROJ not found" >&2; exit 2; }

cmd="${1:-}"

case "$cmd" in
    show|check) ;;
    bump)
        n="${2:-1}"
        [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 ]] || { echo "ERROR: bump needs a positive integer (got '$n')" >&2; exit 2; }
        ;;
    set)
        [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]] || { echo "ERROR: set needs a build number, e.g. set 29" >&2; exit 2; }
        ;;
    marketing)
        [[ -n "${2:-}" && "$2" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "ERROR: marketing needs x.y or x.y.z, e.g. marketing 1.0.2" >&2; exit 2; }
        ;;
    *)
        sed -n '/^# Usage:/,/^# Note:/p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac

exec python3 - "$PBXPROJ" "$cmd" "${@:2}" <<'PY'
import os, re, sys

PBX, CMD, *ARGS = sys.argv[1:]
text = open(PBX, encoding="utf-8").read()

# ---- parse ----------------------------------------------------------------
def parse(src):
    """Populate module globals from pbxproj text."""
    global lists, configs, project_cpv, project_mkt, targets, cpvs, mkts, eff_cpvs, eff_mkts
    # XCConfigurationList -> owner ("Target" or "(project defaults)"), per config id.
    lists = {}
    for m in re.finditer(
            r'([0-9A-F]{24}) /\* Build configuration list for (PBXNativeTarget|PBXProject) "([^"]+)" \*/ = \{.*?buildConfigurations = \((.*?)\);',
            src, re.S):
        owner = m.group(3) if m.group(2) == "PBXNativeTarget" else "(project defaults)"
        for cid, cname in re.findall(r'([0-9A-F]{24}) /\* (\w+) \*/', m.group(4)):
            lists[cid] = owner

    # XCBuildConfiguration blocks: (owner, name, CPV or None, MARKETING_VERSION or None).
    configs = []
    for m in re.finditer(r'^\t\t([0-9A-F]{24}) /\* ([^*]+?) \*/ = \{$(.*?)^\t\t\};$', src, re.S | re.M):
        body = m.group(3)
        if "isa = XCBuildConfiguration;" not in body:
            continue
        cpv = re.search(r'CURRENT_PROJECT_VERSION = (\d+);', body)
        mkt = re.search(r'MARKETING_VERSION = ([^;]+);', body)
        configs.append((lists.get(m.group(1), "?"), m.group(2),
                        cpv.group(1) if cpv else None,
                        mkt.group(1).strip() if mkt else None))

    if not configs:
        sys.exit("ERROR: no XCBuildConfiguration blocks parsed — pbxproj format changed?")

    project = next((c for c in configs if c[0] == "(project defaults)"), None)
    project_cpv = project[2] if project else None
    project_mkt = project[3] if project else None

    seen, targets = set(), []
    for c in configs:
        if c[0] not in seen:
            seen.add(c[0])
            targets.append(c[0])

    order = ["(project defaults)", "ThresholdMac", "ThresholdiOS", "Threshold",
             "ThresholdQLPreview", "ThresholdQLThumbnail", "ThresholdTests"]
    targets.sort(key=lambda t: (order.index(t) if t in order else 99, t))

    cpvs = {c[2] for c in configs if c[2] is not None}
    mkts = {c[3] for c in configs if c[3] is not None}
    eff_cpvs = {effective(c) for c in configs}
    eff_mkts = {effective_mkt(c) for c in configs}

def effective(cfg):
    """Value Xcode will resolve for this config: target override, else project default."""
    return cfg[2] if cfg[2] is not None else project_cpv

def effective_mkt(cfg):
    return cfg[3] if cfg[3] is not None else project_mkt

parse(text)

def report():
    print(f'{"target":22} {"Debug":>12} {"Release":>12} {"PGO":>12}')
    for t in targets:
        rows = [c for c in configs if c[0] == t]
        cells = []
        for name in ("Debug", "Release", "PGO"):
            r = next((c for c in rows if c[1] == name), None)
            if r is None:
                continue
            b = r[2] if r[2] is not None else f'({project_cpv}*)'
            k = (r[3] or project_mkt) if (r[3] is not None or project_mkt is not None) else "?"
            cells.append(f'{b} / {k}')
        print(f'{t:22} ' + " ".join(f'{c:>12}' for c in cells))
    print("\n(* inherited from project defaults)")
    print(f'Archive stamp (what the next build/upload carries): '
          f'build {sorted(eff_cpvs)[0]}, marketing {sorted(eff_mkts)[0]}')

if CMD == "show":
    report()
    sys.exit(0)

if CMD == "check":
    ok = True
    if len(cpvs) != 1:
        ok = False
        print(f"FAIL: CURRENT_PROJECT_VERSION drift: {sorted(cpvs)}")
        for c in configs:
            if c[2] is not None:
                print(f"  {c[0]} {c[1]} = {c[2]}")
    if len(mkts) != 1:
        ok = False
        print(f"FAIL: MARKETING_VERSION drift: {sorted(mkts)}")
        for c in configs:
            if c[3] is not None:
                print(f"  {c[0]} {c[1]} = {c[3]}")
    if len(eff_cpvs) != 1 or len(eff_mkts) != 1:
        ok = False
        print("FAIL: effective values are not uniform across targets "
              f"(build={sorted(eff_cpvs)}, marketing={sorted(eff_mkts)})")
    if ok:
        print(f"VERSION CHECK: OK — build {next(iter(cpvs))}, marketing {next(iter(mkts))}, uniform across all targets")
        sys.exit(0)
    sys.exit(1)

# ---- mutate ---------------------------------------------------------------
new_text = text
if CMD == "bump":
    n = int(ARGS[0]) if ARGS else 1
    if not cpvs:
        sys.exit("ERROR: no CURRENT_PROJECT_VERSION found to bump")
    old = sorted(int(v) for v in cpvs)
    new_build = max(old) + n
    new_text, count = re.subn(r'(CURRENT_PROJECT_VERSION = )\d+(;)',
                              rf'\g<1>{new_build}\g<2>', text)
    if count == 0:
        sys.exit("ERROR: CURRENT_PROJECT_VERSION assignments not found")
    note = f"build number {old} -> {new_build} ({count} configurations)"
elif CMD == "set":
    new_build = int(ARGS[0])
    old = sorted(int(v) for v in cpvs)
    new_text, count = re.subn(r'(CURRENT_PROJECT_VERSION = )\d+(;)',
                              rf'\g<1>{new_build}\g<2>', text)
    if count == 0:
        sys.exit("ERROR: CURRENT_PROJECT_VERSION assignments not found")
    note = f"build number {old} -> {new_build} ({count} configurations)"
else:  # marketing
    old = sorted(mkts)
    new_text, count = re.subn(r'(MARKETING_VERSION = )[^;]+(;)',
                              rf'\g<1>{ARGS[0]}\g<2>', text)
    if count == 0:
        sys.exit("ERROR: MARKETING_VERSION assignments not found")
    note = f"marketing version {old} -> {ARGS[0]} ({count} configurations)"

# Atomic replace so a crash can never leave a truncated pbxproj.
tmp = PBX + ".tmp-version"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(new_text)
os.replace(tmp, PBX)

parse(new_text)  # re-read so the table below shows the NEW values
report()
print(f"\nUPDATED: {note}")
print("Commit this with the release, e.g.: chore(release): bump to %s" %
      (new_build if CMD != "marketing" else ARGS[0]))
PY