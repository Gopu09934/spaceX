#!/bin/bash
set -euo pipefail

#############################################
# Validate Environment Variables
#############################################
if [ -z "${VIDEO_URL:-}" ]; then
    echo "ERROR: VIDEO_URL is not set"
    exit 1
fi
if [ -z "${YOUTUBE_STREAM_KEY:-}" ]; then
    echo "ERROR: YOUTUBE_STREAM_KEY is not set"
    exit 1
fi

echo "========================================"
echo "Starting 24/7 YouTube Stream (simple overlay)"
echo "Output Resolution : 1280x720 (720p — sized for a 2-core CI runner)"
echo "FPS               : 30"
echo "========================================"

#############################################
# Simple filter: scale/pad video to 1280x720,
# scale overlay.png to match, composite it on top.
#############################################
FILTER="[0:v]scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:black[video];"
FILTER+="[1:v]scale=1280:720:flags=fast_bilinear[ovl];"
FILTER+="[video][ovl]overlay=0:0[final]"

#############################################
# Auto-restart on failure
#############################################
MAX_RETRIES=5       # per-video retry attempts before moving on
RETRY_DELAY=5        # seconds between retries

#############################################
# Stream one video with automatic retry on
# failure/crash (e.g. Bus error, network drop),
# instead of letting set -e kill the script.
#############################################
run_video() {
    local url="$1"
    local attempt=1

    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        echo "----------------------------------------"
        echo "Streaming (attempt ${attempt}/${MAX_RETRIES}):"
        echo "$url"
        echo "----------------------------------------"

        set +e
        ffmpeg \
        -hide_banner \
        -loglevel info \
        -reconnect 1 \
        -reconnect_streamed 1 \
        -reconnect_delay_max 5 \
        -re \
        -i "$url" \
        -loop 1 -i overlay.png \
        -filter_complex "$FILTER" \
        -map "[final]" \
        -map 0:a? \
        -r 30 \
        -s 1280x720 \
        -c:v libx264 \
        -preset ultrafast \
        -tune zerolatency \
        -threads 2 \
        -profile:v high \
        -level 4.1 \
        -pix_fmt yuv420p \
        -b:v 3000k \
        -maxrate 3000k \
        -bufsize 6000k \
        -g 60 \
        -keyint_min 60 \
        -sc_threshold 0 \
        -c:a aac \
        -b:a 128k \
        -ar 48000 \
        -ac 2 \
        -shortest \
        -f flv \
        "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}"
        local exit_code=$?
        set -e

        if [ "$exit_code" -eq 0 ]; then
            echo "Video finished normally."
            return 0
        fi

        echo "WARNING: ffmpeg exited with code ${exit_code} (attempt ${attempt}/${MAX_RETRIES})."
        attempt=$((attempt + 1))
        if [ "$attempt" -le "$MAX_RETRIES" ]; then
            echo "Retrying in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
        else
            echo "ERROR: Max retries reached for this video. Moving on."
        fi
    done
    return 1
}

#############################################
# Parse VIDEO_URL
# - Separators: commas, newlines, or both
# - Duplicates are KEPT by default (a URL listed 3 times plays 3 times)
# - Set DEDUPE_URLS=true to collapse duplicates into unique URLs
# - Set SHUFFLE_URLS=false to play in exactly the order given
#############################################
DEDUPE_URLS="${DEDUPE_URLS:-false}"
SHUFFLE_URLS="${SHUFFLE_URLS:-true}"

URLS=()
while IFS= read -r u; do
    u="${u#"${u%%[![:space:]]*}"}"   # trim leading whitespace
    u="${u%"${u##*[![:space:]]}"}"   # trim trailing whitespace
    [ -n "$u" ] && URLS+=("$u")
done < <(printf '%s\n' "$VIDEO_URL" | tr '\r,' '\n\n')

TOTAL_LISTED=${#URLS[@]}

if [ "$DEDUPE_URLS" = true ] && [ "$TOTAL_LISTED" -gt 0 ]; then
    mapfile -t URLS < <(printf '%s\n' "${URLS[@]}" | awk '!seen[$0]++')
fi

NUM_URLS=${#URLS[@]}
if [ "$NUM_URLS" -eq 0 ]; then
    echo "ERROR: VIDEO_URL contained no valid entries after parsing"
    exit 1
fi
echo "Parsed $TOTAL_LISTED URL(s) from VIDEO_URL -> playing $NUM_URLS (dedupe=${DEDUPE_URLS})"

# Shuffle each run, but try to avoid the same URL playing back-to-back
# (only matters when duplicates are present).
if [ "$SHUFFLE_URLS" = true ] && [ "$NUM_URLS" -gt 1 ]; then
    for try_n in $(seq 1 50); do
        mapfile -t SHUFFLED < <(printf '%s\n' "${URLS[@]}" | shuf)
        clash=false
        for ((j = 1; j < NUM_URLS; j++)); do
            if [ "${SHUFFLED[$j]}" = "${SHUFFLED[$((j - 1))]}" ]; then
                clash=true
                break
            fi
        done
        [ "$clash" = false ] && break
    done
    URLS=("${SHUFFLED[@]}")
    echo "Shuffled playback order for this run:"
    for u in "${URLS[@]}"; do
        echo "  - $u"
    done
fi

#############################################
# Stream loop — plays through the whole list,
# forever.
#############################################
while true; do
    for ((i = 0; i < NUM_URLS; i++)); do
        url="${URLS[$i]}"

        run_video "$url"

        echo "Loading next video in 5 seconds..."
        echo ""
        sleep 5
    done
done
