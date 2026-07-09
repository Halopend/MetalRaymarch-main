#!/bin/sh
# Stamps the built app with the current git commit SHA + dirty flag, read at
# runtime by BuildStamp (Threshold/Analytics/PerfLog.swift) so each performance
# log record is keyed to an exact commit.
#
# Invoked as a "Stamp Git SHA" Run Script build phase on app targets.
# Safe to run standalone too — it no-ops gracefully when git or the plist is
# unavailable (the app then reports gitSHA "unknown").

set -e

SRC="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

SHA="${THRESHOLD_GIT_SHA:-}"
if [ -z "$SHA" ]; then
    HEAD_FILE="$SRC/.git/HEAD"
    if [ -f "$HEAD_FILE" ]; then
        HEAD_VALUE=$(cat "$HEAD_FILE" 2>/dev/null || true)
        case "$HEAD_VALUE" in
            ref:\ *)
                REF_PATH="${HEAD_VALUE#ref: }"
                if [ -f "$SRC/.git/$REF_PATH" ]; then
                    SHA=$(cut -c1-12 "$SRC/.git/$REF_PATH" 2>/dev/null || echo unknown)
                elif [ -f "$SRC/.git/packed-refs" ]; then
                    SHA=$(awk -v ref="$REF_PATH" '$2 == ref { print substr($1, 1, 12); exit }' "$SRC/.git/packed-refs" 2>/dev/null || echo unknown)
                fi
                ;;
            *)
                SHA=$(printf '%s' "$HEAD_VALUE" | cut -c1-12)
                ;;
        esac
    fi
fi
if [ -z "$SHA" ]; then
    SHA=unknown
fi
if [ -n "${THRESHOLD_GIT_DIRTY:-}" ]; then
    DIRTY="$THRESHOLD_GIT_DIRTY"
elif [ -n "$(git -C "$SRC" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    DIRTY=YES
else
    DIRTY=NO
fi

# During an Xcode build, write into a bundled stamp resource. Xcode may
# regenerate Info.plist after script phases, so the resource is canonical.
RESOURCE_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}"
if [ -z "${TARGET_BUILD_DIR}" ]; then
    echo "stamp_git_sha: no build product directory (SHA=$SHA dirty=$DIRTY) — skipping"
    exit 0
fi

if [ -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]; then
    RESOURCE_DIR="${TARGET_BUILD_DIR}"
fi
mkdir -p "$RESOURCE_DIR"
STAMP_PLIST="${RESOURCE_DIR}/GitStamp.plist"

/usr/libexec/PlistBuddy -c "Clear dict" "$STAMP_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :GitSHA string $SHA" "$STAMP_PLIST"
/usr/libexec/PlistBuddy -c "Add :GitDirty string $DIRTY" "$STAMP_PLIST"

echo "stamp_git_sha: GitSHA=$SHA GitDirty=$DIRTY → $STAMP_PLIST"
