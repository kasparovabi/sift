#!/bin/bash
# Records one clip per theme, each showing a different part of the app, then the
# clips are stitched into the README hero. Themes are switched by relaunching, so
# nothing but the app is ever on camera.
#
# No AppleScript anywhere: window geometry comes from CGWindowList, which needs no
# Automation permission, and clicks go through cliclick.
set -u

SCR="/private/tmp/claude-501/-Volumes-YEDEK-AHMET-Antigravity-kasa/1c637fb7-7627-4699-b714-3063a6f7b0f5/scratchpad"
DEMO="$SCR/sift-demo"
OUT="$SCR/tour"
APP=/Applications/Sift.app/Contents/MacOS/Sift
mkdir -p "$OUT"

launch() {
  pkill -x Sift 2>/dev/null; sleep 1.5
  defaults write io.github.kasparovabi.sift sift.themeID -string "$1"
  SIFT_PROJECTS_ROOT="$DEMO/projects" SIFT_SUPPORT_DIR="$DEMO/support" "$APP" >/dev/null 2>&1 &
  sleep 11
  read -r WX WY WW WH < <("$SCR/bounds" Sift)
  [ -z "${WW:-}" ] && { echo "no window"; exit 1; }
}

at() {  # at <xFraction> <yFraction> -> "x,y" in screen points
  python3 -c "print(f'{int($WX + $1 * $WW)},{int($WY + $2 * $WH)}')"
}

record() {  # record <seconds> <file>
  ffmpeg -y -hide_banner -loglevel error -f avfoundation -pixel_format bgr0 -capture_cursor 0 \
    -framerate 30 -i "1" -t "$1" \
    -vf "crop=$((WW*2)):$((WH*2)):$((WX*2)):$((WY*2))" \
    -c:v libx264 -crf 18 -pix_fmt yuv420p "$2"
}

launch terminal
record 3 "$OUT/1.mp4"; echo "1 terminal · library"

launch graphite
cliclick "c:$(at 0.345 0.092)"; sleep 1
( sleep 0.8; cliclick -w 95 t:"pagination" ) &
record 4 "$OUT/2.mp4"; echo "2 graphite · search"

launch ocean
cliclick "c:$(at 0.069 0.899)"; sleep 3
cliclick "c:$(at 0.777 0.089)"; sleep 6
record 4 "$OUT/3.mp4"; echo "3 ocean · knowledge graph"

launch paper
cliclick "c:$(at 0.33 0.20)"; sleep 2
record 3 "$OUT/4.mp4"; echo "4 paper · session"

pkill -x Sift
