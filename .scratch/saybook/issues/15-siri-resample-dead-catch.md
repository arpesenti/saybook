# 15: The Siri resample swallowed conversion errors (dead `catch`, `error: nil`)

**What to build:** Nothing new — the Siri engine's resample step must report a failed conversion as itself, not as a confusing frame-count mismatch three guards later.

**Blocked by:** nothing

**Status:** resolved

## How it surfaced

A production build printed two warnings in `Sources/SaybookCore/SiriSynthesis.swift`:

```
warning: no calls to throwing functions occur within 'try' expression
warning: 'catch' block is unreachable because no errors are thrown in 'do' block
```

Warnings that say "this error handling cannot run" are worth reading as bugs.

## Root cause (measured against the SDK)

`AVAudioConverter`'s input-block call is declared:

```objc
- (AVAudioConverterOutputStatus)convertToBuffer:(AVAudioBuffer *)outputBuffer
                                          error:(NSError **)outError
                              withInputFromBlock:(NS_NOESCAPE AVAudioConverterInputBlock)inputBlock;
```

It returns an output **status** and takes an `NSError **`, so Swift imports it as non-throwing — the reason there is no throwing variant to use here is that the one-shot `convert(to:from:)` refuses sample-rate conversion with `paramErr` (the comment above the call says so, and that is why the input block is used at all).

So `try converter.convert(to: output, error: nil) { … }` compiled but meant nothing:

- the `try` was inert (hence the first warning),
- the `catch` was unreachable (hence the second), and
- `error: nil` **discarded the failure reason**, so the diagnostic the code was written to produce could never appear.

The failure was not entirely silent — `produced > 0` and the ±2 % frame-count guard would usually catch a bad conversion — but they report "the Siri audio conversion produced N frames where M were expected", which describes the symptom and hides the cause. A conversion that failed while still filling the buffer would have passed both guards.

## Fix

Read both outputs of the call:

- pass `&conversionError` instead of `nil`,
- treat `status == .error` as the failure, and throw the `NSError`'s own description,
- leave `.haveData`, `.inputRanDry` and `.endOfStream` alone: hitting end of stream is how this call finishes with a finite input, and the existing frame-count guards are what judge the result.

The guards, tolerances and output are otherwise untouched.

## Verification

- Clean `swift build -c release`: **zero warnings** (was two).
- The Siri leg of `./Scripts/e2e.sh Tests/SaybookTests/Fixtures/multi-chapter.epub` reports **135.676009 s** decoded — identical to before the change, so the working path is unaffected (this leg is the only thing in the project that runs 48 kHz → 22.05 kHz through the converter for real).
- 190 tests green in debug and release.
- The error path itself is not covered by a test: provoking a mid-conversion failure means handing the converter something it rejects, which would be a synthetic fixture for a branch whose only job is a better message. Recorded here rather than faked.

## Comments

- 2026-10-06 (agent): Filed and fixed from the warnings in the reporter's production build. Adjacent to tickets 12/13 only in that all three are "the code claimed to handle something it did not".
- 2026-10-06 (agent): **Maintainer's call: `-warnings-as-errors` is now the policy, always.** `Package.swift` carries it on every Swift target (`swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]`) and `-Wall -Wextra -Werror` on the C++ bridge; the e2e script's probe opts in too, since it is compiled outside SwiftPM. Notes from doing it:
  - `-Werror` alone on the C++ target was nearly a no-op: clang enables very few warnings by default, so an unused variable produced nothing. `-Wall -Wextra` is what makes the policy meaningful there, and the bridge is clean under the full set. Verified by inserting an unused local in each target and watching the real `swift build` fail (`-Werror,-Wunused-variable` for the bridge, `NoUsage` for Swift).
  - The policy immediately earned its keep: it failed the test build on a deprecated (`stringValue`) API in this project's own `TestSupport.avFoundationChapters`, which an ordinary green build had been printing past.
  - Cost, recorded rather than discovered later: `unsafeFlags` makes SwiftPM refuse to let another package depend on saybook. It is an executable with no dependents, so nothing is lost here.
  - Consequence to expect: a future SDK that deprecates something saybook uses will now break the build instead of warning. That is the intent, and the fix is to migrate the API rather than to soften the flag.
