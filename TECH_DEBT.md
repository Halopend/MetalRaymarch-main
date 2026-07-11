# Threshold — Tech Debt Register (updated 2026-07-09)

> **2026-07-09 refresh** (counts re-verified against the tree; supersedes the
> 2026-07-04 numbers below): `RenderSettings.swift` is **4,571 lines / 489 lock
> sites**; **16** test files; concurrency markers **66 `nonisolated(unsafe)` +
> 47 `@unchecked Sendable`**. **Closed since:** #17 (`handEffectsBeta` fully
> removed — 0 code hits) and #2 (a shared `Uniforms` builder landed —
> `Threshold/Rendering/Core/UniformsBuilder.swift`, all three call sites now call
> `assembleUniforms`; verified 2026-07-10 by the clean 94-test run, all three app
> builds, and the 37-scene Quick Look render check). **#8d superseded:** the by-value occupancy concern was
> resolved by moving the hand field, space-warp stack, and Env Scrunch behind
> pointers — the `static_assert`s are now `FractalParams ≤ 160`, `Uniforms` /
> `TileUniforms ≤ 2048` (`Shaders.metal:628`, `ShaderTypes.h`). All 304/320/1936 B
> figures below are historical. The 2026-07-07 audit in
> [`Context/TECH_DEBT_AUDIT_2026-07-07.md`](Context/TECH_DEBT_AUDIT_2026-07-07.md)
> is the more current companion.


Companion to [`PERF_PUSH.md`](PERF_PUSH.md) (ALL performance debt lives there — not
duplicated here) and [`Context/CLEANUP_AUDIT.md`](Context/CLEANUP_AUDIT.md) (132
verified dead-code/duplication items — referenced as one backlog entry here).
Scored with the same formula: **Priority = (Impact + Risk) × (6 − Effort)**, each 1–5.

Ground truth: repo-wide scan 2026-07-01 + session incidents 2026-07-01/02, **re-verified
against the tree 2026-07-04** (every item's status re-checked; counts refreshed; new items
#14–#17 from an adversarial scan of the hands/arms + legacy-toggle work and the current
working tree). **Second delta scan 2026-07-04 (later, PM)** over the still-uncommitted
Environment Scrunch feature (new `EnvironmentSDF.swift` + expanded persistence tests):
mostly clean — persistence was originally device-local-by-design and pinned
(`envScrunchStaysDeviceLocal`, same family as #14). **REVERSED 2026-07-05**: the scrunch
PARAMETERS (mode/strength/reach/contain) are now scene-authored and round-trip through
`FractalPreset` (pinned by `envScrunchRoundTrip`); only the scanned-room SDF grid stays
live/device-local. The RenderSettings wiring follows the
established locked-accessor + snapshot + apply pattern (did **not** add a 4th `Uniforms`
drift site — #2 still 3), and the new `EnvironmentSDFGrid: @unchecked Sendable` is
documented (Mutex-swap publication). It added **one new item (#18)** and **materialized
#8d** (the `FractalParams` gate was raised 304→320 B in this tree). **Third delta scan
2026-07-04 (evening)** over the containment addition (Contain hard/blend clip to the
scanned room AABB; tree now 1,755 insertions / 17 files): persistence + UI + harness all
follow pattern and the device-local pin was extended in the same commit; but it **widened
#18** (AABB accumulation + world→grid conversion also untested) and surfaced **#19** (the
shader's hardcoded `2.0f` far-clamp is comment-lockstepped to `EnvironmentSDFGrid.clampFar`).

## Health summary

Still unusually clean for its size: **zero TODO/FIXME/HACK markers** (4 `XXX` are the
`DE_XXX` codegen-macro placeholder, not debt), no `try!`, no third-party dependencies.
Refreshed counts (**2026-07-09**): `RenderSettings` is now **4,571 lines / 489 lock
sites**; tests are **16 files** now; concurrency markers **66 `nonisolated(unsafe)` +
47 `@unchecked Sendable`** across ~19 files.

The debt still concentrates in the same four places (Uniforms seams, persistence-shaped
tests, no CI, the RenderSettings god object) — **plus one new strategic fact**:
[`Context/REBUILD_ARCHITECTURE.md`](Context/REBUILD_ARCHITECTURE.md) (2026-07-04,
uncommitted) designs a ground-up rebuild whose three core systems (ParameterCatalog,
Modulation Engine, Shader IR) would subsume arch items #8/#10/#12/#13 wholesale. Until a
go/no-go exists (#16), **don't invest in big in-place arch refactors**; seam-hardening
(tests, builders, CI) pays off on either path — the tests double as migration pins.

## Register — scored

| # | Item | Type | I | R | E | P | Status / evidence |
|---|------|------|---|---|---|---|----------------|
| 1 | ~~**Automatic embed generation + freshness test**~~ | Infra | – | – | – | – | **DONE 2026-07-10**: every app/Quick Look target generates `EmbeddedMetalSources.swift` into its own Derived Sources directory from an input file list, deleting the 6,506-line checked-in copy and making stale runtime shader input impossible. `EmbedFreshnessTests` still pins every block byte-for-byte and checks generator coverage. |
| 2 | ~~**Single `Uniforms` builder**~~ | Code | – | – | – | – | **DONE + VERIFIED 2026-07-10**: `Threshold/Rendering/Core/UniformsBuilder.swift` holds one `assembleUniforms(settings:effectiveScale:time:platform:)` + a `UniformsPlatformInputs` struct. All three sites (`RendererGameState`, Mac `RaymarchRenderView.makeUniforms`, QL `HeadlessRenderer.packUniforms`) assemble via it, so the ~76-field list + duplicated derived math live once. Verified by `build.sh test` (94 tests), macOS/visionOS/iPadOS builds, and `ql_render_check.sh` (37 scenes). |
| 3 | **Parameter-layering regression tests**: pure-logic tests for base×gesture×music×animation composition (recenter, offset-around-animation, stomp cases) | Test | 4 | 4 | 3 | 24 | **OPEN.** 3+ documented regressions in exactly this math; still zero coverage. Doubles as a behavior pin if the rebuild (#16) proceeds — its Modulation Engine reimplements this exact composition. |
| 18 | **`EnvironmentSDF` geometry math has zero tests**: `pointTriangleDistance` (Ericson 7-region barycentric — a classic bug farm), `bake`/`bakeSynthetic` grid indexing, `parseSynthetic` string parsing, **and (widened 2026-07-04 evening) the containment geometry** — surface-AABB accumulation in both bakes + the world→grid clamp conversion in `makeEnvScrunchParams`. The feature is Mac-verified via `THRESHOLD_SYNTHETIC_ENV` but **NOT device-verified — the visionOS mesh-bake path has literally never executed** | Test | 3 | 3 | 2 | 24 | **NEW 2026-07-04 PM, widened evening.** All PURE functions (only `bake` needs an `MTLDevice` for the output buffer) — golden-value unit tests are ~1 sitting and would headlessly exercise the same CPU bake the untested device path uses. A wrong barycentric region = wrong scrunch; a wrong AABB = containment clips at the wrong wall. Blast radius is bounded (the shader clamps out-of-band samples to "no effect"; containment only ever *removes* geometry), which is why R=3 not 4. The containment A/B PNGs (contain off/hard/blend, synthetic room) exist as manual pins in the scratchpad — a golden-image harness job would make them durable. Fold #19 into the same sitting. |
| 19 | **`clampFar` comment-enforced lockstep**: `Shaders.metal` hardcodes the out-of-grid return as `2.0f * es.metersToModel` with a "keep in sync with `EnvironmentSDFGrid.clampFar`" comment. Change the Swift constant without the shader and Shell mode silently skins the grid boundary instead of cutting beyond it. Fix: carry `farClampModel` in `EnvScrunchParams` (there is padding slack in the three `vector_float3` slots, or accept +16 B) and delete the comment-contract | Code | 2 | 2 | 1 | 20 | **NEW 2026-07-04 evening.** Same disease as #2 (comment-enforced cross-file lockstep), caught while the code is a day old. Single-sitting; pairs with #18's test sitting since a unit test on `envScrunchSample`'s out-of-grid behavior would also pin it. |
| 14 | ~~**`objectCutout*` preset persistence asymmetry**~~ | Test | – | – | – | – | **DECIDED + PINNED 2026-07-04**: cutouts are **device-local by design** (they describe the user's physical room, not the scene — same family as the safety bubble and Quality accel fields; they also persist per-device via their own UserDefaults keys). Pinned by `objectCutoutsStayDeviceLocal` (asserts no `objectCutout` key ever serializes into `FractalPreset` AND scene apply never stomps the live device config); test header documents the boundToSpace-vs-cutout rationale. |
| 8d | ~~**`FractalParams`/`Uniforms` size watch**~~ | Perf-adjacent | – | – | – | – | **DONE 2026-07-04**: `static_assert` gates added — `FractalParams ≤ 304 B` next to its definition in `Shaders.metal` (with a do-not-bump-without-harness-measurement comment), `Uniforms ≤ 1856` / `TileUniforms ≤ 1888` / `FormulaParams ≤ 176` at the end of `ShaderTypes.h` (Metal-only guard). Asserts also fire in every runtime `.threshfx` compile via the embeds. **⚠️ Measured finding: `FractalParams` is 304 B by value — ABOVE the 272 B that caused the documented occupancy collapse** (hand+forearm fields, 4×float4 = 80 B). Logged as a candidate for the PERF_PUSH backlog: pack forearms/hands or move them behind the pointer like `spaceWarpOps`. **↑ 2026-07-04 PM: gate RAISED 304→320 B** — Env Scrunch added `EnvScrunchParams` by value (Uniforms gate 1856→1888→**1936**, TileUniforms 1888→1920→**1968** after containment grew the struct 112→160 B; those live in `constant` space, so growth there is awareness-only). The grid *itself* is correctly behind a bindless pointer (`gpuAddress`). **RESOLVED 2026-07-09:** the hand field, space-warp stack, and Env Scrunch were all moved behind pointers, dropping by-value `FractalParams` well under the 272 B collapse size — the `static_assert` is now `FractalParams ≤ 160` (`Shaders.metal:628`), and `Uniforms` / `TileUniforms` are gated `≤ 2048` (`ShaderTypes.h`; both live in `constant` space). The 304/320/1936/1968 B figures above are historical. |
| 16 | ~~**Rebuild go/no-go record**~~ | Arch | – | – | – | – | **DONE 2026-07-04**: `Context/REBUILD_ARCHITECTURE.md` committed with a PROPOSED status block + explicit decision inputs (deferred-shading outcome, next parameter-heavy feature's wiring cost, Vision Pro baseline). #10–13 stay parked until the call is made. |
| 5 | **CI skeleton**: build (Mac + visionOS schemes) + unit tests + QL render check + perf gate, on push | Infra | 3 | 3 | 2 | 24 | **OPEN, but cheaper now** (E 3→2): `Scripts/perf-gate.sh` and `Scripts/ql_render_check.sh` exist as ready-made steps; still nothing runs them automatically (no `.github/`). Absorbs #8a/#8c as steps. |
| 4 | ~~**Benchmark persistence isolation**~~ | Infra | – | – | – | – | **ALREADY DONE** (register was stale): `SettingsPersistence.benchmarkHermetic` gates BOTH `save` and `load` on the `THRESHOLD_BENCHMARK` env (`SettingsPersistence.swift:131` — checks the env directly, not `BenchmarkMode`, so the QL source closure still compiles; the 2026-07-04 re-verify grep missed it for that reason). |
| 8a | **QL source-closure drift**: derive `wire_quicklook.rb SHARED_SOURCES` from the pbxproj target, or add a freshness check next to #1 | Infra | 2 | 3 | 2 | 20 | **OPEN.** Hit 2026-07-02 (`HandAttractionConfig.swift` missing → QL gate broke mid-session). |
| 8b | **Config Codable-tolerance rule**: audit remaining `cfg.*` domain configs for `decodeIfPresent`; add a test decoding each config from `{}` | Test | 2 | 3 | 2 | 20 | **OPEN.** Two configs fixed by hand 2026-07-02; failure mode is silent per-domain resets. |
| 8c | **Bundled-resource flattening workaround**: fold `Scripts/mark_mixed_scenes.py` check into #5's CI (fail if a file under `Examples/Mixed` lacks `mixedModeScene: true`) | Infra | 2 | 2 | 1 | 20 | **OPEN.** |
| 15 | ~~**Legacy compute-cache toggle is trap code**~~ | Code | – | – | – | – | **DONE 2026-07-10:** removed the nearest-pipeline mismatch toggle, cache-selection branch, settings persistence, and UI. The scene-persisted `deIterationMismatch` δ remains the single intentional recreation path. |
| 17 | ~~**`handEffectsBeta` gate scatter**~~ | Code | – | – | – | – | **DONE** (verified 2026-07-09 + 07-07 audit): `handEffectsBeta` returns **0 code hits** — the beta gate was fully removed, so there is nothing left to centralize. |
| 6 | **Concurrency-safety pass**: audit the 66 `nonisolated(unsafe)` + 47 `@unchecked Sendable` occurrences; keep documented racy-by-design gates, annotate WHY per-site, fix the drift | Code | 3 | 3 | 3 | 18 | **OPEN** (counts refreshed 2026-07-09; spread ~19 files). Swift-6 strict concurrency will force this eventually. |
| 7 | **Execute CLEANUP_AUDIT backlog** (132 verified items) | Code | 2 | 2 | 2 | 16 | **OPEN.** Do opportunistically when touching each file. |
| 8 | **ControlSpec tail** (~290 range/default definition sites for ~63 controls; P0 done for 9) | Code | 3 | 3 | 4 | 12 | **OPEN — keeps growing:** bound-to-space and every envScrunch knob repeat the pattern — e.g. `envScrunchContainFeather` default `0.1` + range `0...0.5` now live at 4 sites (RenderSettings backing, accessor clamp, QualityConfig default+clamp+decode, UI slider range) with no named constant. Subsumed by the rebuild's ParameterCatalog if #16 = go. |
| 9 | ~~**Untrack `default.profraw`** + `*.profraw` in .gitignore~~ | Infra | – | – | – | – | **DONE** (verified 2026-07-04: `.gitignore:17-18`, file untracked). |
| 10 | **Sphere-system unification** (3 parallel systems) | Arch | 2 | 2 | 4 | 8 | **PARKED pending #16** — rebuild's Shader IR replaces this seam outright. |
| 11 | **Param-catalog Slice 8** (route-driven UI) | Arch | 2 | 2 | 4 | 8 | **PARKED pending #16.** |
| 12 | **`RenderSettings` god-object split** (now 4,571 lines / 489 lock sites) | Arch | 4 | 3 | 5 | 7 | **PARKED pending #16** — this is exactly what ParameterCatalog + Modulation Engine dissolve. If no-go: keep the opportunistic-extraction rule, never a big bang. |
| 13 | **Module architecture stages 3+5** | Arch | 2 | 1 | 4 | 6 | **PARKED pending #16.** |

Not-debt, deliberately kept: gated experimental features (custom scenes opt-in), SharePlay
backend, Buddhabrot (keeper), racy-by-design benchmark gates (documented), zero third-party
deps. Noted but assumed intentional: `Backup/` scene backups tracked in git (9 data files —
move to ignore/LFS only if not wanted in history); two stale Windsurf worktrees +
`.claude/worktrees/blissful-gould-ba763c` (local disk clutter, `git worktree prune`-able,
not repo debt).

## Phased plan (alongside feature work)

**Phase A — ✅ COMPLETE 2026-07-04:** #1, #14, #8d, #16 executed this session; #4
turned out to be already done (`benchmarkHermetic`), #9 was done earlier. Byproduct
finding: `FractalParams` measured **304 B by value** (> the documented 272 B collapse
size) — flagged in #8d for a harness measurement. **Later the same day the Env Scrunch
tree pushed it to 320 B** (gate raised to match); the measurement is now overdue and moves
to Phase B / PERF_PUSH.md.

**Phase B — seam hardening (1–2 sessions):** #2, #3, **#18 (+#19 same sitting)**, then #5.
The Uniforms builder has now bitten **three times in three days** — top code-debt item.
The layering tests (#3) pin the most re-broken math in the app; the EnvironmentSDF tests
(#18) pin brand-new, never-device-run geometry math — both are cheap pure-function suites
and both become migration pins for the rebuild. CI is cheaper than when first scored (gate
scripts already exist) and absorbs #8a/#8b/#8c as steps; pairs with PERF_PUSH Phase 0 — one
job runs both. **Also now:** escalate #8d's `FractalParams` = 320 B to PERF_PUSH.md for the
overdue occupancy measurement (the gate was raised again this session).

**Phase C — opportunistic (ongoing, no dedicated sessions):** #7, #8, #6, #15, #17.
Rule: when a file is already open for feature work, burn its CLEANUP_AUDIT items and fix
its concurrency annotations. #15/#17 are single-sitting fixes whenever hands or the
legacy toggle are touched next.

**Parked pending the #16 decision:** #10, #11, #12, #13 — all dissolved by the rebuild
if it proceeds; re-activate here only on a no-go.

## Standing rules

- Perf debt goes to `PERF_PUSH.md`, never here — one register per concern.
- Dead code found during work: add to `CLEANUP_AUDIT.md` if uncertain, delete if verified.
- Every "temporary" measurement affordance (benchmark gates, ablation switches)
  must be env/flag-gated and default-off — same rule as perf toggles.
- New persisted field ⇒ same-commit round-trip test (or an explicit device-local
  exclusion noted in the test) — #14 is what skipping this looks like.
