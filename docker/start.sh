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

# AUDIO_URL is optional. When set, it's a background music track (or a
# playlist of mp3 urls) that plays under the video.
#   MUTE_VIDEO_AUDIO=false (default) -> video's own audio is mixed with
#                                        the background track (falls
#                                        back to background-only if the
#                                        video has no audio track)
#   MUTE_VIDEO_AUDIO=true            -> video's own audio is silenced;
#                                        only the background track plays
MUTE_VIDEO_AUDIO="${MUTE_VIDEO_AUDIO:-false}"

echo "========================================"
echo "Starting 24/7 YouTube Stream (simple overlay)"
echo "Output Resolution : 1280x720 (720p — sized for a 2-core CI runner)"
echo "FPS               : 30"
echo "Mute video audio  : ${MUTE_VIDEO_AUDIO}"
echo "========================================"

#############################################
# Simple filter: scale/pad video to 1280x720,
# scale overlay.png to match, composite it on top.
#
# overlay=...:shortest=1 — overlay.png loops
# forever (-loop 1), so without this the filter
# graph never reaches EOF when the real (shorter)
# video ends: it just repeats the video's last
# frozen frame, -re has nothing left to pace
# against (so encoding races ahead uncapped), and
# -shortest never gets to trigger. shortest=1 ends
# the filter as soon as the video input ends.
#
# (aloop / amix stages are appended per-video in
# run_video() when background audio is present.)
#############################################
BASE_FILTER="[0:v]scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:black[video];"
BASE_FILTER+="[1:v]scale=1280:720:flags=fast_bilinear[ovl];"
BASE_FILTER+="[video][ovl]overlay=0:0:shortest=1[final]"

#############################################
# Auto-restart on failure
#############################################
MAX_RETRIES=5       # per-video retry attempts before moving on
RETRY_DELAY=5        # seconds between retries

#############################################
# Parse AUDIO_URL into a playlist (same
# comma/newline parsing as VIDEO_URL below).
# Optional — if unset, no background track is
# added and video audio passes through as-is
# (unless MUTE_VIDEO_AUDIO=true, which silences
# it and outputs silence instead).
#############################################
AUDIO_URLS=()
if [ -n "${AUDIO_URL:-}" ]; then
    while IFS= read -r a; do
        a="${a#"${a%%[![:space:]]*}"}"
        a="${a%"${a##*[![:space:]]}"}"
        [ -n "$a" ] && AUDIO_URLS+=("$a")
    done < <(printf '%s\n' "$AUDIO_URL" | tr '\r,' '\n\n')
fi
AUDIO_NUM=${#AUDIO_URLS[@]}
if [ "$AUDIO_NUM" -gt 0 ]; then
    echo "Loaded $AUDIO_NUM background audio track(s) from AUDIO_URL."
fi
AUDIO_IDX=0   # round-robins through AUDIO_URLS, one track per video, wrapping around (looping the playlist)

#############################################
# Returns success (0) if the given video URL
# has at least one audio stream. Used to decide
# whether an amix stage is even possible — some
# source clips are video-only, and [0:a] simply
# doesn't exist for those, which used to make
# ffmpeg fail outright ("matches no streams").
# On probe failure (network hiccup, odd
# container, etc.) we conservatively assume no
# audio, since that fails safe (background-only
# playback) rather than crashing the stream.
#############################################
video_has_audio() {
    local url="$1"
    local codec
    codec=$(ffprobe -v error -select_streams a -show_entries stream=codec_type -of csv=p=0 "$url" 2>/dev/null || true)
    [ -n "$codec" ]
}

#############################################
# Stream one video with automatic retry on
# failure/crash (e.g. Bus error, network drop),
# instead of letting set -e kill the script.
#############################################
run_video() {
    local url="$1"
    local attempt=1

    #########################################
    # Pick this video's background audio track
    # (if any) and build the extra ffmpeg input
    # / map / filter args for it. Input index 2
    # is always the audio input, whenever one is
    # present (either a real track or a
    # synthesized silent one for the mute-with-
    # no-AUDIO_URL case).
    #
    # Audio looping is done with the aloop
    # *filter* (on the decoded stream), not
    # -stream_loop on the input, since -stream_loop
    # combined with -re on the video input broke
    # real-time pacing.
    #########################################
    local filter="$BASE_FILTER"
    local audio_input_args=()
    local audio_map_args=()

    if [ "$AUDIO_NUM" -gt 0 ]; then
        local audio_url="${AUDIO_URLS[$((AUDIO_IDX % AUDIO_NUM))]}"
        AUDIO_IDX=$((AUDIO_IDX + 1))
        echo "Background audio: $audio_url"
        audio_input_args=(-i "$audio_url")
        # size is a sample-count ceiling, not a target — with any real
        # mp3 (well under ~12 hours of samples at 48kHz) this just loops
        # the whole track indefinitely.
        filter+=";[2:a]aloop=loop=-1:size=2147483647[abg]"
        if [ "$MUTE_VIDEO_AUDIO" = true ]; then
            audio_map_args=(-map "[abg]")
        elif video_has_audio "$url"; then
            # Mix the video's own audio with the background track.
            filter+=";[0:a][abg]amix=inputs=2:duration=first:dropout_transition=2[aout]"
            audio_map_args=(-map "[aout]")
        else
            # Video has no audio track of its own — nothing to mix, so
            # just stream the background track by itself.
            echo "NOTICE: video has no audio track — using background audio alone."
            audio_map_args=(-map "[abg]")
        fi
    else
        if [ "$MUTE_VIDEO_AUDIO" = true ]; then
            # No AUDIO_URL given but muting was requested — output
            # silence instead of the video's own audio. anullsrc is
            # already an infinite generator, so no looping is needed.
            audio_input_args=(-f lavfi -i "anullsrc=r=48000:cl=stereo")
            audio_map_args=(-map 2:a)
        else
            audio_map_args=(-map 0:a?)
        fi
    fi

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
        "${audio_input_args[@]}" \
        -filter_complex "$filter" \
        -map "[final]" \
        "${audio_map_args[@]}" \
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
