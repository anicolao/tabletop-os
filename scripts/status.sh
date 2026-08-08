# Emit the tabletop's current state as plain text.
#
# Single source of truth for two consumers: the console notice shown while the
# kiosk restarts, and the HTML status tab inside the browser. A tabletop has no
# keyboard and often no monitor beyond the panel itself, so "what is my IP" has
# to be answerable from the panel.

hostname_now="$(hostname 2>/dev/null || echo unknown)"

printf 'host      %s\n' "$hostname_now"

# Global-scope addresses only: link-local and loopback are noise here.
v4="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2": "$4}')"
v6="$(ip -6 -o addr show scope global 2>/dev/null | awk '{print $2": "$4}')"

if [ -n "$v4" ] || [ -n "$v6" ]; then
  printf '%s\n' "$v4" "$v6" | grep -v '^$' | while read -r line; do
    printf 'address   %s\n' "$line"
  done
else
  printf 'address   (no network)\n'
fi

gw="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
printf 'gateway   %s\n' "${gw:-none}"

printf 'kernel    %s\n' "$(uname -r)"
printf 'uptime    %s\n' "$(uptime | sed 's/.*up //; s/,  *[0-9]* user.*//')"

# Which DRM devices exist, and did the GPU driver actually bind? On the board
# this is the difference between hardware acceleration and llvmpipe.
drivers=""
for d in /sys/class/drm/card*/device/driver; do
  [ -e "$d" ] || continue
  drivers="$drivers$(basename "$(readlink -f "$d")") "
done
printf 'drm       %s\n' "$(printf '%s' "${drivers:-none}" | sed 's/ *$//')"

# `systemctl is-active` prints the state *and* exits non-zero for anything but
# "active", so `|| echo unknown` would print two lines. Capture, then default.
kiosk_state="$(systemctl is-active cage-tty1 2>/dev/null || true)"
printf 'kiosk     %s\n' "${kiosk_state:-unknown}"
printf 'launcher  %s\n' "${TABLETOP_KIOSK_URL:-unset}"
