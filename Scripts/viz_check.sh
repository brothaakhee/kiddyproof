#!/bin/bash
# Visual verification loop: run a scene's self-driving demo and capture frames.
#   Scripts/viz_check.sh <SceneName> [white|gray|black] [demo-seconds]
# Frames land in shots/viz_<scene>[_<bg>]_<n>.png — LOOK at them before claiming
# anything about how an effect renders.
#
# KP_CONFIG=release uses .build/release instead. Required for Bloom: its tissue
# solver is a few thousand float operations per cell per frame, and an unoptimised
# build turns a 60fps scene into a slideshow — what you would be looking at then
# is the build configuration, not the effect.
set -euo pipefail
SCENE="${1:?usage: viz_check.sh <SceneName> [white|gray|black] [secs]}"
# PRIVACY: the overlay is transparent — capturing without a test background
# screenshots the user's REAL desktop (mail, code, credentials). Default to black
# and never allow an empty background.
BG="${2:-black}"
SECS="${3:-12}"
# PRIVACY, load-bearing: AppController caps the demo at min(secs+3, 15) seconds and
# then tears the overlay down. Asking for captures past that point screenshots the
# parent's REAL desktop with no overlay in front of it — which is exactly what it
# did once. The last frame lands at SECS/5*4, so SECS must leave room for it.
if [ "$SECS" -gt 11 ]; then
  echo "clamping $SECS -> 11s: the app's own demo cap would end the session mid-capture"
  SECS=11
fi
CONFIG="${KP_CONFIG:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/$CONFIG/kiddyproof"
TAG="viz_$(echo "$SCENE" | tr '[:upper:] ' '[:lower:]_')${BG:+_$BG}"
LOG=/tmp/kp_viz.log

if [ ! -x "$BIN" ]; then
  echo "no binary at $BIN — run: swift build${CONFIG:+ -c $CONFIG}"; exit 1
fi

pkill -f ".build/.*/kiddyproof" 2>/dev/null || true
sleep 0.5
# KP_CANAL_SPECIES pins Bloom to one species for review; harmless for other scenes.
env KP_SCENE="$SCENE" KP_DEMO="$SECS" ${BG:+KP_TESTBG=$BG} \
    ${KP_CANAL_SPECIES:+KP_CANAL_SPECIES="$KP_CANAL_SPECIES"} \
    ${KP_CANAL_PRESTEP:+KP_CANAL_PRESTEP="$KP_CANAL_PRESTEP"} \
    "$BIN" > "$LOG" 2>&1 &
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
