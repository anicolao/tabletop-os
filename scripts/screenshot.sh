# Capture what the board is actually rendering, over SSH.
#
# This exists because an entire evening was lost to inferring the display state
# from `systemctl is-active`, process counts and DRM debugfs, all of which said
# "healthy" while the panel was black. The framebuffer contained a perfectly
# rendered launcher the whole time; the fault was downstream of the HDMI socket.
#
# One capture would have settled it in a minute. So: never reason about whether
# the kiosk is drawing. Look.
#
# A black image means the software is at fault. A correct image means the fault
# is the cable, the monitor's input selection, or the panel — none of which any
# amount of NixOS configuration will fix.
#
# TABLETOP_HOST and TABLETOP_GRIM are substituted by flake.nix.

host="${1:-$TABLETOP_HOST}"
out="${2:-tabletop-screen.png}"

echo "capturing from $host ..."

# grim needs the compositor's own environment. cage runs as `kiosk`, and its
# wayland socket lives in that user's runtime directory — which is mode 0700, so
# even listing it needs sudo. `|| true` because a failed lookup must reach the
# error message below rather than being killed by `set -e` with nothing printed.
# shellcheck disable=SC2016  # deliberate: this expands on the *remote* shell
remote='
  set -e
  sock=$(sudo ls /run/user/1001/ 2>/dev/null | grep -m1 "^wayland-[0-9]*$" || true)
  if [ -z "$sock" ]; then echo "no wayland socket: is cage running?" >&2; exit 1; fi
  # Prefer a grim from the system closure; fall back to fetching one. The
  # fallback needs both a network and the nix daemon, neither of which is a safe
  # assumption on a board whose display is already suspect.
  if command -v grim >/dev/null 2>&1; then
    grimcmd="grim"
  else
    grimcmd="nix --extra-experimental-features \"nix-command flakes\" run nixpkgs#grim --"
  fi
  sudo -u kiosk XDG_RUNTIME_DIR=/run/user/1001 WAYLAND_DISPLAY="$sock" \
    sh -c "$grimcmd /tmp/tabletop-screen.png" >/dev/null 2>&1
  echo ok
'

if ! ssh -o ConnectTimeout=10 "$host" "$remote" >/dev/null; then
  echo "capture failed on the board" >&2
  exit 1
fi

scp -q "$host:/tmp/tabletop-screen.png" "$out"
echo "wrote $out"

# A uniform image is almost certainly a blank screen. Worth saying out loud,
# because "I took a screenshot" and "the screenshot has content" are different
# claims and only the second one is useful.
if command -v identify >/dev/null 2>&1; then
  sd=$(identify -format '%[standard-deviation]' "$out" 2>/dev/null || echo "")
  case "$sd" in
    "") ;;
    *) awk -v s="$sd" 'BEGIN { if (s+0 < 100) print "WARNING: image is nearly uniform — the compositor may be drawing nothing"; else print "image has content (stddev " int(s) ")" }' ;;
  esac
fi
