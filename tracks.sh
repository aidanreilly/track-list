#!/bin/sh
#
# tracks.sh — serialized SongRec calls with jittered pacing

set -eu

# Args
MIX_FILE="${1:-}"; [ -n "$MIX_FILE" ] || { echo "Usage: $0 /path/to/mix.mp3" >&2; exit 1; }

# Defaults
: "${STEP:=120}"                    # seconds between checkpoints
: "${SNIP_LEN:=12}"                 # seconds per attempt
: "${OFFSETS:=30 15}"               # positions within each window
: "${OUT_DIR:=out}"
: "${TMP_DIR:=/tmp/songrec_snips}"
: "${RATE_INTERVAL:=2.5}"           # seconds between SongRec calls
: "${JITTER_MAX:=1.5}"              # max extra jitter seconds

command -v ffprobe >/dev/null || { echo "ffprobe not found"; exit 2; }
command -v ffmpeg  >/dev/null || { echo "ffmpeg not found";  exit 2; }
command -v songrec >/dev/null || { echo "songrec not found"; exit 2; }
command -v jq >/dev/null || { echo "jq not found"; exit 2; }

mkdir -p "$OUT_DIR" "$TMP_DIR" "$OUT_DIR/json"
RESULTS_TSV="${OUT_DIR}/results.tsv"
TRACKS_TXT="${OUT_DIR}/tracks.txt"
ERRORS_LOG="${OUT_DIR}/errors.log"
: > "$RESULTS_TSV"; : > "$ERRORS_LOG"

# Rate limiter
RATE_STAMP_FILE="/tmp/songrec_last_call"
RETRY_UNTIL_FILE="/tmp/songrec_retry_after_until"

rate_limit() {
  # Honor Retry-After if present (epoch seconds)
  if [ -f "$RETRY_UNTIL_FILE" ]; then
    retry_until="$(cat "$RETRY_UNTIL_FILE" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    if [ "$now" -lt "$retry_until" ]; then
      sleep "$(( retry_until - now ))"
    else
      rm -f "$RETRY_UNTIL_FILE" || true
    fi
  fi

  # Minimum spacing since last call
  now="$(date +%s)"
  last_raw="$(cat "$RATE_STAMP_FILE" 2>/dev/null || echo 0)"
  # Strip fractional part if an older run wrote %s.%N
  last="${last_raw%%.*}"
  # If not a pure integer, treat as 0
  case "$last" in ''|*[!0-9]*) last=0 ;; esac

  elapsed=$(( now - last ))
  wait_s="$(awk -v elapsed="$elapsed" -v interval="$RATE_INTERVAL" \
    'BEGIN{d=interval-elapsed; if(d<0)d=0; printf "%.3f\n", d}')"
  sleep "$wait_s"

  # Add random jitter up to JITTER_MAX (if > 0)
  jitter="$(awk -v j="$JITTER_MAX" 'BEGIN{srand(); if (j>0) printf "%.3f\n", rand()*j; else print "0.000"}')"
  sleep "$jitter"

  # Stamp (seconds only)
  date +%s > "$RATE_STAMP_FILE"
}

# Total duration (integer seconds)
DUR="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$MIX_FILE" | awk '{printf("%d\n",$1)}')"
[ "$DUR" -gt 0 ] || { echo "Could not read duration via ffprobe" | tee -a "$ERRORS_LOG"; exit 3; }

extract_title() {
  jq -r '
    ( .track.subtitle + " - " + .track.title ) //
    ( .matches[0].track.subtitle + " - " + .matches[0].track.title ) //
    ( .matches[0].subtitle + " - " + .matches[0].title ) //
    ( .artist_name + " - " + .song_name ) //  # some builds
    empty
  ' 2>/dev/null | head -n1
}

recognize_at() {
  start="$1"; wav="$TMP_DIR/snippet_${start}.wav"; json="$OUT_DIR/json/${start}.json"

  ffmpeg -hide_banner -nostdin -y -loglevel error \
    -ss "$start" -t "$SNIP_LEN" -i "$MIX_FILE" \
    -vn -ac 1 -ar 44100 -af "highpass=f=60,dynaudnorm=f=150:g=5,loudnorm=I=-16:TP=-1.5:LRA=11" \
    -c:a pcm_s16le "$wav" || { echo "ffmpeg failed at $start" >>"$ERRORS_LOG"; return 1; }

  # Serialized, jittered call
  rate_limit
  out=""; title=""
  if out="$(RUST_LOG=reqwest=warn,songrec=debug songrec recognize --json "$wav" 2>>"$ERRORS_LOG" || true)"; then
    printf '%s' "$out" > "$json"
    title="$(printf '%s' "$out" | extract_title || true)"
    if [ -n "$title" ] && ! printf '%s' "$title" | grep -Eq '^[[:space:]]*-[[:space:]]*$'; then
      echo "$title"
      return 0
    fi
  fi

  return 2
}

# Main loop
t=0
while [ "$t" -lt "$DUR" ]; do
  ts="$(printf "%02d:%02d" $((t/60)) $((t%60)))"
  found=""
  for off in $OFFSETS; do
    start=$(( t + off ))
    if [ "$start" -ge 0 ] && [ $(( start + SNIP_LEN )) -le "$DUR" ]; then
      if title="$(recognize_at "$start")"; then
        found="$title"
        break
      fi
    fi
    # No extra sleep here; rate_limit() handles pacing
  done
  if [ -n "$found" ]; then
    printf "%s\t%s\n" "$ts" "$found" | tee -a "$RESULTS_TSV" >/dev/null
    echo "[$ts] $found"
  else
    printf "%s\tUNRECOGNIZED\n" "$ts" | tee -a "$RESULTS_TSV" >/dev/null
    echo "[$ts] UNRECOGNIZED"
  fi
  t=$(( t + STEP ))
done

cut -f2 "$RESULTS_TSV" | awk 'NF' | uniq > "$TRACKS_TXT"

echo "Timeline: $RESULTS_TSV"
echo "Unique tracks: $TRACKS_TXT"
echo "Errors: $ERRORS_LOG"
