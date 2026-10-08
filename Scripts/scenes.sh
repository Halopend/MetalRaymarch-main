#!/usr/bin/env bash
# Convert a scene folder using the exact codec compiled into the app/Quick Look.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    DEVELOPER_DIR="$(bash "$SCRIPT_DIR/select_developer_dir.sh")"
    export DEVELOPER_DIR
fi
TASK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/threshold-scenes.XXXXXX")"
trap 'rm -rf "$TASK_DIR"' EXIT
{
    printf 'import Foundation\nimport Compression\nimport CryptoKit\n'
    awk '/^\/\/ MARK: - Scene file compression/{found=1} found' "$SCRIPT_DIR/../Threshold/Parameters/FractalPreset.swift"
    cat "$SCRIPT_DIR/scene_cli.swift"
} > "$TASK_DIR/main.swift"
xcrun swift -module-cache-path "$TASK_DIR/modules" "$TASK_DIR/main.swift" "$@"
