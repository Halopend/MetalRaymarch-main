# Contributing

## Source of truth for Swift sources

- Canonical Swift source files **must not** use editor-generated duplicate suffixes like `" 2.swift"`.
- If duplicate-named files are discovered, keep the unsuffixed path (for example, `Foo.swift`) as the canonical source-of-truth file and remove the suffixed copy after reconciling needed changes.
- Run `scripts/check_no_duplicate_suffix.sh` before committing.
- Optional local hook setup:

```bash
git config core.hooksPath .githooks
```

This enables the repository pre-commit hook, which blocks commits containing tracked files that match `* 2.swift` under `Threshold/`.
