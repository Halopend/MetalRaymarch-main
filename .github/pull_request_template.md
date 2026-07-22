## Outcome

What becomes observably better after this change?

## Regression surface

- User-visible behavior affected:
- Persistence or file-format impact:
- Swift/Metal lockstep assumptions changed:
- Platform-specific paths affected:

## Verification

- [ ] `Scripts/build.sh test`
- [ ] macOS behavior checked when applicable
- [ ] `Scripts/build.sh ios` when shared/iPad code changed
- [ ] `Scripts/build.sh vision` when shared/visionOS code changed
- [ ] `Scripts/ql_render_check.sh` when rendering, shaders, scenes, or Quick Look changed
- [ ] `Scripts/perf-gate.sh` with evidence when a performance claim is made
- [ ] A regression test fails without the fix and passes with it, or the reason this is impractical is recorded

## Tracking

Issue/debt item closed or advanced:

Follow-up work intentionally left out:
