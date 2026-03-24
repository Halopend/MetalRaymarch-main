#!/usr/bin/env bash
set -euo pipefail

# Guardrail: prevent accidental duplicate Swift source copies like "Foo 2.swift".
# Only fails for files that both exist on disk and are tracked by git.

matches=()
while IFS= read -r path; do
  if git ls-files --error-unmatch "$path" >/dev/null 2>&1; then
    matches+=("$path")
  fi
done < <(find Threshold -type f -name '* 2.swift' | sort)

if (( ${#matches[@]} > 0 )); then
  echo "❌ Duplicate-suffix Swift files detected (must be removed):" >&2
  printf '%s\n' "${matches[@]}" >&2
  exit 1
fi

echo "✅ No duplicate-suffix Swift files found."
