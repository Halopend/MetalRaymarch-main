#!/bin/sh
# Stamps the built app's Info.plist with the current git commit SHA + dirty flag,
# read at runtime by BuildStamp (Threshold/Analytics/PerfLog.swift) so each
# performance-log record is keyed to an exact commit.
#
# Invoked as a "Stamp Git SHA" Run Script build phase on the Threshold target.
# Safe to run standalone too — it no-ops gracefully when git or the plist is
# unavailable (the app then reports gitSHA "unknown").

set -e

SRC="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

SHA=$(git -C "$SRC" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
if [ -n "$(git -C "$SRC" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    DIRTY=YES
else
    DIRTY=NO
fi

# During an Xcode build, write into the built product's Info.plist.
PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [ -z "${TARGET_BUILD_DIR}" ] || [ -z "${INFOPLIST_PATH}" ] || [ ! -f "$PLIST" ]; then
    echo "stamp_git_sha: no built Info.plist (SHA=$SHA dirty=$DIRTY) — skipping"
    exit 0
fi

/usr/libexec/PlistBuddy -c "Set :GitSHA $SHA"    "$PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :GitSHA string $SHA"    "$PLIST"
/usr/libexec/PlistBuddy -c "Set :GitDirty $DIRTY" "$PLIST" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :GitDirty string $DIRTY" "$PLIST"
echo "stamp_git_sha: GitSHA=$SHA GitDirty=$DIRTY → $PLIST"
