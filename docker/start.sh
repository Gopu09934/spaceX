#!/bin/bash
set -euo pipefail

#############################################
# 24/7 YouTube stream - independent pipelines
#
#   [video feeder]  loops VIDEO_URL list forever  -> FIFO (mpegts, h264) --+
#                                                                          +--> [publisher] -> YouTube RTMP
#   [audio feeder]  loops AUDIO_URL list forever  -> FIFO (raw PCM)     ---+
#
# - Video and audio never depend on each other.
# - If a video URL fails, a black+overlay slate is streamed and the loop
#   moves on. Audio keeps playing.
# - If an audio URL fails/is slow/is unset, silence is streamed and video
#   keeps playing. Downloaded tracks loop gap-free from local disk.
# - The RTMP connection is held by ONE long-running ffmpeg (no reconnect
#   between clips).
#
# Env:
#   VIDEO_URL           required, comma/newline separated list
#   YOUTUBE_STREAM_KEY  required
#   AUDIO_URL           optional, comma/newline separated list (mp3 etc.)
#                       unset -> silent audio track
#   DEDUPE_URLS=false   SHUFFLE_URLS=true   (video list only)
#
# NOTE: the video files' own audio is intentionally NOT used, so that audio
# is 100% independent. All sound comes from AUDIO_URL.
#############################################

if [ -z "${VIDEO_URL:-}" ]; then echo "ERROR: VIDEO_URL is not set"; exit 1; fi
if [ -z "${YOUTUBE_STREAM_KEY:-}" ]; then echo "ERROR: YOUTUBE_STREAM_KEY is not set"; exit 1; fi
if [ ! -f overlay.png ]; then echo "ERROR: overlay.png not found in $(pwd)"; exit 1; fi

DEDUPE_URLS="${DEDUPE_URLS:-false}"
SHUFFLE_URLS="${SHUFFLE_URLS:-true}"
RETRY_DELAY=5

echo "========================================"
echo "Starting 24/7 YouTube Stream (independent audio/video)"
echo "Output : 1280x720 @ 30fps, 3000k video, 128k AAC"
echo "========================================"

#############################################
# Helpers
#############################################
parse_list() {   # comma/newline separated -> one trimmed entry per line
    printf '%s\n' "$1" | tr '\r,' '\n\n' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | awk 'NF'
}

kill_tree() {
    local p="$1" c
    for c in $(pgrep -P "$p" 2>/dev/null || true); do kill_tree "$c"; done
    kill "$p" 2>/dev/null || true
}

WORKDIR="$(mktemp -d)"
VFIFO="$WORKDIR/video.ts"
AFIFO="$WORKDIR/audio.pcm"
mkdir -p "$WORKDIR/audio"
mkfifo "$VFIFO" "$AFIFO"

PIDS=()
cleanup() {
    trap - EXIT INT TERM
    for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill_tree "$p"; done
    rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

# Hold both FIFOs open read+write for the whole run. This means:
#  - feeders never get EPIPE / the publisher never gets EOF when a feeder
#    restarts an ffmpeg process
#  - opening never blocks
exec 3<>"$VFIFO" 4<>"$AFIFO"

flush_fifo() {   # drop stale bytes after a publisher restart (keeps alignment)
    local f="$1" n
    for n in 1 2 3 4; do
        dd if="$f" of=/dev/null bs=64k iflag=nonblock 2>/dev/null || true
    done
}

#############################################
# VIDEO pipeline
#############################################
BASE_FILTER="[0:v]scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:black[video];"
BASE_FILTER+="[1:v]scale=1280:720:flags=fast_bilinear[ovl];"
BASE_FILTER+="[video][ovl]overlay=0:0:shortest=1[final]"

VENC=(-r 30 -c:v libx264 -preset ultrafast -tune zerolatency -threads 2
      -profile:v high -level 4.1 -pix_fmt yuv420p
      -b:v 3000k -maxrate 3000k -bufsize 6000k
      -g 60 -keyint_min 60 -sc_threshold 0
      -an -f mpegts -flush_packets 1 pipe:1)

mapfile -t URLS < <(parse_list "$VIDEO_URL")
TOTAL_LISTED=${#URLS[@]}
if [ "$DEDUPE_URLS" = true ] && [ "$TOTAL_LISTED" -gt 0 ]; then
    mapfile -t URLS < <(printf '%s\n' "${URLS[@]}" | awk '!seen[$0]++')
fi
NUM_URLS=${#URLS[@]}
if [ "$NUM_URLS" -eq 0 ]; then
    echo "ERROR: VIDEO_URL contained no valid entries after parsing"
    exit 1
fi
echo "Parsed $TOTAL_LISTED video URL(s) -> playing $NUM_URLS (dedupe=${DEDUPE_URLS}, shuffle=${SHUFFLE_URLS})"

LAST_PLAYED=""
shuffle_urls() {   # reshuffle each pass; avoid back-to-back repeats
    local n=${#URLS[@]} try j clash
    local -a S
    if [ "$SHUFFLE_URLS" != true ] || [ "$n" -lt 2 ]; then return 0; fi
    for try in $(seq 1 50); do
        mapfile -t S < <(printf '%s\n' "${URLS[@]}" | shuf)
        clash=false
        if [ "${S[0]}" = "$LAST_PLAYED" ]; then clash=true; fi
        for ((j = 1; j < n; j++)); do
            if [ "${S[$j]}" = "${S[$((j - 1))]}" ]; then clash=true; fi
        done
        if [ "$clash" = false ]; then break; fi
    done
    URLS=("${S[@]}")
}

video_slate() {   # keeps video flowing while a URL is failing
    ffmpeg -hide_banner -loglevel error -nostdin -re \
        -f lavfi -i "color=c=black:s=1280x720:r=30:d=${RETRY_DELAY}" \
        -loop 1 -framerate 30 -i overlay.png \
        -filter_complex "[1:v]scale=1280:720:flags=fast_bilinear[ovl];[0:v][ovl]overlay=0:0:shortest=1[final]" \
        -map "[final]" "${VENC[@]}" >&3 || true
}

video_feeder() {   # loops the video list forever
    local url rc started
    while true; do
        shuffle_urls
        for url in "${URLS[@]}"; do
            LAST_PLAYED="$url"
            echo "[video] playing: $url"
            started=$SECONDS
            rc=0
            ffmpeg -hide_banner -loglevel warning -nostdin \
                -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
                -re -i "$url" \
                -loop 1 -framerate 30 -i overlay.png \
                -filter_complex "$BASE_FILTER" \
                -map "[final]" "${VENC[@]}" >&3 || rc=$?
            if [ "$rc" -ne 0 ] || [ $((SECONDS - started)) -lt 2 ]; then
                echo "[video] WARNING: '$url' failed/ended instantly (rc=$rc) - slate for ${RETRY_DELAY}s, then next"
                video_slate
            fi
        done
    done
}

#############################################
# AUDIO pipeline
#
# Each track is downloaded once (in the background, with endless retry)
# and converted to raw 48k stereo PCM on local disk. The feeder cats all
# finished tracks in an endless loop -> gap-free looping, no network
# dependency after download. Until a track is ready (or if none is
# configured / all fail) it emits silence, so the publisher never waits.
# 192000 bytes = 1 second of s16le 48kHz stereo.
#############################################
mapfile -t AUDIO_URLS < <(parse_list "${AUDIO_URL:-}")
AUDIO_NUM=${#AUDIO_URLS[@]}
if [ "$AUDIO_NUM" -gt 0 ]; then
    echo "Loaded $AUDIO_NUM background audio track(s) from AUDIO_URL (looped forever)."
else
    echo "AUDIO_URL not set - streaming silent audio."
fi

audio_fetch() {   # $1=index $2=url ; retries until it succeeds
    local idx="$1" url="$2" out
    out="$WORKDIR/audio/track_$(printf '%03d' "$idx").raw"
    until ffmpeg -hide_banner -loglevel error -nostdin -y \
            -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
            -i "$url" -vn -f s16le -ar 48000 -ac 2 "$out.part"; do
        echo "[audio] WARNING: download failed for $url - retrying in ${RETRY_DELAY}s"
        sleep "$RETRY_DELAY"
    done
    mv "$out.part" "$out"
    echo "[audio] ready: $url"
}

audio_feeder() {
    while true; do
        {
            local files
            while true; do
                files=("$WORKDIR"/audio/track_*.raw)
                if [ -e "${files[0]}" ]; then
                    cat "${files[@]}"
                else
                    head -c 192000 /dev/zero
                fi
            done
        } | ffmpeg -hide_banner -loglevel error \
                -re -f s16le -ar 48000 -ac 2 -i pipe:0 \
                -c:a copy -f s16le pipe:1 >&4 || true
        echo "[audio] feeder restarted"
        sleep 1
    done
}

#############################################
# Start feeders (independent background jobs)
#############################################
i=0
for a in "${AUDIO_URLS[@]}"; do
    audio_fetch "$i" "$a" &
    PIDS+=("$!")
    i=$((i + 1))
done

video_feeder & PIDS+=("$!")
audio_feeder & PIDS+=("$!")

#############################################
# Publisher: ONE long-running ffmpeg to YouTube.
# Video is copied (already encoded by the feeder), audio is AAC-encoded.
# Restarts forever if the RTMP link drops.
#############################################
while true; do
    echo "----------------------------------------"
    echo "Publishing to YouTube..."
    echo "----------------------------------------"
    set +e
    ffmpeg -hide_banner -loglevel info -nostdin \
        -thread_queue_size 1024 -f mpegts -i "$VFIFO" \
        -thread_queue_size 1024 -f s16le -ar 48000 -ac 2 -i "$AFIFO" \
        -map 0:v:0 -map 1:a:0 \
        -c:v copy \
        -c:a aac -b:a 128k -ar 48000 -ac 2 \
        -f flv "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}"
    rc=$?
    set -e
    echo "WARNING: publisher ffmpeg exited (code ${rc}). Reconnecting in ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
    flush_fifo "$VFIFO"
    flush_fifo "$AFIFO"
done
