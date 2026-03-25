#!/usr/bin/env bash
set -euo pipefail

# Guardrail: direct UserDefaults access is restricted to persistence modules.
# Feature modules should use typed persistence APIs (e.g. SettingsPersistence).

allow_pattern='^(Threshold/Parameters/SettingsPersistence.swift|Threshold/Parameters/RenderSettings.swift|Threshold/Parameters/GestureSensitivityStore.swift|Threshold/Gestures/FractalDefaultsStore.swift|Threshold/App/UISettingsCache.swift|Threshold/App/AppModel.swift|Threshold/Analytics/UsageAnalytics.swift|Threshold/Animation/AnimationManager.swift)$'

mapfile -t hits < <(rg -n --glob '*.swift' 'UserDefaults\.standard' Threshold \
  | cut -d: -f1 \
  | sort -u)

violations=()
for file in "${hits[@]}"; do
  if [[ ! "$file" =~ $allow_pattern ]]; then
    violations+=("$file")
  fi
done

if (( ${#violations[@]} > 0 )); then
  echo "❌ Disallowed direct UserDefaults.standard usage detected outside persistence modules:" >&2
  printf '%s\n' "${violations[@]}" >&2
  echo "Use SettingsPersistence (or a domain persistence facade) instead." >&2
  exit 1
fi

echo "✅ UserDefaults.standard usage restricted to approved persistence modules."
