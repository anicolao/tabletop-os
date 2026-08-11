# Photograph the physical tabletop with a webcam suspended above it.
#
# The companion to scripts/screenshot.sh, and the reason both exist:
#
#   screenshot  what the compositor drew   (the software's claim)
#   photo       what the panel emits       (the world's answer)
#
# Neither alone is sufficient. An evening was lost to a black panel that every
# software signal called healthy — and it was, the framebuffer held a perfectly
# rendered launcher. The fault was past the HDMI socket, which no amount of
# introspection on the board could ever have revealed. Together the two answer
# the question that actually matters:
#
#   screenshot good, photo good  ->  working; look elsewhere for the bug
#   screenshot good, photo black ->  cable, monitor input, or panel. Not us.
#   screenshot black             ->  ours. Start with cage and Chromium.
#
# Runs on the Mac, not the board: the camera is attached here, pointed there.
#
# TABLETOP_CAMERA is substituted by flake.nix.

out="${1:-tabletop-photo.jpg}"
pattern="${2:-$TABLETOP_CAMERA}"

# Resolve the device index at capture time rather than hardcoding it. Indices
# are positional and shift whenever a camera appears or disappears — an iPhone
# waking up on the same Apple ID is enough to renumber everything below it, and
# a wrong index yields a confident photograph of the wrong subject.
#
# Selecting by name has its own trap: this camera reports itself as
# "USB Camera VID:1133 PID:2083", and avfoundation's input syntax is
# "video:audio", so the colons make the name unusable as a device specifier.
# Hence: match by name, then pass the index.
devices=$(ffmpeg -f avfoundation -list_devices true -i "" 2>&1 || true)

# Video and audio devices are numbered in separate sequences under the same
# format, so stop at the audio header or risk matching a microphone.
#
# The trailing `|| true` is load-bearing. Under `set -o pipefail` a no-match
# from grep fails the whole pipeline, and `set -e` then kills the script *at
# the assignment* — before reaching the error message written to explain it.
# The first time this camera dropped off the bus, that produced a bare exit 1
# with no output at all. An unreachable error path is worse than none.
index=$(printf '%s\n' "$devices" \
  | awk '/AVFoundation audio devices/ { exit } { print }' \
  | grep -E '\[[0-9]+\]' \
  | grep -Ei "$pattern" \
  | head -1 \
  | sed -E 's/.*\[([0-9]+)\].*/\1/' || true)

if [ -z "$index" ]; then
  echo "no camera matching /$pattern/. Available:" >&2
  printf '%s\n' "$devices" \
    | awk '/AVFoundation audio devices/ { exit } /\[[0-9]+\]/ { print }' \
    | sed -E 's/.*(\[[0-9]+\])/  \1/' >&2
  exit 1
fi

name=$(printf '%s\n' "$devices" | grep -E "\[$index\]" | head -1 | sed -E "s/.*\[$index\] //")
echo "capturing from [$index] $name ..."

# Discard frames before keeping one. A webcam opens at whatever exposure it last
# used and takes a moment to adapt; the first frame of a bright panel in a dark
# room is routinely a white blob or a black one. `-update 1` keeps overwriting
# the same file, so what survives is the last and best-exposed frame.
if ! ffmpeg -y -f avfoundation -framerate 30 -i "$index" \
  -frames:v 20 -update 1 "$out" >/dev/null 2>&1; then
  echo "capture failed — if macOS has not been granted camera access, the" >&2
  echo "permission belongs to the terminal application, not to this script." >&2
  exit 1
fi

echo "wrote $out"

# Report brightness rather than judging it. A dark frame means the panel is off
# *or* the room is — this cannot tell which, and should not pretend to.
if command -v identify >/dev/null 2>&1; then
  mean=$(identify -format '%[fx:mean*100]' "$out" 2>/dev/null || echo "")
  case "$mean" in
    "") ;;
    *) awk -v m="$mean" 'BEGIN {
         printf "mean brightness %.1f%%", m
         if (m+0 < 3) printf "  — very dark: panel off, or an unlit room"
         print ""
       }' ;;
  esac
fi
