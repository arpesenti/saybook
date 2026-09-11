#!/usr/bin/env bash
#
# Manual end-to-end check for saybook (ticket 07). One command:
#
#   ./Scripts/e2e.sh [book.epub]
#
# With no argument it downloads a small real Book (Alice's Adventures in
# Wonderland, Project Gutenberg #11) — the only network access anywhere in
# the project, and only in this manual step; pass a local EPUB to run fully
# offline.
#
# Builds the release configuration, runs the real binary on the Book, and
# asserts the Audiobook with independent tools:
#   • brand      — afinfo's file type ID is `m4bf` and ffprobe's
#                  `major_brand` is `M4B `
#   • duration   — the file decodes (afinfo reports a duration) and ffprobe
#                  agrees within tolerance
#   • markers    — ffprobe reads one chapter per non-empty Chapter
#                  (saybook's own summary: Chapters − Skipped), the first at
#                  0:00, every chapter titled
#   • metadata   — ffprobe's title/artist match the Book's OPF
#                  (`dc:title`, `dc:creator`; "Unknown" when absent)
#
# Requires: Xcode CLT (swift, unzip), afinfo (ships with macOS) and
# ffprobe (`brew install ffmpeg`) — ffprobe is the independent verifier for
# markers and metadata. Exits 0 when every assertion holds.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "  ok: $*"; }

command -v ffprobe >/dev/null 2>&1 || fail "ffprobe not found — the independent verifier. Install with: brew install ffmpeg"

WORK="$(mktemp -d /tmp/saybook-e2e.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# --- input ------------------------------------------------------------------
if [ $# -ge 1 ]; then
  EPUB="$1"
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
BIN="$ROOT/.build/release/saybook"

# --- run --------------------------------------------------------------------
OUT="$WORK/book.m4b"
LOG="$WORK/run.log"
echo "running: saybook <book> -o $OUT"
set +e
"$BIN" "$EPUB" -o "$OUT" 2> "$LOG"
RUN_EXIT=$?
set -e
[ "$RUN_EXIT" -eq 0 ] || { fail "saybook exited $RUN_EXIT (expected 0):"; cat "$LOG"; }
[ -f "$OUT" ] || fail "no output file at $OUT"
ok "run exited 0, output exists"

# --- expectations from the Book itself ---------------------------------------
OPF_PATH="$(unzip -p "$EPUB" META-INF/container.xml | sed -n 's:.*full-path="\([^"]*\)".*:\1:p' | head -1)"
[ -n "$OPF_PATH" ] || fail "cannot resolve the OPF path from META-INF/container.xml"
OPF="$(unzip -p "$EPUB" "$OPF_PATH")"
want_title="$(printf '%s' "$OPF" | sed -n 's|.*<dc:title[^>]*>[[:space:]]*\([^<]*\)[[:space:]]*</dc:title>.*|\1|p' | head -1)"
want_author="$(printf '%s' "$OPF" | sed -n 's|.*<dc:creator[^>]*>[[:space:]]*\([^<]*\)[[:space:]]*</dc:creator>.*|\1|p' | head -1)"
[ -n "$want_author" ] || want_author="Unknown"

summary="$(grep -E '^Chapters: ' "$LOG" | tail -1)"
[ -n "$summary" ] || fail "no summary line in saybook's stderr:"; cat "$LOG"
chapters="$(printf '%s' "$summary" | sed -n 's|.*Chapters: \([0-9]*\) ·.*|\1|p')"
skipped="$(printf '%s' "$summary" | sed -n 's|.*Skipped: \([0-9]*\).*|\1|p')"
want_markers=$((chapters - skipped))
[ "$want_markers" -ge 1 ] || fail "Book has $chapters chapters, $skipped skipped — nothing to assert"

# --- brand -------------------------------------------------------------------
afinfo_out="$(afinfo "$OUT")"
printf '%s' "$afinfo_out" | grep -q "File type ID: *m4bf" \
  || fail "afinfo does not report the M4B file type (m4bf):"
ok "brand: afinfo reports m4bf"
ffprobe -v error -show_entries format_tags=major_brand -of default=noprint_wrappers=1 "$OUT" \
  | grep -q "major_brand=M4B" || fail "ffprobe major_brand is not M4B:"
ok "brand: ffprobe major_brand is M4B"

# --- duration ------------------------------------------------------------------
af_duration="$(printf '%s' "$afinfo_out" | sed -n 's|.*estimated duration: \([0-9.]*\) sec.*|\1|p')"
[ -n "$af_duration" ] || fail "afinfo reports no duration (file does not decode):"
awk -v d="$af_duration" 'BEGIN { exit d > 1.0 ? 0 : 1 }' \
  || fail "duration $af_duration s is implausibly short"
ok "duration: afinfo decodes $af_duration s of audio"

pb_duration="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1 "$OUT" | sed -n 's:^duration=::p')"
[ -n "$pb_duration" ] || fail "ffprobe reports no duration"
awk -v a="$af_duration" -v p="$pb_duration" 'BEGIN { d = a - p; if (d < 0) d = -d; exit d <= 2.0 ? 0 : 1 }' \
  || fail "duration mismatch: afinfo $af_duration s vs ffprobe $pb_duration s"
ok "duration: ffprobe agrees ($pb_duration s)"

# --- chapter markers -----------------------------------------------------------
chapters_out="$(ffprobe -v error -show_chapters -of default=noprint_wrappers=1 "$OUT")"
got_markers="$(printf '%s' "$chapters_out" | grep -c '^id=' || true)"
[ "$got_markers" -eq "$want_markers" ] \
  || fail "ffprobe reads $got_markers chapters, expected $want_markers (Chapters $chapters − Skipped $skipped)"
ok "markers: $got_markers chapter(s), one per non-empty Chapter"

# ffprobe's first start_time: take the line after the first `id=`.
first_start="$(printf '%s\n' "$chapters_out" | awk '/^id=[0-9]+$/ {f=1; next} f && /^start_time=/ {sub(/^start_time=/,""); print; exit}')"
[ "$first_start" = "0.000000" ] || fail "first chapter does not start at 0:00 (got $first_start)"
ok "markers: first chapter starts at 0:00"

untitled="$(printf '%s\n' "$chapters_out" | awk -v n="$got_markers" '
  /^TAG:title=$/{ t = substr($0, 11); gsub(/^[[:space:]]+|[[:space:]]+$/, "", t); if (t == "") u++ }
  END { print u + 0 }')"
[ "$untitled" -eq 0 ] || fail "$untitled of $got_markers chapters have no title"
ok "markers: every chapter carries a title"

# --- metadata --------------------------------------------------------------------
tags_out="$(ffprobe -v error -show_entries format_tags=title,artist -of default=noprint_wrappers=1 "$OUT")"
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

echo
echo "E2E PASS: $OUT"
