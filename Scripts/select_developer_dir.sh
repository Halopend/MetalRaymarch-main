#!/usr/bin/env bash
# Print the DEVELOPER_DIR the repo's build + QL-gate scripts should use.
#
# Shared resolver for build.sh and ql_render_check.sh: both previously
# ordered candidates as Xcode-beta.app → "Xcode-beta 2.app" → Xcode.app, so a
# machine running parallel betas (the exact convention
# check_no_duplicate_suffix.sh polices) could build with a STALE beta while
# the QL gate used a different one. Order candidates newest-first (mtime).
#
# Prints the resolved path and exits 0, or prints an error to stderr and
# exits 1 when no usable toolchain is found.

set -euo pipefail

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    echo "$DEVELOPER_DIR"
    exit 0
fi

# Newest-first by modification time; covers Xcode.app, Xcode-beta.app, and the
# "Xcode-beta 2.app" convention.
local_candidate="$(ls -dt /Applications/Xcode*.app/Contents/Developer 2>/dev/null | head -n 1 || true)"
if [[ -n "$local_candidate" && -x "$local_candidate/usr/bin/xcodebuild" ]]; then
    echo "$local_candidate"
    exit 0
fi

selected="$(xcode-select -p 2>/dev/null || true)"
if [[ -n "$selected" && -x "$selected/usr/bin/xcodebuild" ]]; then
    echo "$selected"
    exit 0
fi

echo "ERROR: no full Xcode developer directory was found (looked in /Applications/Xcode*.app and xcode-select)." >&2
echo "       Select Xcode 26+ with xcode-select or set DEVELOPER_DIR explicitly." >&2
exit 1