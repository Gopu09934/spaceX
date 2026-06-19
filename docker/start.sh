#!/bin/bash

set -euo pipefail

mkdir -p /app/videos

if [ -z "${VIDEO_URLS:-}" ]; then
    echo "ERROR: VIDEO_URLS secret is empty."
    exit 1
fi

mapfile -t URLS <<< "$VIDEO_URLS"

TOTAL=${#URLS[@]}

if [ "$TOTAL" -eq 0 ]; then
    echo "No URLs found."
    exit 1
fi

echo "Found $TOTAL videos."

download_video() {

    local url="$1"
    local outfile="$2"

    echo ""
    echo "========================================"
    echo "Downloading:"
    echo "$url"

    for attempt in 1 2 3
    do

        if curl \
            -L \
            --fail \
            --retry 5 \
            --retry-delay 5 \
            -o "$outfile" \
            "$url"
        then

            if ffprobe -v error "$outfile" >/dev/null
            then
                echo "Download OK."
                return 0
            fi

        fi

        echo "Download failed. Retry $attempt/3"
        sleep 5

    done

    echo "Giving up."

    return 1
}

current=0

while ! download_video "${URLS[$current]}" "/app/videos/current.mp4"
do
    current=$(( (current + 1) % TOTAL ))
done

while true
do

    next=$(( (current + 1) % TOTAL ))

    (
        download_video "${URLS[$next]}" "/app/videos/next.mp4"
    ) &

    DOWNLOAD_PID=$!

    echo ""
    echo "========================================"
    echo "Streaming:"
    echo "${URLS[$current]}"

    ffmpeg \
        -hide_banner \
        -loglevel info \
        -re \
        -i /app/videos/current.mp4 \
        -c:v libx264 \
        -preset ultrafast \
        -pix_fmt yuv420p \
        -c:a aac \
        -b:a 128k \
        -f flv \
        "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}"

    if wait "$DOWNLOAD_PID"
    then

        rm -f /app/videos/current.mp4
        mv /app/videos/next.mp4 /app/videos/current.mp4
        current=$next

    else

        echo ""
        echo "Background download failed."

        found=0

        for ((i=1;i<TOTAL;i++))
        do

            idx=$(( (current + i) % TOTAL ))

            if download_video "${URLS[$idx]}" "/app/videos/current.mp4"
            then
                current=$idx
                found=1
                break
            fi

        done

        if [ "$found" -eq 0 ]
        then

            echo "No downloadable videos."

            echo "Sleeping 60 seconds..."

            sleep 60

        fi

    fi

done
