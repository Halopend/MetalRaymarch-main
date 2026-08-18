# Threshold roadmap

This is the ordering layer for active work. It intentionally does not duplicate
the evidence and implementation notes in [`TECH_DEBT.md`](TECH_DEBT.md),
[`PERF_PUSH.md`](PERF_PUSH.md), or the audits in [`Context/`](Context/).

## Working agreement

- Keep at most one primary progression and one hardening task in progress.
- Track work as an outcome with a definition of done, regression surface, and
  permanent guard. The GitHub issue forms and pull-request template enforce that
  shape.
- A fix is not complete until the relevant automated test or gate would catch its
  return. If automation is impractical, record the manual evidence and why.
- Move completed work into Git history and the short log below; do not leave it
  mixed into the active queue.

## Now — trustworthy change pipeline

Outcome: every pushed change receives fast, reproducible feedback before it is
treated as progress.

Exit criteria:

- [x] Clean, serial macOS unit tests run on every push and pull request.
- [x] iPadOS and visionOS schemes compile on every push and pull request.
- [x] Quick Look renders every bundled scene on every push and pull request.
- [x] Repository hygiene catches duplicate artifacts and unmarked Mixed scenes.
- [x] Failed test runs retain an `.xcresult` bundle for diagnosis.
- [ ] Protect the primary branch in GitHub and require the CI jobs after this
      workflow has completed successfully once.

Performance remains a device gate: shared hosted runners are suitable for
correctness and compilation, not stable GPU timing. Run `Scripts/perf-gate.sh`
and record Vision Pro measurements for performance-sensitive changes.

## Next — highest regression leverage (reordered 2026-08-17 with the register refresh)

1. Kill the Swift/Metal identity seams — the function-constant map drift is now a
   **realized bug** (the benchmark harness specializes index 17 as the hand field;
   [tech debt #21](TECH_DEBT.md#register--scored)), plus its new siblings: the
   comment-mirrored Mac motion/blit structs (#27) and the hand-enumerated distance
   cache seed-file identity (#29).
2. Land the in-flight recording-mode tree clean: test the window state machine
   (#37), fix its five comment/constant seams (#38), and decide the four untracked
   presets that local tests already read but CI does not (#39).
3. Pin the default-on `WarmStartGate` tolerance behavior (#20), finish the
   parameter-layering coverage — recenter + the now-duplicated composition
   invariant (#3) — and unify the tripled band-sensitivity mapping (#26).
4. One-liner safety batch: enforce the analytics record cap and surface failures
   (#33), assert the audio scratch-buffer queue confinement (#34), wire the
   formula-editor library eviction that already exists (#25), env-gate the audio
   micro-benchmark (#36).
5. Fix the docs that lie or omit the operating envelope: the `CONTRIBUTING.md`
   test-action row that yields a zero-test green, the undocumented DerivedData
   serial-build lock, and the hosted-GUI test cost with its `testfast` escape
   (#43).

## Later — bounded cleanup

- Audit concurrency escape hatches alongside the proposed `@Locked` cleanup
  (#6 and #24.2.7) — fix the unguarded `handTrackingEnabledForRenderer`
  cross-thread var ahead of the full pass.
- Pull small, verified items from the cleanup/consolidation audits only when the
  owning file is already being changed (#7 and #24).
- Finish the `ControlCatalog` migration — 16 literal `range:` sites remain (#8) —
  and the six missing `{}` decode pins (#8b).
- Unify the triplicated trace-horizon derivation before the next horizon change
  (#23); `boxFoldMandelbulb` family/identity seam (#22).
- Hygiene decisions: reclaim ~600 MB of unreachable `.git` packs, resolve the
  `Sources/` tracked-vs-ignored half-state, delete the empty
  `MetalRaymarch.xcodeproj` husk, probe `/Applications/Xcode.app` in `build.sh`
  (#40–#42, #44).
- Keep rebuild-dependent architecture work parked until the recorded go/no-go
  inputs in [`Context/REBUILD_ARCHITECTURE.md`](Context/REBUILD_ARCHITECTURE.md)
  are available — and record that call: its inputs are aging while in-place work
  (formula editor, `ControlCatalog` convergence) executes rebuild seeds anyway.

## Completed progression log

- **2026-07-18 — CI foundation:** automatic tests, cross-platform builds, Quick
  Look rendering, failure artifacts, repository hygiene, and structured
  regression/progression tracking.
