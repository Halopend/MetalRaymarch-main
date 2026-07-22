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

## Next — highest regression leverage

1. Add parameter-layering composition tests for base × gesture × music ×
   animation behavior ([tech debt #3](TECH_DEBT.md#register--scored)).
2. Pin the default-on `WarmStartGate` tolerance behavior (#20).
3. Remove silent Swift/Metal lockstep seams: function-constant indices (#21) and
   `boxFoldMandelbulb` identity/family behavior (#22).
4. Unify the triplicated trace-horizon derivation (#23).
5. Finish tolerant empty-object decoding coverage for all domain configs (#8b).

## Later — bounded cleanup

- Audit concurrency escape hatches alongside the proposed `@Locked` cleanup
  (#6 and #24.2.7).
- Pull small, verified items from the cleanup/consolidation audits only when the
  owning file is already being changed (#7 and #24).
- Continue the `ControlCatalog` migration without expanding the literal-spec tail
  (#8).
- Keep rebuild-dependent architecture work parked until the recorded go/no-go
  inputs in [`Context/REBUILD_ARCHITECTURE.md`](Context/REBUILD_ARCHITECTURE.md)
  are available.

## Completed progression log

- **2026-07-18 — CI foundation:** automatic tests, cross-platform builds, Quick
  Look rendering, failure artifacts, repository hygiene, and structured
  regression/progression tracking.
