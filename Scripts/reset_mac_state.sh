#!/usr/bin/env bash
# Reset the macOS app's persisted state so the next launch behaves as if the
# app had just been uninstalled and installed again — the first-launch
# onboarding ("Welcome" window), the storage choice prompt, and an empty scene
# library all come back.
#
# WHY ONE DIRECTORY IS ENOUGH: Threshold.app is App-Store-sandboxed
# (com.apple.security.app-sandbox in ThresholdMac.entitlements), so every
# persisted artifact resolves INTO its container when the app runs:
#   • SharedPreferences (hasCompletedIntroOnboarding, Storage.mode,
#     Storage.hasChosenMode, AnalyticsEnabled, audio-launch preference,
#     gesture/render settings…) → Data/Library/Preferences/*.plist
#   • The library store (Scenes / Music Presets / Animations / Settings /
#     Formulas) and the always-local Backups → Data/Documents/
#   • Pipeline binary-archive caches → Data/Library/Application Support/
#   • Saved window/scene state → Data/Library/Saved Application State/
#   • Caches / WebView / logs → Data/Library/*
# Non-container state that can still affect a "fresh" run:
#   • Saved Application State in ~/Library/Saved Application State/
#   • Any pre-sandbox defaults registered in the user's real preference store
#
# The containers are MOVED into .build/reset-backups/<timestamp>/ rather than
# deleted, so a bad test run costs you nothing — restore with --restore
# (or delete them with --purge-backups when you are done testing).
#
# Usage:
#   Scripts/reset_mac_state.sh                 # quit app + stow all state away
#   Scripts/reset_mac_state.sh --launch        # …then launch the built app
#   Scripts/reset_mac_state.sh --restore       # put the newest backup back
#   Scripts/reset_mac_state.sh --purge-backups # delete all stowed backups
#   Scripts/reset_mac_state.sh --privacy       # also reset TCC mic permission
#
# The script refuses to run while the app process is alive unless it can
# terminate it; quit Threshold first for the cleanest result.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

BACKUP_ROOT="$REPO_ROOT/.build/reset-backups"

# Bundle ids whose state belongs to a fresh-install test. The typo'd
# "com.pupppower.thresholdb3" container from development history is left
# untouched on purpose (it is never read by current builds).
MAIN_ID="com.puppypower.Threshold"
IDS=("$MAIN_ID" "$MAIN_ID.QLPreview" "$MAIN_ID.QLThumbnail")

CONTAINERS_BASE="$HOME/Library/Containers"
SAVED_STATE_BASE="$HOME/Library/Saved Application State"

app_running() {
    pgrep -xq Threshold 2>/dev/null
}

terminate_app() {
    if app_running; then
        echo "Quitting a running Threshold instance…"
        osascript -e 'tell application "Threshold" to quit' >/dev/null 2>&1
        sleep 2
        if app_running; then
            echo "Still running — sending TERM."
            pkill -x Threshold 2>/dev/null
            sleep 1
        fi
        if app_running; then
            echo "ERROR: Threshold is still running; cannot reset live state." >&2
            exit 1
        fi
    fi
}

stow() {
    # $1 = source path, $2 = backup subdir bucket
    [[ -e "$1" ]] || return 0
    local dest="."
    mkdir -p "$BACKUP_ROOT/$STAMP/$2"
    dest="$BACKUP_ROOT/$STAMP/$2/$(basename "$1")"
    if mv "$1" "$dest" 2>/dev/null; then
        echo "  stowed: $1"
    else
        echo "  FAILED to stow: $1" >&2
    fi
}

do_reset() {
    local STAMP
    STAMP=$(date '+%Y%m%d-%H%M%S')
    terminate_app

    echo "Stowing app state into $BACKUP_ROOT/$STAMP"
    for id in "${IDS[@]}"; do
        stow "$CONTAINERS_BASE/$id" "containers/$id"
        # Companion dirs macOS creates in .dataless/.partial variants occasionally.
        stow "$CONTAINERS_BASE/$id.dataless" "containers/$id"
    done
    stow "$SAVED_STATE_BASE/$MAIN_ID.savedState" "saved-state"

    # Pre-sandbox / agent-visible preference domains. The QL appex domains are
    # cleared too so a QuickLook previewer can't resurrect stale library state.
    for id in "${IDS[@]}"; do
        if defaults read "$id" >/dev/null 2>&1; then
            defaults delete "$id" >/dev/null 2>&1 && echo "  cleared defaults: $id"
        fi
    done

    if [[ "${RESET_PRIVACY:-0}" == "1" ]]; then
        tccutil reset Microphone "$MAIN_ID" 2>/dev/null && echo "  reset TCC microphone permission for $MAIN_ID"
    fi

    echo "Done. The next launch starts with: no onboarding completion, no storage"
    echo "choice, an empty library, and factory render settings."
    echo "Restore the previous state any time with:"
    echo "  Scripts/reset_mac_state.sh --restore  (newest backup: $STAMP)"
}

do_restore() {
    # Restore the newest backup set unless one was passed on argv.
    local newest
    newest=$(ls -dt "$BACKUP_ROOT"/*/ 2>/dev/null | head -1)
    [[ -n "$newest" ]] || { echo "No backups to restore in $BACKUP_ROOT" >&2; exit 1; }
    echo "Restoring from ${newest%/}"
    terminate_app
    while IFS= read -r -d '' src; do
        local rel dest_base
        rel="${src#${newest%/}}"
        # rel looks like "containers/com.puppypower.Threshold"
        dest_base=$(dirname "$rel")
        mkdir -p "$HOME/${dest_base}"
        ln -sfn "$src" "$HOME/$rel" 2>/dev/null ||
            cp -R "$src" "$HOME/$rel" ||
            { echo "  FAILED: $src" >&2; continue; }
        echo "  restored: $rel"
    done < <(find "$newest" -mindepth 2 -maxdepth 2 -print0)
    echo "Done. Relaunch Threshold to see the restored state."
}

do_purge() {
    if [[ -d "$BACKUP_ROOT" ]]; then
        rm -rf "$BACKUP_ROOT"
        echo "Deleted all stowed backups under $BACKUP_ROOT"
    else
        echo "No backups present."
    fi
}

launch_built_app() {
    local app=".build/DerivedData/Build/Products/Debug/Threshold.app"
    [[ -d "$app" ]] || {
        echo "No app at $app — run: Scripts/build.sh mac" >&2
        exit 1
    }
    echo "Launching $app"
    open "$app"
}

case "${1:-}" in
    --launch)   shift; do_reset "$@"; launch_built_app ;;
    --restore)  shift; do_restore "$@" ;;
    --purge-backups) do_purge ;;
    --privacy)  RESET_PRIVACY=1 do_reset ;;
    ""|--reset) do_reset ;;
    *) echo "Usage: $(basename "$0") [--launch|--restore|--purge-backups|--privacy]" >&2; exit 2 ;;
esac