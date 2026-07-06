#!/bin/bash
# Visual verification loop: run a scene's self-driving demo and capture frames.
#   Scripts/viz_check.sh <SceneName> [white|gray|black] [demo-seconds]
# Frames land in shots/viz_<scene>[_<bg>]_<n>.png — LOOK at them before claiming
# anything about how an effect renders.
set -euo pipefail
SCENE="${1:?usage: viz_check.sh <SceneName> [white|gray|black] [secs]}"
# PRIVACY: the overlay is transparent — capturing without a test background
# screenshots the user's REAL desktop (mail, code, credentials). Default to black
# and never allow an empty background.
BG="${2:-black}"
SECS="${3:-12}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="viz_$(echo "$SCENE" | tr '[:upper:] ' '[:lower:]_')${BG:+_$BG}"
LOG=/tmp/kp_viz.log

pkill -f ".build/debug/kiddyproof" 2>/dev/null || true
sleep 0.5
env KP_SCENE="$SCENE" KP_DEMO="$SECS" ${BG:+KP_TESTBG=$BG} \
    "$ROOT/.build/debug/kiddyproof" > "$LOG" 2>&1 &
APP=$!

# Wait for arm (adaptive contrast can make it async).
for i in $(seq 1 40); do
  grep -q "KID MODE ARMED" "$LOG" && break
  sleep 0.25
done
if ! grep -q "KID MODE ARMED" "$LOG"; then
  echo "FAILED to arm:"; tail -5 "$LOG"; kill $APP 2>/dev/null; exit 1
fi

# Capture frames across the session (demo input is driving the scene).
mkdir -p "$ROOT/shots"
for n in 1 2 3 4; do
  sleep $(( SECS / 5 ))
  screencapture -x "$ROOT/shots/${TAG}_${n}.png"
done
wait $APP 2>/dev/null || true
echo "captured:"
ls -la "$ROOT/shots/${TAG}"_*.png
