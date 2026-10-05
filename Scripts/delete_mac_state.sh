#!/usr/bin/env bash
# Permanently remove local macOS state for Threshold and its Quick Look extensions.
# Run without arguments to preview; run with --delete to remove the listed paths.
# This does not touch iCloud Drive, exported files, or the app installation.

set -euo pipefail

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--delete" ) ]]; then
    echo "Usage: $0 [--delete]" >&2
    exit 2
fi

library="${HOME:?}/Library"
ids=(
    com.puppypower.Threshold
    com.puppypower.Threshold.QLPreview
    com.puppypower.Threshold.QLThumbnail
)
paths=()

for id in "${ids[@]}"; do
    paths+=(
        "$library/Containers/$id"
        "$library/Containers/$id.dataless"
        "$library/Containers/$id.partial"
        "$library/Application Scripts/$id"
        "$library/Preferences/$id.plist"
        "$library/Caches/$id"
        "$library/Application Support/$id"
        "$library/Saved Application State/$id.savedState"
        "$library/HTTPStorages/$id"
        "$library/WebKit/$id"
        "$library/Logs/$id"
    )
done

existing=()
for path in "${paths[@]}"; do
    if [[ -e "$path" || -L "$path" ]]; then
        existing+=("$path")
    fi
done

if [[ ${#existing[@]} -eq 0 ]]; then
    echo "No matching local Threshold files found."
    exit 0
fi

echo "Local Threshold files:"
printf '  %s\n' "${existing[@]}"

if [[ ${1:-} != "--delete" ]]; then
    echo
    echo "To permanently delete these files, run: $0 --delete"
    exit 0
fi

if pgrep -xq Threshold 2>/dev/null; then
    echo "Quit Threshold before deleting its state." >&2
    exit 1
fi

access_help() {
    cat >&2 <<'EOF'
macOS is blocking access to a Threshold app container.
In System Settings > Privacy & Security > Full Disk Access, enable the app
running this shell (Terminal, iTerm, or Codex). Quit and reopen that app, then
run this script again. sudo does not override macOS privacy protection.
EOF
}

# Check protected containers before deleting any preferences or other state.
# -w catches the common macOS app-container denial, even when POSIX ownership
# and mode bits appear to allow writes.
for path in "${existing[@]}"; do
    if [[ "$path" == "$library/Containers/"* && ! -w "$path" ]]; then
        echo "Cannot write: $path" >&2
        access_help
        exit 1
    fi
done

if [[ ! -t 0 ]]; then
    echo "Run --delete in a terminal so you can confirm the deletion." >&2
    exit 1
fi

echo
read -r -p 'Type DELETE to permanently remove these files: ' confirmation
if [[ "$confirmation" != "DELETE" ]]; then
    echo "Cancelled."
    exit 1
fi

# Delete the protected containers first. If macOS denies access despite the
# check above, leave the remaining local paths and preference domains alone.
for path in "${existing[@]}"; do
    [[ "$path" == "$library/Containers/"* ]] || continue
    if rm -rf -- "$path"; then
        echo "Deleted: $path"
    else
        echo "Failed: $path" >&2
        access_help
        exit 1
    fi
done

# Ask the preferences daemon to forget these exact app domains, including any
# values it still holds in memory. Remove the on-disk files afterwards.
for id in "${ids[@]}"; do
    if defaults read "$id" >/dev/null 2>&1; then
        defaults delete "$id" >/dev/null
    fi
done

failed=0
for path in "${existing[@]}"; do
    [[ "$path" == "$library/Containers/"* ]] && continue
    if rm -rf -- "$path"; then
        echo "Deleted: $path"
    else
        echo "Failed: $path" >&2
        failed=1
    fi
done

if [[ "$failed" -ne 0 ]]; then
    echo "Some files could not be deleted. Check Terminal's file access permissions." >&2
    exit 1
fi

echo "Local Threshold state deleted."
