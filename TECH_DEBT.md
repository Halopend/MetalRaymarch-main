# Threshold — Tech Debt Register (2026-07-01)

Companion to [`PERF_PUSH.md`](PERF_PUSH.md) (ALL performance debt lives there — not
duplicated here) and [`Context/CLEANUP_AUDIT.md`](Context/CLEANUP_AUDIT.md) (132
verified dead-code/duplication items — referenced as one backlog entry here).
Scored with the same formula: **Priority = (Impact + Risk) × (6 − Effort)**, each 1–5.

Ground truth for this register: repo-wide scan 2026-07-01 (file sizes, markers,
force-risk, tests, concurrency annotations, artifacts) + this session's incidents.

## Health summary

The codebase is unusually clean for its size: **zero TODO/FIXME/HACK markers**, no
`try!`, 2 `as!` (tooling), no third-party dependencies at all, and a verified
cleanup audit already exists. The debt concentrates in four places:

1. **Silent-corruption seams** — the `Uniforms` struct is hand-constructed at 3 sites
   with order-sensitive 50-param inits, and its embedded shader-source copy
   (`EmbeddedMetalSources.swift`) drifts silently unless a manual script is run.
   Both bit us on 2026-07-01.
2. **Test coverage is persistence-shaped** — 7 test files (1,249 lines) cover
   presets/catalogs/decode well, but the historically bug-prone **parameter layering**
   (slider base × gesture offset × music offset × animation playback) has zero
   coverage despite 3+ documented regressions in that exact math.
3. **No CI** — everything (build, tests, QL render check, perf gate) is
   run-when-remembered.
4. **The `RenderSettings` god object** (3,912 lines, ~405 locked properties,
   526 `withLock` sites) — real, but a big-bang split scores poorly; chip at it.

## Register — scored

| # | Item | Type | I | R | E | P | Evidence / why |
|---|------|------|---|---|---|---|----------------|
| 1 | **Embed-freshness test**: a unit test asserting `EmbeddedMetalSources.shaderTypesH` (+ shaders) matches the on-disk headers, so a stale regen fails the test instead of silently mis-laying-out structs in the runtime shader compiler | Infra | 3 | 4 | 1 | 35 | Hit live 2026-07-01: `benchAblate` field added → embed stale → struct-layout mismatch risk for every runtime-compiled `.threshfx`. Currently enforced only by a comment. |
| 2 | **Single `Uniforms` builder**: one shared function feeding the 3 construction sites (Mac renderer / visionOS `RendererGameState` / QL `HeadlessRenderer`); kills order-sensitivity and the copy-drift (safety-bubble conditionals already duplicated 3×) | Code | 3 | 4 | 2 | 28 | Adding ONE field today required edits in 3 files, hit a type-checker blowup, and a field-order trap. 8 memberwise call sites found by scan. |
| 3 | **Parameter-layering regression tests**: pure-logic tests for base×gesture×music×animation composition (recenter, offset-around-animation, stomp cases) | Test | 4 | 4 | 3 | 24 | 3+ documented regressions in exactly this math (music base stomps, gesture override gaps, music-dies-during-playback). All fixed by hand, none pinned by a test. |
| 4 | **Benchmark persistence isolation**: suppress `SettingsPersistence.save` when `BenchmarkMode.isActive` | Infra | 2 | 3 | 2 | 20 | Harness runs silently rewrote the user's persisted app settings (shadows=false leaked into later runs AND the user's real app state). |
| 5 | **CI skeleton**: build (Mac + visionOS schemes) + unit tests + QL render check + the PERF_PUSH Phase-0 perf gate, on push | Infra | 3 | 3 | 3 | 18 | No CI exists; the embed test (#1) and perf gate only pay off if something runs them. macOS runners suffice (build+tests); perf gate stays local-Mac if runner GPU variance is too high. |
| 6 | **Concurrency-safety pass**: audit the 6 `nonisolated(unsafe)` globals + 10 `@unchecked Sendable`; keep the documented racy-by-design gates (e.g. `isAppActive`) but annotate WHY per-site; fix the undocumented ones | Code | 3 | 3 | 3 | 18 | Cross-thread mutable globals on `AppModel` accessed from render + main threads. Some are deliberate perf choices (documented), others are drift. Swift-6 strict concurrency will force this eventually. |
| 7 | **Execute CLEANUP_AUDIT backlog** (132 verified items: dead per-pixel shader fields, duplicated adapters/interpolators, debug prints) | Code | 2 | 2 | 2 | 16 | Already adversarially verified; Tier-1 shader items even trim per-pixel GPU work. Do opportunistically when touching each file. |
| 8 | **ControlSpec tail** (~290 range/default definition sites for ~63 controls; P0 done for 9 core controls) | Code | 3 | 3 | 4 | 12 | Already produced shipped UI bugs (dead slider strips, disagreeing mins). Mechanical but wide. |
| 9 | **Untrack `default.profraw`** + `*.profraw` in .gitignore | Infra | 1 | 1 | 1 | 10 | Binary churn artifact in every commit since benchmarking began. |
| 10 | **Sphere-system unification** (3 parallel systems; MSP remnants; Disguise/Vampire negative-MinDistance oddity) | Arch | 2 | 2 | 4 | 8 | Documented seam map exists; wait until a feature needs it. |
| 11 | **Param-catalog Slice 8** (route-driven UI) | Arch | 2 | 2 | 4 | 8 | Deliberately deferred — needs on-device visual pass, low consolidation value. |
| 12 | **`RenderSettings` god-object split** | Arch | 4 | 3 | 5 | 7 | Real pain (405 locked props, 526 lock sites) but big-bang refactor is high-risk on an actively-edited tree. Strategy: extract cohesive sub-objects opportunistically (the animation-phase block, the color-scheme block) whenever a feature touches them; never a dedicated rewrite. |
| 13 | **Module architecture stages 3+5** (FractalType classes, menu state machine) | Arch | 2 | 1 | 4 | 6 | Nice-to-have; revisit when adding fractal types gets painful. |

Not-debt, deliberately kept: gated experimental features (custom scenes opt-in),
SharePlay backend (retained on purpose), Buddhabrot (keeper), the racy-by-design
benchmark gates (documented), zero third-party deps (a feature, not a gap).

## Phased plan (alongside feature work)

**Phase A — the afternoon of quick wins (~1 session):** #9, #1, #4.
Untrack profraw; write the embed-freshness test; gate persistence writes behind
`!BenchmarkMode.isActive`. All three are small, none can regress visuals.

**Phase B — seam hardening (1–2 sessions):** #2, #3, then #5.
The Uniforms builder makes future shader-struct evolution one-site; the layering
tests pin the most re-broken math in the app; CI makes both permanent. Pairs
naturally with PERF_PUSH Phase 0 (perf gate) — one CI job runs both.

**Phase C — opportunistic (ongoing, no dedicated sessions):** #7, #8, #6, #12.
Rule: when a file is already open for feature work, burn its CLEANUP_AUDIT items
and extract its RenderSettings block if one applies. Concurrency annotations get
fixed per-file the same way.

**Parked (revisit on demand):** #10, #11, #13.

## Standing rules

- Perf debt goes to `PERF_PUSH.md`, never here — one register per concern.
- Dead code found during work: add to `CLEANUP_AUDIT.md` if uncertain, delete if verified.
- Every "temporary" measurement affordance (benchmark gates, ablation switches)
  must be env/flag-gated and default-off — same rule as perf toggles.
