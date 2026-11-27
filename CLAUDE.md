# Glint

A raw-first iPhone camera app (Swift 6, SwiftUI, AVFoundation). The README describes behaviour; this file is for working in the code.

## Checks

Run `tools/check` before pushing. CI runs `tools/check --fast` only, because GitHub's runners lack the Xcode this project needs; build and tests run locally.

- `tools/check --fast`: swift-format, SwiftLint and the baseline ratchet only (the pre-commit hook).
- `tools/check --fix`: apply swift-format first.
- Enable the hook once per clone: `git config core.hooksPath .githooks`.
- Needs `brew install swiftlint`. swift-format comes with Xcode.
- On a phone, which `tools/check` can't do because it builds unsigned: `xcodebuild test -project Glint.xcodeproj -scheme GlintTests -destination 'id=<device id>' -allowProvisioningUpdates`, and the same with `-scheme GlintUITests` (about 7 minutes).

- `tools/dead-code`: finds unused code with Periphery (`brew install periphery`). Local only: it needs a full build. `.periphery-baseline.json` holds findings that are false positives (SwiftUI `$` bindings, App Intent metadata); don't add to it without checking the code really is used.

Warnings are build errors. Formatting is swift-format's job (`.swift-format`); SwiftLint (`.swiftlint.yml`) checks correctness. `.swiftlint-baseline.json` holds the existing size and complexity findings: don't add entries to it, and don't let a recorded size grow unless the same change removes an entry for that file. `tools/baseline-ratchet` fails if it does, comparing with main.

A size limit is a prompt to look, not a target. Shrink a recorded function by removing repetition or moving code to the topic it belongs to; don't cut a flat sequence into helpers that are each called once just to get under the limit. An entry that stays in the baseline is fine.

## Structure

One type, one job. Lint caps sizes, but a file can stay under them and still take on a second concern, so check where new code belongs before adding it.

- `CameraController` is the camera screen's capture state: mode, exposure, focus, lens, stills, recording. It owns the feature models and sends their changes to `CaptureSession`. A new feature gets its own `@MainActor @Observable` model, owned by the controller and exposed for views (`aids`, `shotLibrary`, `levelModel`), not more properties on the controller.
- Rules and wording are value types with no framework state (`SceneDescription`, `ViewfinderAidPauses`, `CapturePlan`); a class around them keeps only state and timing (`SceneNarrator`, `ViewfinderAidsModel`). Inject clocks and side effects so the class can be tested.
- Folders by job: `Capture/` device and session work; `Exposure/`; `Photo/` developing, saving, review; `Video/`; `Viewfinder/` per-frame aids and rendering; `Accessibility/` VoiceOver; `Settings/` what is saved between launches and keeping the two copies of Glint in step; `Support/` logging and small utilities with no feature of their own; `Views/` display only, calling a model's setters.
- `CaptureSession` is one actor; split it with `CaptureSession+Topic.swift` extensions, not new types. Its members may drop `private` to be shared between those files, because the actor still guards them.
- `CameraController`'s extensions must not drop `private` or `private(set)`: views would then get past the setters. A method that needs private state stays in the main file.
- A helper used by one file is `private` in that file, not a file of its own.
- Keep one copy of a table of constants (a colour matrix, a threshold) and have every user read it, including Metal's caller.
- A `// MARK:` section whose name no longer covers its contents means a type should come out.
- A new model or rule type gets its own test file in `GlintTests/`.

## Conventions

- Don't write `TODO`/`FIXME` or commented-out code (lint rejects both). Write an issue, or delete it.
- Don't add comments that restate what the code does. Put intent in names, types and tests; a comment is only for a constraint the code can't show (a measured cost, an OS quirk).
- Behaviour is specified by tests in `GlintTests/`. Change behaviour, change the test in the same commit.
- Tests run on a phone as well as the simulator, so they can't read the Mac's files (`#filePath`). A test that can only run on one gives the reason: `.enabled(if: onPhone, "why")`.
- The README feature list must change in the same commit as the behaviour it describes.
