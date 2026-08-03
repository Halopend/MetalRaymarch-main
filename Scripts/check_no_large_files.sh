#!/usr/bin/env bash
#
# check_no_large_files.sh
#
# Guards against committing oversized binaries. Git history is append-only in
# practice: once a large blob is pushed, every future clone pays for it forever
# and removing it means rewriting history. This repo already carries ~766 MB of
# packfiles, and a 218 MB screen recording was caught staged (but not yet
# committed) during the 2026-08-02 audit — hence this gate.
#
# Large media belongs outside the repo (or in Git LFS), not in a normal commit.
#
# Usage:
#   Scripts/check_no_large_files.sh          # scan files staged for commit
#   Scripts/check_no_large_files.sh --all    # scan every tracked file
#
# Exits non-zero (listing offenders) if any are found; used by .githooks/pre-commit.
# Bypass a single commit with:  git commit --no-verify
# Override the threshold with:  THRESHOLD_MAX_FILE_MB=25 Scripts/check_no_large_files.sh
#
# Intentionally bash 3.2 compatible (macOS system bash): no `mapfile`, no `readarray`.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# 10 MB. The largest file tracked today is ~5.5 MB, so this fires only on new
# outliers, never on the existing tree.
max_mb="${THRESHOLD_MAX_FILE_MB:-10}"
max_bytes=$(( max_mb * 1024 * 1024 ))

if [[ "${1:-}" == "--all" ]]; then
    list() { git ls-files; }
else
    list() { git diff --cached --name-only --diff-filter=ACMR; }
fi

offenders=""
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ -f "$f" ]] || continue
    # stat -f%z is BSD/macOS; -c%s is GNU. Support both so CI (Linux) agrees.
    size=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0)
    if (( size > max_bytes )); then
        offenders+="   $f  ($(( size / 1024 / 1024 )) MB)"$'\n'
    fi
done < <(list)

if [[ -n "$offenders" ]]; then
    {
        printf '❌ File(s) larger than %s MB staged for commit:\n' "$max_mb"
        printf '%s' "$offenders"
        printf '   Keep large media out of git history (it can never be cheaply removed).\n'
        printf '   Move it outside the repo or use Git LFS.\n'
        printf '   Intentional? Bypass once: git commit --no-verify\n'
    } >&2
    exit 1
fi

exit 0
