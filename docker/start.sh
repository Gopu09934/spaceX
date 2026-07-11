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
echo "Starting 24/7 YouTube Stream (Documentary Overlay)"
echo "Output Resolution : 1920x1080"
echo "FPS               : 30"
echo "========================================"

FONT="font.ttf"
GOLD="0xE8A33D"
RED="0xE8453C"
ASSET_DIR="panel_assets"
INFO_FILE="galaxy_info.txt"
TICKER_SPEED=110  # pixels/second for the bottom ticker scroll

#############################################
# Up-next bumper (shown between videos)
#############################################
ENABLE_BUMPER=true
BUMPER_DURATION=5   # seconds
BUMPER_MESSAGES=(
    "Stay tuned for more cosmic wonders"
    "Another journey through deep space is coming up"
    "More discoveries from the edge of the universe"
    "The story of the cosmos continues"
)

#############################################
# Auto-restart on failure
#############################################
MAX_RETRIES=5       # per-video retry attempts before moving on
RETRY_DELAY=5        # seconds between retries

mkdir -p "$ASSET_DIR"

#############################################
# Background clock writer (avoids fragile
# drawtext %{gmtime} expansion syntax)
#############################################
date -u +'%H:%M:%S  UTC' > "$ASSET_DIR/clock.txt"
(
    while true; do
        date -u +'%H:%M:%S  UTC' > "$ASSET_DIR/clock.txt.tmp"
        mv -f "$ASSET_DIR/clock.txt.tmp" "$ASSET_DIR/clock.txt"
        sleep 1
    done
) &
CLOCK_PID=$!
trap 'kill "$CLOCK_PID" 2>/dev/null || true' EXIT

#############################################
# Load headlines from galaxy_info.txt
# (still used to build the bottom ticker text)
#############################################
RAW_LINES=()
if [ -f "$INFO_FILE" ]; then
    while IFS= read -r line; do
        [ -n "$(echo "$line" | tr -d '[:space:]')" ] && RAW_LINES+=("$line")
    done < "$INFO_FILE"
fi

if [ "${#RAW_LINES[@]}" -eq 0 ]; then
    echo "WARNING: $INFO_FILE not found or empty — using default headlines."
    RAW_LINES=(
    "Falcon 9 continues setting records with rapid rocket reusability."
    "Starship development moves toward fully reusable spaceflight."
    "SpaceX supports NASA missions to the International Space Station."
    "Launch operations continue from Kennedy Space Center and Starbase."
)
fi

N=${#RAW_LINES[@]}
echo "Loaded $N headline(s) from $INFO_FILE for ticker"

# Build one long ticker string for the bottom scroll bar
TICKER_STRING=""
for i in "${!RAW_LINES[@]}"; do
    TICKER_STRING+="${RAW_LINES[$i]}     •     "
done
printf '%s' "$TICKER_STRING" > "$ASSET_DIR/ticker.txt"

#############################################
# Build the filter_complex dynamically
#############################################

# --- base video + vignette + background art -------------------------------
CHAIN="[0:v]scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black,vignette=PI/5,eq=contrast=1.08:saturation=1.15:brightness=0.02[video];"
CHAIN+="[1:v]scale=1920:1080:flags=lanczos[ovl];"
CHAIN+="[ovl][video]overlay=0:0[base];"

# --- LIVE indicator: steady label + blinking dot ---------------------------
CHAIN+="[base]drawbox=x=40:y=42:w=16:h=16:color=${RED}:t=fill:enable='lt(mod(t\,1)\,0.6)'[p7];"
CHAIN+="[p7]drawtext=fontfile=${FONT}:text='LIVE':fontcolor=white:fontsize=44:x=66:y=28[p8];"

# --- credits + live UTC clock ----------------------------------------------
CHAIN+="[p8]drawtext=fontfile=${FONT}:text='Credits\: NASA':fontcolor=white@0.85:fontsize=30:x=w-text_w-30:y=20[p9];"
CHAIN+="[p9]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/clock.txt:reload=1:fontcolor=${GOLD}:fontsize=28:x=w-text_w-30:y=58[p10];"

prev="p10"

# --- periodic subscribe CTA (fades in every 4 min for 8s) -----------------
CTA_CYCLE=240   # total cycle length in seconds
CTA_SHOW=8      # how long the CTA stays visible per cycle
CTA_START=0
CTA_END=$CTA_SHOW
CTA_ALPHA="if(between(mod(t\,${CTA_CYCLE})\,${CTA_START}\,${CTA_END})\,if(lt(mod(t\,${CTA_CYCLE})-${CTA_START}\,0.6)\,(mod(t\,${CTA_CYCLE})-${CTA_START})/0.6\,if(gt(mod(t\,${CTA_CYCLE})-${CTA_START}\,${CTA_SHOW}-0.6)\,(${CTA_END}-mod(t\,${CTA_CYCLE}))/0.6\,1))\,0)"
CTA_ENABLE="between(mod(t\,${CTA_CYCLE})\,${CTA_START}\,${CTA_END})"
printf 'SUBSCRIBE for daily space discoveries' > "$ASSET_DIR/cta.txt"
CHAIN+="[${prev}]drawbox=x=1100:y=930:w=760:h=64:color=black@0.75:t=fill:enable='${CTA_ENABLE}'[cta1];"
CHAIN+="[cta1]drawbox=x=1100:y=930:w=6:h=64:color=${GOLD}:t=fill:enable='${CTA_ENABLE}'[cta2];"
CHAIN+="[cta2]drawbox=x=1132:y=954:w=16:h=16:color=${RED}:t=fill:enable='${CTA_ENABLE}'[cta3];"
CHAIN+="[cta3]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/cta.txt:fontcolor=white:fontsize=28:x=1160:y=950:alpha='${CTA_ALPHA}'[cta4];"
prev="cta4"

# --- bottom ticker bar -------------------------------------------------
CHAIN+="[${prev}]drawbox=x=0:y=1020:w=1920:h=60:color=black@0.72:t=fill[tk1];"
CHAIN+="[tk1]drawbox=x=0:y=1020:w=1920:h=3:color=${GOLD}@0.9:t=fill[tk2];"
CHAIN+="[tk2]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/ticker.txt:fontcolor=white:fontsize=26:borderw=2:bordercolor=black@0.6:y=1043:x='w-mod(t*${TICKER_SPEED}\,text_w+w)'[tk3];"
CHAIN+="[tk3]drawbox=x=0:y=1020:w=180:h=60:color=black@0.85:t=fill[tk4];"
CHAIN+="[tk4]drawbox=x=0:y=1023:w=170:h=57:color=${GOLD}:t=fill[tk5];"
CHAIN+="[tk5]drawtext=fontfile=${FONT}:text='BULLETIN':fontcolor=black:fontsize=24:x=25:y=1043[tk6];"

# --- outer frame border -------------------------------------------------
CHAIN+="[tk6]drawbox=x=0:y=0:w=1920:h=1080:color=black@0.5:t=2[final]"

FILTER="$CHAIN"

#############################################
# Up-next bumper: short branded title card
# streamed between videos to reduce drop-off
# at the loop/transition point.
#############################################
run_bumper() {
    local next_url="$1"

    # Try to derive a readable title from the filename; fall back to generic.
    local raw title
    raw="${next_url##*/}"
    raw="${raw%.*}"
    raw="${raw//[-_]/ }"
    raw="$(echo "$raw" | tr -d '[:space:]')"
    if [ -z "$raw" ] || [ ${#raw} -lt 3 ]; then
        title="A New Discovery"
    else
        raw="${next_url##*/}"
        raw="${raw%.*}"
        raw="${raw//[-_]/ }"
        title=$(echo "$raw" | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2); print}')
    fi

    local sub_idx=$((RANDOM % ${#BUMPER_MESSAGES[@]}))
    printf '%s' "$title" | fold -s -w 34 > "$ASSET_DIR/bumper_title.txt"
    printf '%s' "${BUMPER_MESSAGES[$sub_idx]}" > "$ASSET_DIR/bumper_sub.txt"

    echo ">>> Up next: $title"

    local fade_out_start
    fade_out_start=$(awk -v d="$BUMPER_DURATION" 'BEGIN{print d - 0.6}')

    local BFILTER
    BFILTER="[0:v]scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,eq=brightness=-0.08:saturation=0.85[bg];"
    BFILTER+="[bg]drawbox=x=0:y=0:w=1920:h=1080:color=black@0.55:t=fill[b1];"
    BFILTER+="[b1]drawbox=x=40:y=42:w=16:h=16:color=${RED}:t=fill:enable='lt(mod(t\,1)\,0.6)'[b2];"
    BFILTER+="[b2]drawtext=fontfile=${FONT}:text='LIVE':fontcolor=white:fontsize=44:x=66:y=28[b3];"
    BFILTER+="[b3]drawbox=x=0:y=470:w=1920:h=3:color=${GOLD}@0.8:t=fill[b4];"
    BFILTER+="[b4]drawtext=fontfile=${FONT}:text='UP NEXT':fontcolor=${GOLD}:fontsize=32:x=(w-text_w)/2:y=390[b5];"
    BFILTER+="[b5]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/bumper_title.txt:fontcolor=white:fontsize=54:line_spacing=10:x=(w-text_w)/2:y=520[b6];"
    BFILTER+="[b6]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/bumper_sub.txt:fontcolor=white@0.75:fontsize=26:x=(w-text_w)/2:y=640[b7];"
    BFILTER+="[b7]fade=t=in:st=0:d=0.5,fade=t=out:st=${fade_out_start}:d=0.6[final]"

    ffmpeg \
    -hide_banner \
    -loglevel warning \
    -loop 1 -t "$BUMPER_DURATION" -i overlay.png \
    -f lavfi -t "$BUMPER_DURATION" -i anullsrc=r=48000:cc=2 \
    -filter_complex "$BFILTER" \
    -map "[final]" \
    -map 1:a \
    -r 30 \
    -s 1920x1080 \
    -c:v libx264 \
    -preset ultrafast \
    -tune zerolatency \
    -profile:v high \
    -level 4.2 \
    -pix_fmt yuv420p \
    -b:v 6000k \
    -maxrate 6000k \
    -bufsize 12000k \
    -g 60 \
    -keyint_min 60 \
    -sc_threshold 0 \
    -c:a aac \
    -b:a 160k \
    -ar 48000 \
    -ac 2 \
    -f flv \
    "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}" || echo "WARNING: bumper failed, continuing to next video"
}

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
        -re \
        -i "$url" \
        -loop 1 -i overlay.png \
        -filter_complex "$FILTER" \
        -map "[final]" \
        -map 0:a? \
        -r 30 \
        -s 1920x1080 \
        -c:v libx264 \
        -preset ultrafast \
        -profile:v high \
        -level 4.2 \
        -pix_fmt yuv420p \
        -b:v 6000k \
        -maxrate 6000k \
        -bufsize 12000k \
        -g 60 \
        -keyint_min 60 \
        -sc_threshold 0 \
        -c:a aac \
        -b:a 160k \
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
# Stream loop
#############################################
IFS=',' read -ra URLS <<< "$VIDEO_URL"
NUM_URLS=${#URLS[@]}
while true; do
    for ((i = 0; i < NUM_URLS; i++)); do
        url="${URLS[$i]}"
        next_idx=$(( (i + 1) % NUM_URLS ))
        next_url="${URLS[$next_idx]}"

        run_video "$url"

        if [ "$ENABLE_BUMPER" = true ]; then
            run_bumper "$next_url"
        fi

        echo "Loading next video in 5 seconds..."
        echo ""
        sleep 5
    done
done
