#!/bin/bash
# Regenerate package/clips/: tiny synthetic test clips (ffmpeg's testsrc2
# pattern, 176x144, 10 frames) the install uses to check each decoder really
# decodes. They're committed, so builds don't need ffmpeg.
set -euo pipefail
OUT=$(cd "$(dirname "$0")/.." && pwd)/package/clips
mkdir -p "$OUT"
src=(-f lavfi -i testsrc2=size=176x144:rate=10 -frames:v 10 -an -map_metadata -1 -fflags +bitexact -y)

# Baseline profile: KitKat's software H.264 decoder only handles Baseline.
ffmpeg -loglevel error "${src[@]}" -c:v libx264 -profile:v baseline -level 1.3 -pix_fmt yuv420p \
    -x264-params keyint=10 -movflags +faststart "$OUT/avc.mp4"
ffmpeg -loglevel error "${src[@]}" -c:v mpeg4 -q:v 5 -g 10 "$OUT/mpeg4.mp4"
ffmpeg -loglevel error "${src[@]}" -c:v h263 -q:v 5 -g 10 "$OUT/h263.3gp"
ffmpeg -loglevel error "${src[@]}" -c:v libvpx -b:v 200k -g 10 "$OUT/vp8.webm"
ffmpeg -loglevel error "${src[@]}" -c:v libvpx-vp9 -b:v 200k -g 10 -row-mt 0 "$OUT/vp9.webm"
ls -l "$OUT"
