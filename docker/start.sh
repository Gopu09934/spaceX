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
echo "Output Resolution : 1280x720 (720p — sized for a 2-core CI runner)"
echo "FPS               : 30"
echo "========================================"

FONT="font.ttf"
GOLD="0xE8A33D"
RED="0xE8453C"
ASSET_DIR="panel_assets"
INFO_FILE="galaxy_info.txt"
SLOT=6            # seconds each headline is shown
FACT_SLOT=8       # seconds each fun fact is shown
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
# Static panel text
#############################################
printf 'J A M E S   W E B B'              > "$ASSET_DIR/title1.txt"
printf 'S P A C E   T E L E S C O P E'    > "$ASSET_DIR/title2.txt"
printf "T O D A Y ' S   D I S C O V E R Y" > "$ASSET_DIR/header.txt"
printf 'DEEP SPACE REPORT'                > "$ASSET_DIR/eyebrow.txt"

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
        "Webb reveals one of the oldest galaxies ever discovered."
        "Infrared observations uncover hidden star-forming regions."
        "The Cartwheel Galaxy was formed after a galactic collision."
        "Scientists continue studying the earliest galaxies in the Universe."
    )
fi

N=${#RAW_LINES[@]}
CYCLE=$((N * SLOT))
echo "Loaded $N headline(s) from $INFO_FILE — rotation cycle: ${CYCLE}s"

# Wrap each headline for the side panel.
# NOTE: widened from 20 -> 25 chars so long headlines fold into fewer
# lines (max ~3 instead of 4), which is what was pushing text down into
# the progress bar / dots. Panel text column is ~280px wide at fontsize 21,
# so 25 chars/line still fits comfortably without clipping.
for i in "${!RAW_LINES[@]}"; do
    idx=$((i + 1))
    echo "${RAW_LINES[$i]}" | fold -s -w 25 > "$ASSET_DIR/headline${idx}.txt"
done

# Build one long ticker string for the bottom scroll bar
TICKER_STRING=""
for i in "${!RAW_LINES[@]}"; do
    TICKER_STRING+="${RAW_LINES[$i]}     •     "
done
printf '%s' "$TICKER_STRING" > "$ASSET_DIR/ticker.txt"

#############################################
# Fun facts (fills empty space + adds motion)
# Optional file: facts.txt, one fact per line.
#############################################
FACTS=()
if [ -f "facts.txt" ]; then
    while IFS= read -r line; do
        [ -n "$(echo "$line" | tr -d '[:space:]')" ] && FACTS+=("$line")
    done < "facts.txt"
fi
if [ "${#FACTS[@]}" -eq 0 ]; then
    FACTS=(
        "Light from the Cartwheel Galaxy took 500 million years to reach us."
        "Webb sees infrared light invisible to the human eye."
        "A day on Venus is longer than its year."
        "There are more stars in the universe than grains of sand on Earth."
    )
fi
FACT_N=${#FACTS[@]}
FACT_CYCLE=$((FACT_N * FACT_SLOT))
for i in "${!FACTS[@]}"; do
    idx=$((i + 1))
    echo "${FACTS[$i]}" | fold -s -w 23 > "$ASSET_DIR/fact${idx}.txt"
done
printf 'DID YOU KNOW' > "$ASSET_DIR/fact_label.txt"

#############################################
# Build the filter_complex dynamically
#############################################

# --- base video + background art -------------------------------
# NOTE: vignette + eq removed — too expensive for a 2-core CI runner.
# NOTE: resolution dropped to 1280x720 — 1080p30 is not realtime-encodable
# on 2 vCPUs with this filter graph, regardless of preset.
CHAIN="[0:v]scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:black[video];"
CHAIN+="[1:v]scale=1280:720:flags=fast_bilinear[ovl];"
CHAIN+="[ovl][video]overlay=0:0[base];"

# --- left info panel with feathered (gradient-style) edge -----------------
# NOTE: scaled to 333px wide (was 500px at 1080p) to match the 1280x720 frame.
CHAIN+="[base]drawbox=x=0:y=0:w=333:h=720:color=black@0.60:t=fill[p1];"
CHAIN+="[p1]drawbox=x=333:y=0:w=4:h=720:color=black@0.45:t=fill[p2];"
CHAIN+="[p2]drawbox=x=337:y=0:w=4:h=720:color=black@0.30:t=fill[p3];"
CHAIN+="[p3]drawbox=x=341:y=0:w=4:h=720:color=black@0.15:t=fill[p4];"
CHAIN+="[p4]drawbox=x=0:y=0:w=347:h=4:color=${GOLD}@0.9:t=fill[p5];"
CHAIN+="[p5]drawbox=x=345:y=0:w=2:h=720:color=${GOLD}@0.6:t=fill[p6];"

# --- LIVE indicator: steady label + blinking dot ---------------------------
CHAIN+="[p6]drawbox=x=27:y=28:w=11:h=11:color=${RED}:t=fill:enable='lt(mod(t\,1)\,0.6)'[p7];"
CHAIN+="[p7]drawtext=fontfile=${FONT}:text='LIVE':fontcolor=white:fontsize=30:x=44:y=19[p8];"

# --- credits + live UTC clock ----------------------------------------------
CHAIN+="[p8]drawtext=fontfile=${FONT}:text='Credits\: NASA':fontcolor=white@0.85:fontsize=20:x=w-text_w-20:y=14[p9];"
CHAIN+="[p9]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/clock.txt:reload=1:fontcolor=${GOLD}:fontsize=19:x=w-text_w-20:y=39[p10];"

# --- titles ------------------------------------------------------------
CHAIN+="[p10]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title1.txt:fontcolor=white:fontsize=23:x=33:y=83[p11];"
CHAIN+="[p11]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title2.txt:fontcolor=white@0.85:fontsize=17:x=33:y=112[p12];"
CHAIN+="[p12]drawbox=x=33:y=143:w=280:h=2:color=white@0.3:t=fill[p13];"

# --- section header ----------------------------------------------------
CHAIN+="[p13]drawbox=x=33:y=159:w=8:h=8:color=${GOLD}:t=fill[p14];"
CHAIN+="[p14]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/header.txt:fontcolor=${GOLD}:fontsize=15:x=49:y=156[p15];"

# --- eyebrow category tag above the rotating headline -----------------
CHAIN+="[p15]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/eyebrow.txt:fontcolor=${GOLD}@0.85:fontsize=12:x=33:y=187[p16];"

prev="p16"
for i in "${!RAW_LINES[@]}"; do
    idx=$((i + 1))
    start=$((i * SLOT))
    end=$((start + SLOT))
    nxt="h${idx}"
    ALPHA="if(between(mod(t\,${CYCLE})\,${start}\,${end})\,if(lt(mod(t\,${CYCLE})-${start}\,0.6)\,(mod(t\,${CYCLE})-${start})/0.6\,if(gt(mod(t\,${CYCLE})-${start}\,${SLOT}-0.6)\,(${end}-mod(t\,${CYCLE}))/0.6\,1))\,0)"
    CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/headline${idx}.txt:fontcolor=white:fontsize=21:line_spacing=9:x=33:y=207:alpha='${ALPHA}'[${nxt}];"
    prev="$nxt"
done

# --- animated progress bar: fills across current headline's time slot -----
# NOTE: moved from y=313 -> y=328 to give a 3-line wrapped headline
# (fontsize 21, line_spacing 9 => ~90px tall block starting at y=207)
# enough clearance before this bar starts.
CHAIN+="[${prev}]drawbox=x=33:y=328:w=280:h=2:color=white@0.15:t=fill[pg1];"
CHAIN+="[pg1]drawbox=x=33:y=328:w='280*(mod(t\,${SLOT}))/${SLOT}':h=2:color=${GOLD}:t=fill[pg2];"
prev="pg2"

# --- background dots (dim) -------------------------------------------------
# NOTE: moved from y=333 -> y=348 (kept 15px below the progress bar).
for i in "${!RAW_LINES[@]}"; do
    idx=$((i + 1))
    x=$((33 + i * 17))
    nxt="db${idx}"
    CHAIN+="[${prev}]drawbox=x=${x}:y=348:w=7:h=7:color=white@0.3:t=fill[${nxt}];"
    prev="$nxt"
done

# --- active dot (gold, toggled per slot) -----------------------------------
last=$((N - 1))
for i in "${!RAW_LINES[@]}"; do
    idx=$((i + 1))
    x=$((33 + i * 17))
    start=$((i * SLOT))
    end=$((start + SLOT))
    ENABLE="between(mod(t\,${CYCLE})\,${start}\,${end})"
    if [ "$i" -eq "$last" ]; then
        CHAIN+="[${prev}]drawbox=x=${x}:y=348:w=7:h=7:color=${GOLD}:t=fill:enable='${ENABLE}'[pdotend];"
        prev="pdotend"
    else
        nxt="da${idx}"
        CHAIN+="[${prev}]drawbox=x=${x}:y=348:w=7:h=7:color=${GOLD}:t=fill:enable='${ENABLE}'[${nxt}];"
        prev="$nxt"
    fi
done

# --- rotating fun fact (fills empty space, adds periodic motion) ----------
# NOTE: whole fact block shifted down ~15px (373->388, 387->402, 407->422)
# to match the dots moving down.
CHAIN+="[${prev}]drawbox=x=33:y=388:w=280:h=2:color=${GOLD}@0.4:t=fill[fp1];"
CHAIN+="[fp1]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/fact_label.txt:fontcolor=${GOLD}@0.85:fontsize=12:x=33:y=402[fp2];"
prev="fp2"
for i in "${!FACTS[@]}"; do
    idx=$((i + 1))
    start=$((i * FACT_SLOT))
    end=$((start + FACT_SLOT))
    nxt="f${idx}"
    FALPHA="if(between(mod(t\,${FACT_CYCLE})\,${start}\,${end})\,if(lt(mod(t\,${FACT_CYCLE})-${start}\,0.6)\,(mod(t\,${FACT_CYCLE})-${start})/0.6\,if(gt(mod(t\,${FACT_CYCLE})-${start}\,${FACT_SLOT}-0.6)\,(${end}-mod(t\,${FACT_CYCLE}))/0.6\,1))\,0)"
    CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/fact${idx}.txt:fontcolor=white@0.9:fontsize=16:line_spacing=7:x=33:y=422:alpha='${FALPHA}'[${nxt}];"
    prev="$nxt"
done

prev="$prev"

# --- periodic subscribe CTA (fades in every 4 min for 8s) -----------------
CTA_CYCLE=240   # total cycle length in seconds
CTA_SHOW=8      # how long the CTA stays visible per cycle
CTA_START=0
CTA_END=$CTA_SHOW
CTA_ALPHA="if(between(mod(t\,${CTA_CYCLE})\,${CTA_START}\,${CTA_END})\,if(lt(mod(t\,${CTA_CYCLE})-${CTA_START}\,0.6)\,(mod(t\,${CTA_CYCLE})-${CTA_START})/0.6\,if(gt(mod(t\,${CTA_CYCLE})-${CTA_START}\,${CTA_SHOW}-0.6)\,(${CTA_END}-mod(t\,${CTA_CYCLE}))/0.6\,1))\,0)"
CTA_ENABLE="between(mod(t\,${CTA_CYCLE})\,${CTA_START}\,${CTA_END})"
printf 'SUBSCRIBE for daily space discoveries' > "$ASSET_DIR/cta.txt"
CHAIN+="[${prev}]drawbox=x=733:y=620:w=507:h=43:color=black@0.75:t=fill:enable='${CTA_ENABLE}'[cta1];"
CHAIN+="[cta1]drawbox=x=733:y=620:w=4:h=43:color=${GOLD}:t=fill:enable='${CTA_ENABLE}'[cta2];"
CHAIN+="[cta2]drawbox=x=755:y=636:w=11:h=11:color=${RED}:t=fill:enable='${CTA_ENABLE}'[cta3];"
CHAIN+="[cta3]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/cta.txt:fontcolor=white:fontsize=19:x=773:y=633:alpha='${CTA_ALPHA}'[cta4];"
prev="cta4"

# --- bottom ticker bar -------------------------------------------------
CHAIN+="[${prev}]drawbox=x=0:y=680:w=1280:h=40:color=black@0.72:t=fill[tk1];"
CHAIN+="[tk1]drawbox=x=0:y=680:w=1280:h=2:color=${GOLD}@0.9:t=fill[tk2];"
CHAIN+="[tk2]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/ticker.txt:fontcolor=white:fontsize=17:borderw=2:bordercolor=black@0.6:y=695:x='w-mod(t*${TICKER_SPEED}\,text_w+w)'[tk3];"
CHAIN+="[tk3]drawbox=x=0:y=680:w=120:h=40:color=black@0.85:t=fill[tk4];"
CHAIN+="[tk4]drawbox=x=0:y=682:w=113:h=38:color=${GOLD}:t=fill[tk5];"
CHAIN+="[tk5]drawtext=fontfile=${FONT}:text='BULLETIN':fontcolor=black:fontsize=16:x=17:y=695[tk6];"

# --- outer frame border -------------------------------------------------
CHAIN+="[tk6]drawbox=x=0:y=0:w=1280:h=720:color=black@0.5:t=2[final]"

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
    BFILTER="[0:v]scale=1280:720:force_original_aspect_ratio=increase,crop=1280:720[bg];"
    BFILTER+="[bg]drawbox=x=0:y=0:w=1280:h=720:color=black@0.55:t=fill[b1];"
    BFILTER+="[b1]drawbox=x=27:y=28:w=11:h=11:color=${RED}:t=fill:enable='lt(mod(t\,1)\,0.6)'[b2];"
    BFILTER+="[b2]drawtext=fontfile=${FONT}:text='LIVE':fontcolor=white:fontsize=30:x=44:y=19[b3];"
    BFILTER+="[b3]drawbox=x=0:y=313:w=1280:h=2:color=${GOLD}@0.8:t=fill[b4];"
    BFILTER+="[b4]drawtext=fontfile=${FONT}:text='UP NEXT':fontcolor=${GOLD}:fontsize=22:x=(w-text_w)/2:y=260[b5];"
    BFILTER+="[b5]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/bumper_title.txt:fontcolor=white:fontsize=36:line_spacing=8:x=(w-text_w)/2:y=347[b6];"
    BFILTER+="[b6]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/bumper_sub.txt:fontcolor=white@0.75:fontsize=18:x=(w-text_w)/2:y=427[b7];"
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
