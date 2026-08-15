# Read WiFi credentials from the SD card's FAT partition and hand them to
# NetworkManager.
#
# Solves a bootstrap problem, not a secrecy problem. A portable tabletop needs
# WiFi to reach the network, and the credentials cannot live in a public
# repository or a world-readable nix store. Everything else about this device
# is provisioned over SSH — which needs the network this file provides.
#
# Deliberately NOT sops-nix, though the rest of these machines use it. sops
# needs a decryption key on the device, and getting that key onto a freshly
# flashed card has exactly the same chicken-and-egg problem: no network, no
# keys. The out-of-band step is unavoidable; this is the cheapest channel that
# already exists. Once a device is on the network, sops-nix is the right tool
# for every *subsequent* secret, and this file could carry an age key instead
# of a passphrase without changing the mechanism.
#
# TABLETOP_WIFI_FILE and TABLETOP_NM_DIR are substituted by flake.nix.

if [ ! -f "$TABLETOP_WIFI_FILE" ]; then
  echo "no $TABLETOP_WIFI_FILE — leaving networking to Ethernet/DHCP"
  exit 0
fi

# Values are parsed rather than sourced. This file is edited on whatever laptop
# is to hand, so it will arrive with CRLF line endings, stray quotes and
# surrounding spaces, and a passphrase is entirely capable of containing
# characters a shell would love to interpret.
# Order matters: strip CR, then trailing blanks, then surrounding quotes. Doing
# the quotes first would let `ssid = "My Net "` lose the space the quotes exist
# to protect; doing the trim last would leave `ssid = MyNet  ` with trailing
# spaces that match no network and produce a baffling failure.
get() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$TABLETOP_WIFI_FILE" \
    | tr -d '\r' \
    | sed -e 's/[[:space:]]*$//' \
    | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/" \
    | head -1
}

ssid="$(get ssid)"
psk="$(get psk)"
hidden="$(get hidden)"

if [ -z "$ssid" ]; then
  echo "error: $TABLETOP_WIFI_FILE has no 'ssid=' line; ignoring it" >&2
  exit 0
fi

# NetworkManager keyfiles are ini; a literal newline would end the value early
# and silently truncate the passphrase.
#
# The newline must come from a variable holding a literal one. Writing the
# pattern as *"$(printf '\n')"* looks equivalent and is not: command
# substitution strips trailing newlines, so it expands to the empty string, the
# pattern collapses to *""*, and that matches every string. The guard then
# refused every valid wifi.conf. It shipped that way and went unnoticed until
# the first board that actually used WiFi, because the Orange Pi has Ethernet
# and never runs this.
newline='
'
case "$ssid$psk" in
  *"$newline"*) echo "error: ssid/psk contain a newline; refusing" >&2; exit 1 ;;
esac

out="$TABLETOP_NM_DIR/tabletop-wifi.nmconnection"
mkdir -p "$TABLETOP_NM_DIR"

# Written with a restrictive umask *before* the content exists, so the
# passphrase is never briefly world-readable. NetworkManager refuses to load
# keyfiles that are group- or world-accessible, so this is also required.
umask 077

{
  printf '[connection]\n'
  printf 'id=tabletop-wifi\n'
  printf 'type=wifi\n'
  printf 'autoconnect=true\n'
  printf 'autoconnect-priority=10\n'
  printf '\n[wifi]\n'
  printf 'mode=infrastructure\n'
  printf 'ssid=%s\n' "$ssid"
  [ "$hidden" = "true" ] && printf 'hidden=true\n'
  if [ -n "$psk" ]; then
    printf '\n[wifi-security]\n'
    printf 'key-mgmt=wpa-psk\n'
    printf 'psk=%s\n' "$psk"
  fi
  printf '\n[ipv4]\nmethod=auto\n'
  printf '\n[ipv6]\nmethod=auto\n'
} > "$out.tmp"

chmod 600 "$out.tmp"
mv -f "$out.tmp" "$out"

echo "provisioned WiFi for SSID '$ssid'"
