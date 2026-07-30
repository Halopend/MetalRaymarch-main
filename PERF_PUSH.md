# Threshold Performance Push — 2026-07

Prioritized performance-debt backlog + phased plan. Companion to
[`PERF_LOG.md`](PERF_LOG.md) (the only citable source of numbers) and
[`Threshold/Rendering/PERF_TECHNIQUES.md`](Threshold/Rendering/PERF_TECHNIQUES.md)
(idea catalog — claims there are unverified estimates).

## Ground truth (measured 2026-07-01, Mac harness + GPU counters)

- Canonical scene = the named benchmark scene **"Stress test"** (driven by
  `Scripts/perf-gate.sh` via `THRESHOLD_BENCHMARK_SCENES="Stress test"`; baselined
  in `Baselines/mac-stress-1080p-accel-{on,off}.json` + `Baselines/png-accel-*/Stress test.png`).
  There is no `Stress_test.threshscene` file — the harness resolves the scene by
  name from the bundled presets. **19.4 ms @ 1080p** on this Mac, byte-identical PNGs across runs.
- Heaviest scene = **Bulatov limit set, ~40 ms**.
- Both are **ALU-bound (~68–70%** of GPU time in ALU, windowed counters). Not
  bandwidth, not occupancy-starved by buffers — arithmetic + register pressure.
- **Shading tail is 2–3 ms flat** across scenes; shadows are its biggest chunk.
  **SUPERSEDED 2026-07-25** (`Baselines/mac-ablation-2026-07-25.json`, single-launch
  plan-mode ablation matrix at 48d24230+WIP): on Stress test (accel-on 1080p,
  29.1 ms full / 17.1 ms flat-hits) the shading tail is **12.0 ms = 41% of the
  frame** — shadows 6.2 ms, GetNormal 4.9 ms, colour 0.7 ms. On Bulatov the tail
  is 2.9 ms (shadows ~1.1 ms). The tail is scene-dependent, not flat.
- **Mandelbox cost grows super-linearly with resolution** (epsilon tightens with
  res → more steps), unlike other formulas.
- Vision Pro is GPU-bound below 45 fps on heavy scenes; budget is **11.1 ms** for
  90 fps. No device numbers exist in the repo yet (`PERF_LOG.jsonl` is empty).
- Already ruled out on Bulatov (measured, no win): MaxReflections cap,
  transcendental hoisting, secondary-ray step cap, shadow toggle alone.

## Measurement protocol (non-negotiable for every item below)

1. Mac: `THRESHOLD_BENCHMARK=1` harness family, canonical Stress test scene,
   pin shadows via `THRESHOLD_BENCHMARK_SHADOWS`, settle ≥ 2.5 s before
   measuring, steps counter = hit-rays only.
2. Vision Pro: in-app Performance Sweep → pull `perf-log.jsonl` → append to
   `PERF_LOG.jsonl`. Pin the adaptive render-quality governor OFF during
   sweeps — it holds fps by silently dropping quality and masks regressions.
3. A change ships only with a before/after `gpuMsAvg`/`gpuMsP95` pair from the
   same machine + resolution. No estimates. Refuted ideas get logged too.

## Harness caveats (measured 2026-07-25/26)

- **accel-on is bimodal ACROSS LAUNCHES**: identical code lands in either a
  ~29 ms / steps-17.1 mode or a ~12 ms / steps-2.5 mode per app launch and stays
  there for the whole run. The steps delta means it is behavioral (cone-march
  engagement differing at startup, suspected QC-override/scene-apply race), not
  GPU thermal noise. Until fixed, only compare runs whose steps counters match,
  or A/B inside one launch via plan mode.
- Benchmark launches resolve scenes hermetically: `perf-gate.sh` stages
  `Baselines/scenes/*.threshscene` into a temp store and points the app at it
  with `THRESHOLD_BENCHMARK_STORE_ROOT` (unsigned debug builds cannot see an
  iCloud-mode user store, which silently dropped "Stress test" from the catalog).
- PNG captures are now fog-deterministic: the fog hue-cycle phase integrates
  from launch and was the one phase `benchStableColorScheme` couldn't pin;
  benchmark processes now skip fog hue rotation entirely (RenderSettings).
  Before this fix, Bulatov PNGs differed run-to-run (~0.3–1.3% of pixels).

## Backlog — scored

Priority = (Impact + Risk) × (6 − Effort), each 1–5.

| # | Item | I | R | E | P | Why it matters |
|---|------|---|---|---|---|----------------|
| 1 | Capture first Vision Pro baseline into PERF_LOG | 5 | 4 | 2 | 36 | The target device has zero recorded numbers; every Mac-side win is a proxy until this exists. |
| 2 | Commit the staged harness work + add a Mac perf regression gate | 4 | 4 | 2 | 32 | 23 files staged uncommitted. A script asserting Stress-test `gpuMs` within tolerance vs a checked-in baseline JSON makes every future change perf-accountable (PNGs are already byte-identical → cheap correctness gate too). |
| 3 | Instrument the visionOS compute path (in-kernel step counters) | 4 | 3 | 2 | 28 | Mac/fragment path has measured steps; the path that actually misses 90 fps is blind. Blocks porting any win to device. |
| 4 | Measure conservative coarse-pass warm start (landed, default OFF) | 3 | 2 | 1 | 25 | Shipped code nobody has measured. One harness run decides: promote to default or delete. Gated-off unmeasured code is pure debt. |
| 5 | Resolution-aware epsilon policy | 3 | 2 | 2 | 20 | Mandelbox's super-linear res scaling is an epsilon artifact, not intrinsic cost. A floor/curve on epsilon vs res caps the worst scaling case. |
| 6 | Annotate PERF_TECHNIQUES.md with measured/refuted/unmeasured status | 2 | 3 | 2 | 20 | 252 techniques with fabricated magnitudes keep getting re-proposed. Marking verdicts stops re-litigating ruled-out ideas (see Bulatov list above). |
| 7 | Shadow efficiency (step budget, early-out, cheaper march) | 4 | 2 | 3 | 18 | Biggest slice of the shading tail (6.2 ms of 29.1 ms on Stress test, measured 2026-07-25). **PARTIALLY LANDED 2026-07-26:** N·L≤0 shadow-march skip in `fragmentMain` (exact-zero multiplier in ShadeSurface ⇒ byte-identical, PNG-verified) cut it to 4.3 ms — Stress full 29.15→27.2 ms (−6.6% frame), no-shadows/flat-hits anchors unchanged (`Baselines/mac-ablation-2026-07-25.json` vs `mac-ablation-2026-07-26-shadow-nl-skip.json`). Not yet applied to the dormant adaptive-compute kernel's per-lane fallback sites. Remaining 4.3 ms needs step-budget/march changes (visual-affecting → toggle + measure). |
| 8 | F16 in shading + secondary rays | 3 | 3 | 3 | 18 | ALU-bound → halving arithmetic width is a direct lever; risk is precision artifacts near surfaces (DE march itself likely must stay F32). |
| 9 | **Deferred shading (split march → G-buffer → shade pass)** | 5 | 3 | 4 | 16 | The #1 ranked lever from both investigations. The megakernel's register footprint throttles the ALU-bound 70%; splitting shading out shrinks live state for the march loop. Scores mid on the formula only because effort is real — it's the headline of the push. |
| 10 | Hoist 4× `applySphereProjectionDomain` in `GetNormal` | 2 | 1 | 2 | 12 | Known redundant work in the normal estimator (open item from transform-overhead phase 1). Small, contained. |

## Phased plan (each phase ships alongside feature work)

### Phase 0 — Lock the baseline (do first, ~1 session)
Items 2, 1. Commit the harness; `Scripts/perf-gate.sh` now exists (runs the harness on
Stress test, diffs `gpuMsAvg` vs `Baselines/mac-stress-1080p-accel-{on,off}.json`, fails > +5%);
run one Vision Pro sweep and land the first real rows in `PERF_LOG`. Everything
after this is measured against these two baselines.

### Phase 1 — Cheap measured wins (1–2 sessions)
Items 4, 5, 10, 7-ablation. All are one-flag or one-function changes,
individually gated through the perf gate. Also item 6 (doc annotation) as the
paper trail. Expected outcome: a few ms shaved and several catalog entries
moved to "refuted" — both are wins.

### Phase 2 — The big lever: deferred shading (multi-session)
Item 9, informed by item 7's ablation numbers. Minimal G-buffer (hit t /
position + iteration count; recompute normal in shade pass vs store — measure
both). Success criteria: Stress test and Bulatov `gpuMsAvg` down with PNGs
visually identical; register/occupancy delta captured from counters. This is
the only item that plausibly moves the ~70% ALU share itself.

### Phase 3 — Precision + device (multi-session)
Items 8, 3, then port Phase 1/2 winners to the visionOS compute path and
re-sweep on device. The push "succeeds" when heavy scenes hold 90 fps
(≤ 11.1 ms `gpuMsP95`) on Vision Pro, or we have a measured explanation of the
remaining gap.

## Standing rules

- Never cite a perf number that isn't in `PERF_LOG` or a harness JSON.
- Every lever lands behind a toggle until measured, then the toggle is removed
  (promote or delete — no permanent gated-off code).
- One lever per measurement; no stacked changes in a single before/after.
