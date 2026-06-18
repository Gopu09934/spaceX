#!/bin/bash

set -euo pipefail

mkdir -p /app/videos

# Use VIDEO_URL from environment
if [ -z "${VIDEO_URL:-}" ]; then
    echo "ERROR: VIDEO_URL is not set."
    exit 1
fi

echo "Downloading video..."
echo "$VIDEO_URL"

curl -L --fail --retry 3 --retry-delay 5 \
    -o /app/videos/video.mp4 \
    "$VIDEO_URL"

echo "Verifying video..."

ffprobe -v error /app/videos/video.mp4

echo "Starting stream..."

exec ffmpeg \
    -re \
    -stream_loop -1 \
    -i /app/videos/video.mp4 \
    -c:v libx264 \
    -preset ultrafast \
    -c:a aac \
    -f flv \
    "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}"
