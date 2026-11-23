# Glint

A raw-first iPhone camera app (Swift 6, SwiftUI, AVFoundation). The README describes behaviour; this file is for working in the code.

## Checks

Run `tools/check` before pushing. CI runs `tools/check --fast` only, because GitHub's runners lack the Xcode this project needs; build and tests run locally.

- `tools/check --fast`: swift-format and SwiftLint only (the pre-commit hook).
- `tools/check --fix`: apply swift-format first.
- Enable the hook once per clone: `git config core.hooksPath .githooks`.
- Needs `brew install swiftlint`. swift-format comes with Xcode.

- `tools/dead-code`: finds unused code with Periphery (`brew install periphery`). Local only: it needs a full build. `.periphery-baseline.json` holds findings that are false positives (SwiftUI `$` bindings, App Intent metadata); don't add to it without checking the code really is used.

Warnings are build errors. Formatting is swift-format's job (`.swift-format`); SwiftLint (`.swiftlint.yml`) checks correctness. `.swiftlint-baseline.json` holds the existing size and complexity findings: don't add to it. Shrink it when you touch those functions.

## Conventions

- Don't write `TODO`/`FIXME` or commented-out code (lint rejects both). Write an issue, or delete it.
- Don't add comments that restate what the code does. Put intent in names, types and tests; a comment is only for a constraint the code can't show (a measured cost, an OS quirk).
- Behaviour is specified by tests in `GlintTests/`. Change behaviour, change the test in the same commit.
- The README feature list must change in the same commit as the behaviour it describes.
