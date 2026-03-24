#!/usr/bin/env bash
set -euo pipefail

# Guardrail: direct UserDefaults access is only allowed in persistence modules.
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
  echo "❌ Disallowed direct UserDefaults.standard usage detected:" >&2
  printf '%s\n' "${violations[@]}" >&2
  echo "Use SettingsPersistence or another typed persistence facade instead." >&2
  exit 1
fi

echo "✅ UserDefaults.standard usage restricted to persistence modules."
