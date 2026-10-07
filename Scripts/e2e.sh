#!/usr/bin/env bash
#
# Manual end-to-end check for saybook (tickets 07, 10). One command:
#
#   ./Scripts/e2e.sh [--siri-full] [book.epub]
#
# With no argument it downloads a small real Book (Alice's Adventures in
# Wonderland, Project Gutenberg #11) — the only network access anywhere in
# the project, and only in this manual step; pass a local EPUB to run fully
# offline.
#
# Builds the release configuration, runs the real binary, and asserts the
# Audiobook with independent tools. Two legs, the same five assertions each:
#
#   1. the default (Apple) engine on the Book — unchanged from ticket 07.
#      Cost: the Book (~3 min of synthesis for Alice).
#   2. the private Siri engine (`--engine siri`) on a small in-repo Book
#      (Tests/SaybookTests/Fixtures/multi-chapter.epub, ~2:10 of audio), so the
#      *release* binary is exercised through SiriTTSBridge with real Chapter
#      boundaries — the configuration no test in the project runs. Cost: ~33 s
#      measured (38.6 s with the leg, 6.0 s with it skipped, release build
#      cached): the Siri render of the fixture's ~2:10 at ~8× realtime is the
#      bulk of it, plus ~3 s for the Apple-engine render of the same fixture
#      that the cross-engine duration check compares against. `--siri-full`
#      renders the Book itself instead of the fixture and drops that extra
#      render, since leg 1 already produced the reference duration — for Alice
#      that is ~20 min, extrapolated from the same ~8× against her ~163 min of
#      audio (not measured end to end).
#
# What each leg asserts:
#   • brand      — afinfo's file type ID is `m4bf` and ffprobe's
#                  `major_brand` is `M4B `
#   • duration   — the file decodes (afinfo reports a duration) and ffprobe
#                  agrees within tolerance
#   • markers    — ffprobe reads one chapter per non-empty Chapter
#                  (saybook's own summary: Chapters − Skipped), the first at
#                  0:00, every chapter titled
#   • markers(2)  — AVFoundation reads the same chapters, via the same
#                  `loadChapterMetadataGroups` call Books/VoiceOver/QuickTime
#                  use. Both are needed: ffprobe reads the `chpl` box and Apple's
#                  players ignore it, so a `chpl`-only file passed every
#                  assertion here and showed no chapters in the app (ticket 12).
#                  The probe is Scripts/apple-chapters.swift.
#   • metadata   — ffprobe's title/artist match the Book's OPF
#                  (`dc:title`, `dc:creator`; "Unknown" when absent)
#
# The Siri leg asserts two things of its own, because both fail silently
# otherwise: that the run announced `Engine: siri` (an ignored `--engine` would
# otherwise look exactly like a green Apple-engine run), and that its decoded
# duration is within 25 % of the Apple engine's for the same Book (a sample-rate
# mistake is a 2× gap, and release builds have hidden exactly that class of bug
# before — see ticket 07).
#
# The Siri leg SKIPS — loudly, and still exiting 0 — on a Mac with no Siri voice
# bundle, because macOS decides which machines have one and a missing bundle is
# not a saybook defect. Anything else (a bundle that cannot render, an ignored
# flag, a bad Audiobook) is a FAIL. To see the skip on a Mac that does have a
# bundle, point the catalog at an empty root:
#
#   SAYBOOK_SIRI_ASSETS_ROOT=/nonexistent ./Scripts/e2e.sh book.epub
#
# SAYBOOK_E2E_BIN replaces the binary both legs run. It exists so this script's
# own assertions can be exercised where the release binary cannot be (a Siri
# engine that will not render, say) and a run using it says so on stdout: that
# is a self-test of this script, not evidence about the release build.
#
# Requires: Xcode CLT (swift, unzip), afinfo (ships with macOS) and
# ffprobe (`brew install ffmpeg`) — ffprobe is the independent verifier for
# markers and metadata. Exits 0 when every assertion holds.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "  ok: $*"; }

usage() {
  echo "usage: ./Scripts/e2e.sh [--siri-full] [book.epub]"
  echo "  --siri-full   render the Book itself through --engine siri (slow) instead of"
  echo "                the in-repo fixture used by default; see the header of this script"
}

command -v ffprobe >/dev/null 2>&1 || fail "ffprobe not found — the independent verifier. Install with: brew install ffmpeg"

# --- arguments ---------------------------------------------------------------
siri_full=0
epub_arg=""
for arg in "$@"; do
  case "$arg" in
    --siri-full) siri_full=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; fail "unknown option: $arg" ;;
    *)
      [ -z "$epub_arg" ] || fail "more than one Book given: $epub_arg and $arg"
      epub_arg="$arg"
      ;;
  esac
done

WORK="$(mktemp -d /tmp/saybook-e2e.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# --- input ------------------------------------------------------------------
if [ -n "$epub_arg" ]; then
  EPUB="$epub_arg"
  [ -f "$EPUB" ] || fail "no such file: $EPUB"
else
  EPUB="$WORK/book.epub"
  echo "no EPUB given — downloading Project Gutenberg #11 (Alice's Adventures in Wonderland)…"
  curl -fL --silent --show-error -o "$EPUB" "https://www.gutenberg.org/ebooks/11.epub" \
    || fail "download failed (pass a local EPUB to run offline)"
fi
echo "Book: $EPUB"

# --- build ------------------------------------------------------------------
echo "building (release)…"
swift build -c release
BIN="${SAYBOOK_E2E_BIN:-$ROOT/.build/release/saybook}"
if [ -n "${SAYBOOK_E2E_BIN:-}" ]; then
  [ -x "$BIN" ] || fail "SAYBOOK_E2E_BIN is not an executable: $BIN"
  echo "note: running SAYBOOK_E2E_BIN=$BIN instead of .build/release/saybook —"
  echo "      this exercises this script's assertions, NOT the release binary"
fi

# --- the AVFoundation chapter probe ------------------------------------------
# Compiled rather than shipped as a binary: it exists so this script reads its
# own output the way a player does, and it must exercise the same AVFoundation
# the release binary's output will meet at runtime.
PROBE_SRC="$ROOT/Scripts/apple-chapters.swift"
PROBE="$WORK/apple-chapters"
[ -f "$PROBE_SRC" ] || fail "missing the AVFoundation probe: $PROBE_SRC"
# -warnings-as-errors, like the package itself (the probe is compiled
# outside SwiftPM, so it does not inherit Package.swift's setting).
swiftc -O -warnings-as-errors -o "$PROBE" "$PROBE_SRC" || fail "could not build the AVFoundation probe"
[ -x "$PROBE" ] || fail "the AVFoundation probe did not build: $PROBE"

# --- helpers -----------------------------------------------------------------

# Runs the binary with stderr captured to $1 and leaves the exit code in
# $RUN_EXIT, so a run that is *expected* to fail (the availability probe) cannot
# abort the script under `set -e`.
#
# stderr goes to a FILE, never a pipe: the Siri engine writes its own
# diagnostics to stderr from the calling thread (153 KB for one 6-second
# Chapter), so an undrained pipe fills its 64 KB buffer and the run blocks
# forever inside Apple's write. See ticket 08.
run_saybook() {
  local log="$1"
  shift
  set +e
  "$BIN" "$@" 2> "$log"
  RUN_EXIT=$?
  set -e
}

# The estimated decoded duration, in seconds, out of afinfo's own output.
afinfo_duration() { printf '%s' "$1" | sed -n 's|.*estimated duration: \([0-9.]*\) sec.*|\1|p'; }

# afinfo's estimated decoded duration of a file — empty when it does not decode.
decoded_duration() { afinfo_duration "$(afinfo "$1" || true)"; }

# Reads what the Book says about itself, for the assertions: want_title and
# want_author from its OPF, want_markers from saybook's own summary line in the
# run's stderr ($2). Sets them — plus the raw `Chapters`/`Skipped` counts the
# marker assertion quotes back — as globals.
read_expectations() {
  local epub="$1" log="$2"
  local opf_path opf summary

  opf_path="$(unzip -p "$epub" META-INF/container.xml | sed -n 's:.*full-path="\([^"]*\)".*:\1:p' | head -1 || true)"
  [ -n "$opf_path" ] || fail "cannot resolve the OPF path from META-INF/container.xml"
  opf="$(unzip -p "$epub" "$opf_path" || true)"
  # The leading `.*` consumes the line's indentation (sed's s// only replaces
  # the matched span); last-occurrence-on-a-line semantics are fine — real OPFs
  # put one element per line.
  want_title="$(printf '%s' "$opf" | sed -n 's|.*<dc:title[^>]*>[[:space:]]*\([^<]*\)[[:space:]]*</dc:title>.*|\1|p' | head -1)"
  want_author="$(printf '%s' "$opf" | sed -n 's|.*<dc:creator[^>]*>[[:space:]]*\([^<]*\)[[:space:]]*</dc:creator>.*|\1|p' | head -1)"
  [ -n "$want_author" ] || want_author="Unknown"

  summary="$(grep -E '^Chapters: ' "$log" | tail -1 || true)"
  if [ -z "$summary" ]; then
    echo "FAIL: no summary line in saybook's stderr" >&2
    cat "$log" >&2
    exit 1
  fi
  chapters="$(printf '%s' "$summary" | sed -n 's|.*Chapters: \([0-9]*\) ·.*|\1|p')"
  skipped="$(printf '%s' "$summary" | sed -n 's|.*Skipped: \([0-9]*\).*|\1|p')"
  [ -n "$chapters" ] && [ -n "$skipped" ] || fail "cannot parse the summary line: $summary"
  want_markers=$((chapters - skipped))
  [ "$want_markers" -ge 1 ] || fail "Book has $chapters chapters, $skipped skipped — nothing to assert"
}

# The four assertions, run against $1 (the Audiobook) using $2 (that run's
# stderr) only for the expected marker count. Reads want_title / want_author /
# want_markers; leaves the decoded duration in $last_duration.
assert_audiobook() {
  local out="$1" log="$2"
  local afinfo_out af_duration pb_duration chapters_out got_markers first_start titled tags_out got_title got_author

  # brand
  afinfo_out="$(afinfo "$out" || true)"
  printf '%s' "$afinfo_out" | grep -q "File type ID: *m4bf" \
    || fail "afinfo does not report the M4B file type (m4bf):"
  ok "brand: afinfo reports m4bf"
  ffprobe -v error -show_entries format_tags=major_brand -of default=noprint_wrappers=1 "$out" \
    | grep -q "major_brand=M4B" || fail "ffprobe major_brand is not M4B:"
  ok "brand: ffprobe major_brand is M4B"

  # duration
  af_duration="$(afinfo_duration "$afinfo_out")"
  [ -n "$af_duration" ] || fail "afinfo reports no duration (file does not decode):"
  awk -v d="$af_duration" 'BEGIN { exit d > 1.0 ? 0 : 1 }' \
    || fail "duration $af_duration s is implausibly short"
  ok "duration: afinfo decodes $af_duration s of audio"

  pb_duration="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1 "$out" 2>/dev/null | sed -n 's:^duration=::p' || true)"
  [ -n "$pb_duration" ] || fail "ffprobe reports no duration"
  awk -v a="$af_duration" -v p="$pb_duration" 'BEGIN { d = a - p; if (d < 0) d = -d; exit d <= 2.0 ? 0 : 1 }' \
    || fail "duration mismatch: afinfo $af_duration s vs ffprobe $pb_duration s"
  ok "duration: ffprobe agrees ($pb_duration s)"

  # chapter markers
  chapters_out="$(ffprobe -v error -show_chapters -of default=noprint_wrappers=1 "$out" 2>/dev/null || true)"
  got_markers="$(printf '%s' "$chapters_out" | grep -c '^id=' || true)"
  [ "$got_markers" -eq "$want_markers" ] \
    || fail "ffprobe reads $got_markers chapters, expected $want_markers (Chapters $chapters − Skipped $skipped)"
  ok "markers: $got_markers chapter(s), one per non-empty Chapter"

  # ffprobe's first start_time: take the line after the first `id=`.
  first_start="$(printf '%s\n' "$chapters_out" | awk '/^id=[0-9]+$/ {f=1; next} f && /^start_time=/ {sub(/^start_time=/,""); print; exit}')"
  [ "$first_start" = "0.000000" ] || fail "first chapter does not start at 0:00 (got $first_start)"
  ok "markers: first chapter starts at 0:00"

  titled="$(printf '%s\n' "$chapters_out" | awk '
    /^TAG:title=/{ t = substr($0, 11); gsub(/^[[:space:]]+|[[:space:]]+$/, "", t); if (t != "") n++ }
    END { print n + 0 }')"
  [ "$titled" -eq "$got_markers" ] || fail "$((got_markers - titled)) of $got_markers chapters have no title"
  ok "markers: every chapter carries a title"

  # chapter markers, as Apple's own players see them (ticket 12). ffprobe
  # above read `chpl`; AVFoundation reads a chapter text track, and the
  # difference is invisible until a real player shows no chapters at all.
  apple_chapters="$("$PROBE" "$out" 2>"$WORK/apple-chapters.err" || true)"
  if [ -z "$apple_chapters" ] && [ -s "$WORK/apple-chapters.err" ]; then
    echo "FAIL: the AVFoundation probe could not read $out:" >&2
    cat "$WORK/apple-chapters.err" >&2
    exit 1
  fi
  got_apple="$(printf '%s\n' "$apple_chapters" | grep -c . || true)"
  [ "$got_apple" -eq "$want_markers" ] \
    || fail "AVFoundation reads $got_apple chapters, expected $want_markers (Chapters $chapters − Skipped $skipped)"
  ok "markers: AVFoundation reads $got_apple chapter(s)"

  apple_first="$(printf '%s\n' "$apple_chapters" | head -1 | cut -f1)"
  awk -v s="$apple_first" 'BEGIN { exit (s >= 0 && s < 0.02) ? 0 : 1 }' \
    || fail "AVFoundation's first chapter starts at ${apple_first}s, not 0:00"
  ok "markers: AVFoundation's first chapter starts at 0:00"

  apple_titled="$(printf '%s\n' "$apple_chapters" | awk -F'\t' 'NF > 1 && length($2) > 0 { n++ } END { print n + 0 }')"
  [ "$apple_titled" -eq "$got_apple" ] \
    || fail "$((got_apple - apple_titled)) of $got_apple AVFoundation chapters have no title"
  ok "markers: every AVFoundation chapter carries a title"

  # metadata
  tags_out="$(ffprobe -v error -show_entries format_tags=title,artist -of default=noprint_wrappers=1 "$out" 2>/dev/null || true)"
  got_title="$(printf '%s\n' "$tags_out" | sed -n 's|^TAG:title=||p')"
  got_author="$(printf '%s\n' "$tags_out" | sed -n 's|^TAG:artist=||p')"
  if [ -n "$want_title" ]; then
    [ "$got_title" = "$want_title" ] || fail "metadata title is \"$got_title\", OPF says \"$want_title\""
    ok "metadata: title \"$got_title\""
  else
    [ -n "$got_title" ] || fail "metadata title missing (OPF also lacks dc:title — nothing to compare, but a Book should have one)"
    ok "metadata: title present (OPF has no dc:title to compare)"
  fi
  [ "$got_author" = "$want_author" ] || fail "metadata artist is \"$got_author\", expected \"$want_author\""
  ok "metadata: artist \"$got_author\""

  last_duration="$af_duration"
}

# --- leg 1: the Book, default engine -----------------------------------------
OUT="$WORK/book.m4b"
LOG="$WORK/run.log"
echo "running: saybook <book> -o $OUT"
run_saybook "$LOG" "$EPUB" -o "$OUT"
if [ "$RUN_EXIT" -ne 0 ]; then
  echo "FAIL: saybook exited $RUN_EXIT (expected 0)" >&2
  cat "$LOG" >&2
  exit 1
fi
[ -f "$OUT" ] || fail "no output file at $OUT"
ok "run exited 0, output exists"

read_expectations "$EPUB" "$LOG"
assert_audiobook "$OUT" "$LOG"
book_duration="$last_duration"

# --- leg 2: the private Siri engine ------------------------------------------
# A small in-repo Book, not the Book above: the Siri engine renders at ~8×
# realtime, so a Siri leg over Alice would add ~20 minutes to a ~3-minute
# script for coverage the release path does not need. `--siri-full` opts into
# the Book itself.
if [ "$siri_full" -eq 1 ]; then
  SIRI_BOOK="$EPUB"
else
  SIRI_BOOK="$ROOT/Tests/SaybookTests/Fixtures/multi-chapter.epub"
  [ -f "$SIRI_BOOK" ] || fail "no Book for the Siri leg: $SIRI_BOOK"
fi
siri_skipped=0
echo
echo "Siri leg: --engine siri on $SIRI_BOOK"

# Is there a Siri voice on this Mac? Ask the binary rather than re-implement
# Apple's asset layout in bash: the catalog is the single source of truth, and
# its root (`/System/Library/AssetsV2/…`, plus the `gryphon.cfg` marker) is the
# thing most likely to move. `--voice` is resolved before any work happens, so
# this costs one startup and writes nothing. Any failure that is not "no bundle
# installed" stays a FAIL: a bundle that exists but cannot render is exactly the
# thing this leg exists to catch.
PROBE_LOG="$WORK/siri-probe.log"
run_saybook "$PROBE_LOG" "$SIRI_BOOK" --engine siri --voice __no_such_voice__ -o "$WORK/siri-probe.m4b"
case "$RUN_EXIT" in
  0)
    echo "FAIL: --engine siri accepted a voice that does not exist (exit 0)" >&2
    cat "$PROBE_LOG" >&2
    exit 1
    ;;
  1) ;;  # the expected outcome; the message below says which kind of failure
  *)
    echo "FAIL: the Siri availability probe exited $RUN_EXIT (expected 1)" >&2
    cat "$PROBE_LOG" >&2
    exit 1
    ;;
esac

skip_reason="$(grep -m1 -o 'no Siri voice bundle is installed.*' "$PROBE_LOG" | sed 's/)[[:space:]]*$//' || true)"
if [ -n "$skip_reason" ]; then
  echo "  skip: Siri leg — $skip_reason"
  echo "        (macOS delivers these itself; the leg runs wherever one is present)"
  siri_skipped=1
else
  SIRI_OUT="$WORK/siri.m4b"
  SIRI_LOG="$WORK/siri.log"
  echo "running: saybook <siri book> --engine siri -o $SIRI_OUT"
  run_saybook "$SIRI_LOG" "$SIRI_BOOK" --engine siri -o "$SIRI_OUT"
  if [ "$RUN_EXIT" -ne 0 ]; then
    echo "FAIL: saybook --engine siri exited $RUN_EXIT (expected 0)" >&2
    cat "$SIRI_LOG" >&2
    exit 1
  fi
  [ -f "$SIRI_OUT" ] || fail "no output file at $SIRI_OUT"
  ok "run exited 0, output exists"

  # A `--engine` flag the binary ignored would produce a perfectly good
  # Apple-engine Audiobook, so the run has to say which engine talked.
  grep -q '^Engine: siri' "$SIRI_LOG" || {
    echo "FAIL: the --engine siri run never announced 'Engine: siri':" >&2
    cat "$SIRI_LOG" >&2
    exit 1
  }
  ok "engine: the run announced Engine: siri"

  read_expectations "$SIRI_BOOK" "$SIRI_LOG"
  assert_audiobook "$SIRI_OUT" "$SIRI_LOG"

  # Cross-engine duration sanity. The two engines are different voices at
  # different speeds, so this is not an equality — but a 2× gap is a
  # sample-rate mistake, and the release path has shipped that class of bug
  # before (ticket 07). The reference is the Apple engine on the same Book:
  # leg 1's own render when the Siri leg is running that same Book.
  if [ "$SIRI_BOOK" = "$EPUB" ]; then
    ref_duration="$book_duration"
    ref_how="leg 1"
  else
    REF_OUT="$WORK/apple-reference.m4b"
    REF_LOG="$WORK/apple-reference.log"
    echo "running: saybook <siri book> -o $REF_OUT (Apple-engine reference for the duration check)"
    run_saybook "$REF_LOG" "$SIRI_BOOK" -o "$REF_OUT"
    [ "$RUN_EXIT" -eq 0 ] || {
      echo "FAIL: the Apple-engine duration reference exited $RUN_EXIT (expected 0)" >&2
      cat "$REF_LOG" >&2
      exit 1
    }
    ref_duration="$(decoded_duration "$REF_OUT")"
    [ -n "$ref_duration" ] || fail "the Apple-engine duration reference does not decode: $REF_OUT"
    ref_how="the Apple engine on the same fixture"
  fi
  awk -v s="$last_duration" -v r="$ref_duration" \
    'BEGIN { if (r <= 0) exit 2; d = (s - r) / r; if (d < 0) d = -d; exit d <= 0.25 ? 0 : 1 }' \
    || fail "the Siri engine rendered $last_duration s where $ref_how rendered $ref_duration s — more than 25% apart (a 2x gap is a sample-rate error)"
  ok "engine: $last_duration s against $ref_how's $ref_duration s (within 25%)"
fi

echo
if [ "$siri_skipped" -eq 1 ]; then
  echo "E2E PASS: $OUT (Siri leg skipped — this Mac has no Siri voice bundle)"
else
  echo "E2E PASS: $OUT (+ Siri leg: $SIRI_OUT)"
fi
