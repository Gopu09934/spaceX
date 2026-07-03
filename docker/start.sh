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
echo "Starting 24/7 YouTube Stream"
echo "Output Resolution : 1920x1080"
echo "FPS               : 30"
echo "========================================"

# Multiple video URLs separated by commas
IFS=',' read -ra URLS <<< "$VIDEO_URL"

while true; do
    for url in "${URLS[@]}"; do

        echo "----------------------------------------"
        echo "Streaming:"
        echo "$url"
        echo "----------------------------------------"

        ffmpeg \
        -hide_banner \
        -loglevel info \
        -re \
        -i "$url" \
        -loop 1 -i overlay.png \
        -filter_complex "\
        [0:v]scale=1920:1080:force_original_aspect_ratio=decrease,\
        pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black[video];\
        [1:v]scale=1920:1080:flags=lanczos[overlay];\
        [video][overlay]overlay=0:0,\
        drawtext=fontfile=font.ttf:text='LIVE':\
        fontcolor=red:fontsize=34:x=40:y=35,\
        drawtext=fontfile=font.ttf:\
        text='Credits\: NASA / SpaceX':\
        fontcolor=white:fontsize=24:\
        x=w-text_w-30:y=25" \
        -r 30 \
        -s 1920x1080 \
        -c:v libx264 \
        -preset veryfast \
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

        echo ""
        echo "Video Finished."
        echo "Loading next video in 5 seconds..."
        echo ""

        sleep 5

    done
done
