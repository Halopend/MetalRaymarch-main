# Threshold — Tech Debt Register (updated 2026-07-18)

> **2026-07-18 progression refresh:** #5 (CI) and #8c (Mixed-scene resource
> validation) are closed. The active order now lives in [`ROADMAP.md`](ROADMAP.md),
> while this file remains the evidence-backed debt register. Current branch metrics:
> `RenderSettings.swift` is **4,656 lines / 495 `withLock` sites**; tests are **33
> files / 219 passing tests**; concurrency markers are **69 `nonisolated(unsafe)`
> + 60 `@unchecked Sendable`**. The next regression leverage is #3, #20, then
> the #21/#22 lockstep seams.

> **2026-07-16 refresh** (full item re-verify + scan of the input-menu, iPad, formula,
> construction-primitive, and persistence commits since 07-09:
> input-menu overhaul, scene-state persistence overhaul, temporal starts; supersedes the
> 07-09 numbers below): `RenderSettings.swift` is **4,654 lines / 495 `withLock` sites**;
> tests are **28 files** (16 → 28 — the persistence/menu work landed heavily tested);
> concurrency markers **66 `nonisolated(unsafe)` (flat) + 57 `@unchecked Sendable`** (+10;
> only one inside the audited window — `BoxFoldMandelbulbDescriptor`, covered by the
> documented class-level immutability rationale). **Closed since:** #15
> (`recreateLegacyComputeCacheBug` — 0 hits, removed), #18 (`EnvironmentSDFTests` landed),
> #19 (`farClampModel` carried in `EnvScrunchParams`; comment-contract deleted). **#8b is
> near-done** (all 9 domain configs have tolerant decoders; the `{}` pin covers 3/9).
> **#16 still PROPOSED** — no go/no-go recorded; #10–13 stay parked. **New items #20–#24**
> from two sources: the new-work scan (#20 `WarmStartGate` untested-but-default-on, #22
> `boxFoldMandelbulb` lockstep) and
> [`Context/CONSOLIDATION_REVIEW_2026-07-11.md`](Context/CONSOLIDATION_REVIEW_2026-07-11.md)
> — a tiered consolidation backlog tracked as one entry (#24) with its two hottest items
> promoted (#21 `FunctionConstantIndex` lockstep, #23 horizon triplication). The recent
> feature work otherwise followed the standing rules: new controls are catalog-backed with
> range tests (the #8 tail did NOT grow), legacy nav enums were canonicalized under new
> tests rather than left dead, and persisted fields shipped with same-commit round-trips.
> Below itemization threshold, noted only: `EdgeDetectionEffect.normalize()`'s
> legacy-migration branch is untested (`LightingTypes.swift:220-229`) and the
> `vignetteStrength` default literal appears at 3 sites (house convention; range/clamp do
> read the shared spec). Smart advance is now an explicit opt-in (commit `4f53414`);
> validated temporal reprojection remains default-on, so #20 stays focused on
> `WarmStartGate` coverage.

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
Refreshed counts (**2026-07-18**): `RenderSettings` is now **4,656 lines / 495 `withLock`
sites**; tests are **33 files / 219 passing tests**; concurrency markers **69
`nonisolated(unsafe)` + 60 `@unchecked Sendable`**.

The debt now concentrates in three places (comment-lockstep seams — #21/#22 are the live
ones; missing pure-logic tests — #3/#20; the RenderSettings god object) — **plus one new strategic fact**:
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
| 18 | ~~**`EnvironmentSDF` geometry math has zero tests**~~ | Test | – | – | – | – | **DONE (verified 2026-07-13)**: `ThresholdTests/EnvironmentSDFTests.swift` covers `pointTriangleDistance` (one analytic golden case per barycentric region + deterministic fuzz vs a brute-force reference), `parseSynthetic` grammar/malformed-part skipping, `bakeSynthetic` voxel goldens + containment AABB, mesh `bake` (tight triangle AABB, near-voxel accuracy, far clamp), and `makeEnvScrunchParams` world→grid conversion + containment gating. |
| 19 | ~~**`clampFar` comment-enforced lockstep**~~ | Code | – | – | – | – | **DONE (verified 2026-07-13)**: `EnvScrunchParams` carries `farClampModel` (`ShaderTypes.h:306`), the shader returns `es.farClampModel` out-of-grid (`Shaders.metal:1276`), and the comment-contract is gone. Pinned by `EnvironmentSDFTests`' `makeEnvScrunchParams` test ("#19 pin" in the test name). |
| 21 | **`FunctionConstantIndex` Mac literal lockstep**: the function-constant index map is an enum on visionOS (`RendererCoreTypes.swift:16`) but that file starts with `import CompositorServices`, so the Mac path re-encodes indices 0,2,3,6,7,9,11,12,16,17,18 as bare literals under a "mirrors the visionOS `FunctionConstantIndex`" comment (`RaymarchRenderView.swift:1191-1229`). Indices 16 (`hasEnvScrunch`) / 18 (`hasHandField`) are days old and the list is still growing. Fix: move the enum (plus `FragmentTextureIndex`/`BufferIndex` if similarly trapped) into a dependency-free shared Core file; Mac uses `.rawValue` | Code | 3 | 4 | 1 | 35 | **NEW 2026-07-13** (promoted from `CONSOLIDATION_REVIEW` 1.4; literals re-verified in today's tree). #19's disease at higher blast radius: a drifted index silently bakes the wrong feature toggle into every specialized Mac pipeline — wrong-looking scenes with no error anywhere. Single sitting. |
| 20 | **`WarmStartGate` tolerance math untested while default-ON**: commit 7bc62d19 flipped `computeTemporalReprojectionEnabled` default-true, so the compute path now gates per-pixel temporal starts on `WarmStartGate.GeometryKey.matches` — a 3%-relative-tolerance geometry comparison (`RendererCoreTypes.swift:103-116`) wired through `Renderer.swift` — and the gate has zero unit tests (the commit's test only pins the two bools' persistence). The gate is pure and host-testable | Test | 3 | 4 | 2 | 28 | **NEW 2026-07-13** (temporal-starts scan). Too-loose tolerance = stale warm starts (ghost geometry, wrong marches) on the DEFAULT path; too-tight = keys never match and the accelerator silently does nothing. Smart advance is now opt-in, but validated reprojection remains default-on, so this remains a coverage gap on the active path. |
| 22 | **`boxFoldMandelbulb` triple-site lockstep + missing round-trip** (commit bc38d725): rawValue `18` hardcoded at `ShaderTypes.h:93`, `FractalModelType.swift:21`, and `FractalTypeDescriptor.swift:513`, held in sync only by a file-header comment; the Mandelbulb-family predicate (`type == Mandelbulb \|\| MandelbulbJulia \|\| BoxFoldMandelbulb`) is inlined at ~6 `Shaders.metal` sites with no `isMandelbulbFamily()` helper; and no persistence suite round-trips `.boxFoldMandelbulb` (they pin `.mandelbox`/`.mandelbulb`/`.custom`). One sitting: shared family helper + a rawValue-agreement test + one round-trip assertion | Code | 2 | 3 | 1 | 25 | **NEW 2026-07-13.** A missed family site = wrong DE start distance/iterations on one code path only (the hardest kind of visual bug to localize); a drifted rawValue = the wrong formula renders. The codable-string gap is standing-rule-#14 shaped. Pairs naturally with #24's 2.6 (`deFamily` classification). |
| 23 | **Trace-horizon derivation triplicated** (~95 lines, byte-identical ×3): the zoom-adaptive `maxViewDistance` computation (Kleinian branch, `traceScaleFloor`, 420/80/880 caps, divisor-floor guard) is hand-copied into `RaymarchRenderView.swift:~1675`, `RendererGameState.swift:~215`, `HeadlessRenderer.swift:~75`, with comments literally saying "mirrors the Mac guard". Extract `RenderPrecompute.horizonTargetDistance(...)` (already compiled into every target); callers keep their own smoothers | Code | 3 | 3 | 2 | 24 | **NEW 2026-07-13** (promoted from `CONSOLIDATION_REVIEW` 1.2). Same disease as #2, which bit three times in three days before `UniformsBuilder` unified it — this is the largest remaining sibling triplication. |
| 14 | ~~**`objectCutout*` preset persistence asymmetry**~~ | Test | – | – | – | – | **DECIDED + PINNED 2026-07-04**: cutouts are **device-local by design** (they describe the user's physical room, not the scene — same family as the safety bubble and Quality accel fields; they also persist per-device via their own UserDefaults keys). Pinned by `objectCutoutsStayDeviceLocal` (asserts no `objectCutout` key ever serializes into `FractalPreset` AND scene apply never stomps the live device config); test header documents the boundToSpace-vs-cutout rationale. |
| 8d | ~~**`FractalParams`/`Uniforms` size watch**~~ | Perf-adjacent | – | – | – | – | **DONE 2026-07-04**: `static_assert` gates added — `FractalParams ≤ 304 B` next to its definition in `Shaders.metal` (with a do-not-bump-without-harness-measurement comment), `Uniforms ≤ 1856` / `TileUniforms ≤ 1888` / `FormulaParams ≤ 176` at the end of `ShaderTypes.h` (Metal-only guard). Asserts also fire in every runtime `.threshfx` compile via the embeds. **⚠️ Measured finding: `FractalParams` is 304 B by value — ABOVE the 272 B that caused the documented occupancy collapse** (hand+forearm fields, 4×float4 = 80 B). Logged as a candidate for the PERF_PUSH backlog: pack forearms/hands or move them behind the pointer like `spaceWarpOps`. **↑ 2026-07-04 PM: gate RAISED 304→320 B** — Env Scrunch added `EnvScrunchParams` by value (Uniforms gate 1856→1888→**1936**, TileUniforms 1888→1920→**1968** after containment grew the struct 112→160 B; those live in `constant` space, so growth there is awareness-only). The grid *itself* is correctly behind a bindless pointer (`gpuAddress`). **RESOLVED 2026-07-09:** the hand field, space-warp stack, and Env Scrunch were all moved behind pointers, dropping by-value `FractalParams` well under the 272 B collapse size — the `static_assert` is now `FractalParams ≤ 160` (`Shaders.metal:628`), and `Uniforms` / `TileUniforms` are gated `≤ 2048` (`ShaderTypes.h`; both live in `constant` space). The 304/320/1936/1968 B figures above are historical. |
| 16 | ~~**Rebuild go/no-go record**~~ | Arch | – | – | – | – | **DONE 2026-07-04**: `Context/REBUILD_ARCHITECTURE.md` committed with a PROPOSED status block + explicit decision inputs (deferred-shading outcome, next parameter-heavy feature's wiring cost, Vision Pro baseline). #10–13 stay parked until the call is made. |
| 5 | ~~**CI skeleton**~~ | Infra | – | – | – | – | **DONE 2026-07-18:** `.github/workflows/ci.yml` runs clean serial tests, iPadOS/visionOS builds, the Quick Look all-scenes render gate, and repository hygiene on every push/PR; failed tests retain an `.xcresult`. GPU timing remains deliberately local/on-device because hosted-runner timing is not stable evidence. |
| 4 | ~~**Benchmark persistence isolation**~~ | Infra | – | – | – | – | **ALREADY DONE** (register was stale): `SettingsPersistence.benchmarkHermetic` gates BOTH `save` and `load` on the `THRESHOLD_BENCHMARK` env (`SettingsPersistence.swift:131` — checks the env directly, not `BenchmarkMode`, so the QL source closure still compiles; the 2026-07-04 re-verify grep missed it for that reason). |
| 8a | **QL source-closure drift**: derive `wire_quicklook.rb SHARED_SOURCES` from the pbxproj target, or add a freshness check next to #1 | Infra | 2 | 3 | 2 | 20 | **OPEN.** Hit 2026-07-02 (`HandAttractionConfig.swift` missing → QL gate broke mid-session). |
| 8b | **Config Codable-tolerance rule**: audit remaining `cfg.*` domain configs for `decodeIfPresent`; add a test decoding each config from `{}` | Test | 2 | 2 | 1 | 20 | **NEAR-DONE (re-verified 2026-07-13).** The audit half is complete: all 9 Codable domain configs have tolerant custom decoders (`GestureDefaults` is constants-only and `PerFractalGestureStore` a store helper — N/A). The `{}` pin covers 3/9 (Geometry+Color in `SceneStatePersistenceTests:148`, Quality in `QualityConfigCodableTests`). Remaining: add the other six configs to that one existing test — fold into any sitting. |
| 8c | ~~**Bundled-resource flattening workaround**~~ | Infra | – | – | – | – | **DONE 2026-07-18:** `Scripts/mark_mixed_scenes.py --check` fails without modifying files when a bundled Mixed scene lacks `mixedModeScene: true`; CI runs it on every change. |
| 15 | ~~**Legacy compute-cache toggle is trap code**~~ | Code | – | – | – | – | **DONE (verified 2026-07-13)**: `recreateLegacyComputeCacheBug` — 0 hits in the tree; the toggle was removed and only the scene-persisted `deIterationMismatch` δ path remains. |
| 17 | ~~**`handEffectsBeta` gate scatter**~~ | Code | – | – | – | – | **DONE** (verified 2026-07-09 + 07-07 audit): `handEffectsBeta` returns **0 code hits** — the beta gate was fully removed, so there is nothing left to centralize. |
| 6 | **Concurrency-safety pass**: audit the 66 `nonisolated(unsafe)` + 57 `@unchecked Sendable` occurrences; keep documented racy-by-design gates, annotate WHY per-site, fix the drift | Code | 3 | 3 | 3 | 18 | **OPEN** (counts refreshed 2026-07-16; +10 `@unchecked Sendable` since 07-09, with new resource and renderer types documented where applicable). Swift-6 strict concurrency will force this eventually. Sequence #24's 2.7 (`@Locked` shrink) with this pass — same lock-discipline review. |
| 7 | **Execute CLEANUP_AUDIT backlog** (132 verified items) | Code | 2 | 2 | 2 | 16 | **OPEN.** Do opportunistically when touching each file. `CONSOLIDATION_REVIEW` (07-11) confirmed its Tier-1 gestures block and the `KeyframeLerp` consolidation are already done — re-verify an item's 0-hit status before spending a sitting on it. |
| 24 | **Execute `CONSOLIDATION_REVIEW_2026-07-11.md` backlog** (Tier 1 mechanical single-sittings + Tier 2 structural 1–3-day items; its Tier 3 stays rebuild-gated per #16): ControlCatalog/moduleCard migration finish (1.1 — the action end of #8), shared proxy mesh + QL `hr_*` deletions (1.3), `ParameterPipeline`/`ParameterRoute` deletions + redundant projection re-clamps (1.5), dual formula-default sources read by different code paths (1.6), small-helper batch (1.7), Apple Music adapter merge incl. the pbxproj-membership fragility (2.1), generic coalesced dispatcher (2.2), one gesture-engine contract (2.3 — ⚠️ needs on-device verify), keyframe field-policy table (2.4 — incl. the redundant `musicReactiveConfig` double-assign at `AnimationTypes.swift:1226`/`1246`, verified still present 07-13), descriptor/readback factories (2.5), `deFamily` classification (2.6 — pairs with #22), `@Locked` RenderSettings shrink (2.7 — sequence with #6) | Code | 3 | 2 | 3 | 15 | **NEW 2026-07-13.** Same treatment as #7: one register entry for an externally-documented, verified backlog. Its two hottest items are promoted to standalone entries above (#21, #23). Tier 1 items are the "when the file is open" default; 2.6 and 1.6 are the two with silent-visual-drift failure modes if skipped. |
| 8 | **ControlSpec tail** (~290 range/default definition sites for ~63 controls; catalog adoption now quantified at 31/63 controls, ~50 literal `range:` args left in UI) | Code | 3 | 3 | 3 | 18 | **OPEN, but no longer growing** (2026-07-13): the menu-overhaul window added its new controls (vignette + 4 edge params) through `ControlCatalog` specs with range tests — the fixed pattern, not the disease. The remaining work is the mechanical UI swap = `CONSOLIDATION_REVIEW` 1.1 (tracked under #24); E rescored 4→3 accordingly. Fully subsumed by the rebuild's ParameterCatalog if #16 = go. |
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

**Phase B — seam hardening: ✅ first half COMPLETE by 2026-07-13** (#2 done 07-10;
#18 + #19 done — `EnvironmentSDFTests` landed; #15 removed; #8b near-done). The original
rationale held: the pure-function suites were cheap and now double as migration pins.

**Phase B′ — updated 2026-07-13 (1–2 sessions):** in order —
1. **#21 + #22 first** (one short sitting each): both are comment-lockstep traps on
   days-old code — the exact window where #19 proved these are cheapest to kill. #21 is
   the highest-priority item on the register (P 35).
2. **#20** (WarmStartGate unit test): the tolerance math is pure, host-testable, and now
   guards the *default* compute path.
3. **#3** (parameter-layering tests): unchanged — still the most re-broken math in the
   app, still zero coverage, still the rebuild's Modulation Engine pin.
4. **#5** (CI): absorbs #8a/#8c as steps and the #8b finish (six lines in an existing
   test); gate scripts already exist; pairs with PERF_PUSH Phase 0 — one job runs both.

**Phase C — opportunistic (ongoing, no dedicated sessions):** #7, #24, #8 (via #24's
1.1), #6. Rule: when a file is already open for feature work, burn its CLEANUP_AUDIT and
CONSOLIDATION_REVIEW Tier-1 items and fix its concurrency annotations. #23 graduates to a
dedicated sitting if any horizon-math change is planned — do the extraction *before* the
change, not after the third copy drifts.

**Parked pending the #16 decision** (re-verified still PROPOSED 2026-07-13): #10, #11,
#12, #13, plus #24's Tier 3 — all dissolved by the rebuild if it proceeds; re-activate
here only on a no-go.

## Standing rules

- Perf debt goes to `PERF_PUSH.md`, never here — one register per concern.
- Dead code found during work: add to `CLEANUP_AUDIT.md` if uncertain, delete if verified.
- Every "temporary" measurement affordance (benchmark gates, ablation switches)
  must be env/flag-gated and default-off — same rule as perf toggles.
- New persisted field ⇒ same-commit round-trip test (or an explicit device-local
  exclusion noted in the test) — #14 is what skipping this looks like.
