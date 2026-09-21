# 10: Manual E2E has no Siri-engine leg (release build, private engine)

**What to build:** `./Scripts/e2e.sh` proves the **release** binary on the private engine too — the same four independent assertions (brand, duration, markers, metadata), plus that the run announced itself as `Engine: siri` — and reports `skip:` rather than `FAIL:` on a Mac with no Siri voice bundle. The default engine's leg stays exactly as it is.

**Blocked by:** 07 (E2E script), 08 (`--engine siri`)

**Status:** ready-for-agent

## The gap

`Scripts/e2e.sh` builds `-c release`, runs `"$BIN" "$EPUB" -o "$OUT" 2> "$LOG"` and verifies with `afinfo`/`ffprobe`. It has **no `--engine` and no `--voice` argument anywhere**, so nothing in the project ever runs the release binary through `SiriTTSBridge`:

- the CLI test suite shells out to **`.build/debug/saybook`** (recorded in #07: the release-only `ftyp` bug was invisible precisely because of this), and
- the release test run (`swift test -c release`) compiles the release target but still executes the debug binary.

So `SiriTTSBridge` under `-O`, on a real Book, with real Chapter boundaries, has been verified exactly once, by hand (2026-09-19: `m4bf`, 2:16, 553 KB, `1 ch 22050 Hz aac`). The class of bug this leaves open is the one that bit #07 — a defect that only exists in the shipping configuration.

## Decisions to make (recommendations in brackets)

1. **What does the Siri leg render?** [A small in-repo fixture, e.g. `multi-chapter.epub`, ~17 s of render.] The Siri engine renders at ~8× realtime (#08's measurement) against the public engine's ~40×, so a Siri leg over Alice (~160 min of audio) would add ~20 minutes to a script that today takes ~3. The release-path coverage the ticket wants does not need a 160-minute Book; a `--siri-full` opt-in can run the Book itself for anyone who wants it.
2. **How is "no Siri voice on this Mac" detected?** [Ask the binary, don't re-implement the catalog.] Run `saybook <book> --engine siri --voice __no_such_voice__` and treat an exit 1 whose message contains `no Siri voice bundle is installed` as a skip; any *other* failure stays a FAIL. This reuses `SiriVoiceCatalog` as the single source of truth instead of hard-coding `/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Siri_TextToSpeech/…/gryphon.cfg` into bash — that path is Apple's, and it is the thing most likely to move. Guard the substitution against `set -euo pipefail` (`|| true` on the failing run, per #07's lesson) and keep the skip noisy and explicit.
3. **Cross-engine duration sanity.** [Assert the Siri output's decoded duration is within ~25 % of the Apple leg's for the same Book.] #08 caught the sample-rate question in debug tests (48 kHz mono int16 → 22.05 kHz CAF); on the release path a 2× error is currently silent, and this is a two-line guard that would catch it.

## Checklist

- [ ] `./Scripts/e2e.sh` gains a Siri leg: release binary, `--engine siri`, asserts brand, decodable duration, one marker per non-empty Chapter (first at 0:00, every chapter titled), `ilst` title/artist vs the OPF — reusing the existing assertions rather than copying them
- [ ] The leg asserts `Engine: siri` appears in the run's stderr, so a silently-ignored `--engine` cannot pass
- [ ] A Mac with no Siri voice bundle prints an explicit `skip:` with the reason and still exits 0
- [ ] Cross-engine duration comparison (or a recorded reason for dropping it)
- [ ] The script's own runtime on the default (no-argument) path is unchanged, and the Siri leg's cost is stated in the header comment
- [ ] Header comment updated to list what the Siri leg asserts and when it skips; README's Manual E2E paragraph says the same
- [ ] Verified on this Mac (bundle present → the leg runs and passes) **and** by simulating absence (e.g. pointing the catalog at an empty root, or a temporary env override) so the skip path is not untested code

## Comments

- 2026-09-19 (agent): Opened from #08. Note for whoever picks this up: stderr is captured with `2> "$LOG"` (a file), which is *why* the engine's diagnostic torrent never blocked this script — a future change to `2>&1 | tee` would reintroduce the deadlock #08 fixed at the bridge level (`SAYBOOK_SIRI_DIAGNOSTICS=1` reproduces 153 KB of chatter per 6-second Chapter).
