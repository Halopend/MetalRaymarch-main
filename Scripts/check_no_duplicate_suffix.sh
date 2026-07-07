#!/usr/bin/env bash
#
# check_no_duplicate_suffix.sh
#
# Guards against committing Finder/Xcode "Duplicate" artifacts — files whose
# name ends in " copy" or " <number>" before the extension, e.g.
# "RenderSettings 2.swift", "Shaders copy.metal", "Config copy 2.json". These
# come from an accidental Option-drag or "Duplicate" in Finder/Xcode and should
# never be committed. (This repo was bitten by exactly this class of mistake:
# an "Xcode-beta 2.app" path string outlived the app it named — see build.sh.)
#
# Usage:
#   Scripts/check_no_duplicate_suffix.sh          # scan files staged for commit
#   Scripts/check_no_duplicate_suffix.sh --all    # scan every tracked file
#
# Exits non-zero (listing offenders) if any are found; used by .githooks/pre-commit.
# Bypass a single commit with:  git commit --no-verify
#
# Intentionally bash 3.2 compatible (macOS system bash): no `mapfile`, no `readarray`.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if [[ "${1:-}" == "--all" ]]; then
    list() { git ls-files; }
else
    list() { git diff --cached --name-only --diff-filter=ACMR; }
fi

offenders=""
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    base="${f##*/}"
    dir="${f%/*}"; [[ "$dir" == "$f" ]] && dir="."

    # "Foo copy.ext" / "Foo copy 2.ext" — always a Finder/Xcode duplicate artifact.
    if [[ "$base" =~ \ copy(\ [0-9]+)?\.[A-Za-z0-9]+$ ]]; then
        offenders+="   $f"$'\n'
        continue
    fi

    # "Foo 2.ext" — flag ONLY when the un-numbered sibling "Foo.ext" also exists,
    # i.e. a genuine duplicate PAIR. This spares legitimate numbered series like
    # "Scene 15.threshanim" (which have no "Scene.threshanim" sibling).
    if [[ "$base" =~ ^(.*)\ [0-9]+(\.[A-Za-z0-9]+)$ ]]; then
        sibling="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
        if [[ -e "$dir/$sibling" ]]; then
            offenders+="   $f  (looks like a duplicate of $sibling)"$'\n'
        fi
    fi
done < <(list)

if [[ -n "$offenders" ]]; then
    {
        printf '❌ Duplicate-suffix file(s) detected (Finder/Xcode "Duplicate" artifacts):\n'
        printf '%s' "$offenders"
        printf '   Rename or delete them before committing (bypass once: git commit --no-verify).\n'
    } >&2
    exit 1
fi

exit 0
