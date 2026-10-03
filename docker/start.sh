#!/bin/bash
set -euo pipefail

#############################################
# 24/7 YouTube stream (video + its own audio)
#
#   [video feeder]  loops VIDEO_URL list forever -> FIFO (mpegts: h264 + aac)
#                                                       |
#                                                  [publisher] -> YouTube RTMP
#
# - Each video's OWN audio is streamed.
# - If a video has no audio track, silence is added for that clip.
# - If a video URL fails, a black+overlay slate (with silence) is streamed
#   and the loop moves on.
# - The RTMP connection is held by ONE long-running ffmpeg (no reconnect
#   between clips).
#
# Env:
#   VIDEO_URL           required, comma/newline separated list
#   YOUTUBE_STREAM_KEY  required
#   DEDUPE_URLS=false   SHUFFLE_URLS=true
#############################################

if [ -z "${VIDEO_URL:-}" ]; then echo "ERROR: VIDEO_URL is not set"; exit 1; fi
if [ -z "${YOUTUBE_STREAM_KEY:-}" ]; then echo "ERROR: YOUTUBE_STREAM_KEY is not set"; exit 1; fi
if [ ! -f overlay.png ]; then echo "ERROR: overlay.png not found in $(pwd)"; exit 1; fi

DEDUPE_URLS="${DEDUPE_URLS:-false}"
SHUFFLE_URLS="${SHUFFLE_URLS:-true}"
RETRY_DELAY=5

echo "========================================"
echo "Starting 24/7 YouTube Stream (video + its own audio)"
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
STREAM_FIFO="$WORKDIR/stream.ts"
mkfifo "$STREAM_FIFO"

PIDS=()
cleanup() {
    trap - EXIT INT TERM
    for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill_tree "$p"; done
    rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

# Hold the FIFO open read+write for the whole run so that:
#  - the feeder never gets EPIPE / the publisher never gets EOF when a
#    clip's ffmpeg process ends
#  - opening never blocks
exec 3<>"$STREAM_FIFO"

flush_fifo() {   # drop stale bytes after a publisher restart
    local n
    for n in 1 2 3 4; do
        dd if="$STREAM_FIFO" of=/dev/null bs=64k iflag=nonblock 2>/dev/null || true
    done
}

#############################################
# Encoder settings
#############################################
VIDEO_GRAPH="[0:v]scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:black[video];"
VIDEO_GRAPH+="[1:v]scale=1280:720:flags=fast_bilinear[ovl];"
VIDEO_GRAPH+="[video][ovl]overlay=0:0:shortest=1[final]"

# clip has audio: resample/normalize its own audio inside the same graph
GRAPH_WITH_AUDIO="${VIDEO_GRAPH};[0:a:0]aresample=48000:async=1,aformat=channel_layouts=stereo[aout]"

OUT_ENC=(-r 30 -c:v libx264 -preset ultrafast -tune zerolatency -threads 2
         -profile:v high -level 4.1 -pix_fmt yuv420p
         -b:v 3000k -maxrate 3000k -bufsize 6000k
         -g 60 -keyint_min 60 -sc_threshold 0
         -c:a aac -b:a 128k -ar 48000 -ac 2
         -f mpegts -flush_packets 1 pipe:1)

#############################################
# URL list
#############################################
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

has_audio() {   # $1=url ; true if the file has an audio stream
    local out
    out="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_type \
            -of csv=p=0 "$1" 2>/dev/null || true)"
    [ -n "$out" ]
}

#############################################
# Slate: keeps video+audio flowing while a URL is failing
#############################################
video_slate() {
    ffmpeg -hide_banner -loglevel error -nostdin -re \
        -f lavfi -i "color=c=black:s=1280x720:r=30:d=${RETRY_DELAY}" \
        -loop 1 -framerate 30 -i overlay.png \
        -f lavfi -i "anullsrc=r=48000:cl=stereo" \
        -filter_complex "[1:v]scale=1280:720:flags=fast_bilinear[ovl];[0:v][ovl]overlay=0:0:shortest=1[final]" \
        -map "[final]" -map 2:a -t "$RETRY_DELAY" "${OUT_ENC[@]}" >&3 || true
}

#############################################
# Video feeder: loops the list forever
#############################################
video_feeder() {
    local url rc started
    while true; do
        shuffle_urls
        for url in "${URLS[@]}"; do
            LAST_PLAYED="$url"
            echo "[video] playing: $url"
            started=$SECONDS
            rc=0
            if has_audio "$url"; then
                ffmpeg -hide_banner -loglevel warning -nostdin \
                    -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
                    -re -i "$url" \
                    -loop 1 -framerate 30 -i overlay.png \
                    -filter_complex "$GRAPH_WITH_AUDIO" \
                    -map "[final]" -map "[aout]" \
                    "${OUT_ENC[@]}" >&3 || rc=$?
            else
                echo "[video] no audio track in this clip - adding silence"
                ffmpeg -hide_banner -loglevel warning -nostdin \
                    -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
                    -re -i "$url" \
                    -loop 1 -framerate 30 -i overlay.png \
                    -f lavfi -i "anullsrc=r=48000:cl=stereo" \
                    -filter_complex "$VIDEO_GRAPH" \
                    -map "[final]" -map 2:a -shortest \
                    "${OUT_ENC[@]}" >&3 || rc=$?
            fi
            if [ "$rc" -ne 0 ] || [ $((SECONDS - started)) -lt 2 ]; then
                echo "[video] WARNING: '$url' failed/ended instantly (rc=$rc) - slate for ${RETRY_DELAY}s, then next"
                video_slate
            fi
        done
    done
}

video_feeder & PIDS+=("$!")

#############################################
# Publisher: ONE long-running ffmpeg to YouTube.
# Video and audio are already encoded by the feeder, so just copy.
# Restarts forever if the RTMP link drops.
#############################################
while true; do
    echo "----------------------------------------"
    echo "Publishing to YouTube..."
    echo "----------------------------------------"
    set +e
    ffmpeg -hide_banner -loglevel info -nostdin \
        -thread_queue_size 1024 -f mpegts -i "$STREAM_FIFO" \
        -map 0:v:0 -map 0:a:0 \
        -c copy \
        -f flv "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}"
    rc=$?
    set -e
    echo "WARNING: publisher ffmpeg exited (code ${rc}). Reconnecting in ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
    flush_fifo
done
