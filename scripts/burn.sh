# Write the tabletop-os SD image to a card.
#
# This is the one destructive thing in the repo, so it is deliberately
# suspicious: it refuses anything that is not a removable whole disk, refuses
# the disk the running system booted from, and requires the target to be typed
# again at the prompt. `dd` to the wrong device destroys it silently and
# instantly, and the usual cause is a device name that was correct yesterday.
#
# TABLETOP_IMAGE_DIR is substituted by flake.nix.

usage() {
  cat <<'EOF'
Write the tabletop-os SD image to a card.

Usage:
  nix run .#burn -- --sd /dev/rdisk4
  nix run .#burn -- --list

Options:
  --sd, -sd, -d DEVICE   whole-disk device to write to
  --list, -l             list plausible removable disks and exit
  --yes                  skip the confirmation prompt (still refuses unsafe
                         targets; intended for scripts, not for convenience)
  -h, --help             this message

The image is built first if it is not already in the store.

On macOS prefer /dev/rdiskN over /dev/diskN — the raw device is several times
faster. This script will suggest it if you pass the buffered one.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

os="$(uname -s)"
device=""
assume_yes=0

img="$(echo "$TABLETOP_IMAGE_DIR"/sd-image/*.img)"
[ -f "$img" ] || die "no image found under $TABLETOP_IMAGE_DIR/sd-image/"
img_bytes="$(wc -c <"$img" | tr -d ' ')"

list_disks() {
  case "$os" in
    Darwin)
      # NOT `diskutil list external physical`. A Mac's built-in SD slot reports
      # Internal=Yes, so the card you actually want is excluded by that filter —
      # it prints nothing while the card sits there writable. Enumerate whole
      # disks instead and keep anything ejectable or holding removable media,
      # minus the disk we booted from.
      echo "Removable whole disks:"
      boot_id="$(diskutil info -plist / 2>/dev/null | plutil -extract ParentWholeDisk raw -o - - 2>/dev/null || echo '')"
      found=0
      ids="$(diskutil list -plist physical 2>/dev/null |
        plutil -extract WholeDisks json -o - - 2>/dev/null |
        tr -d '[]"' | tr ',' '\n')"
      for id in $ids; do
        [ -n "$id" ] || continue
        [ "$id" = "$boot_id" ] && continue
        info="$(diskutil info -plist "/dev/$id" 2>/dev/null)" || continue
        get() { printf '%s' "$info" | plutil -extract "$1" raw -o - - 2>/dev/null || echo "$2"; }
        [ "$(get Ejectable false)" = "true" ] || [ "$(get RemovableMedia false)" = "true" ] || continue
        printf '  /dev/r%-7s %s, %s\n' "$id" "$(get MediaName '?')" \
          "$(get TotalSize 0 | awk '{printf "%.1f GB", $1/1000000000}')"
        found=1
      done
      [ "$found" = "1" ] || echo "  (none found — is a card inserted?)"
      ;;
    Linux)
      echo "Removable whole disks:"
      lsblk -ndo NAME,SIZE,RM,TYPE,MODEL | awk '$3 == 1 && $4 == "disk"' || true
      ;;
    *) die "unsupported platform: $os" ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --sd | -sd | -d | --device)
      [ $# -ge 2 ] || die "$1 needs a device argument"
      device="$2"
      shift 2
      ;;
    --list | -l)
      list_disks
      exit 0
      ;;
    --yes) assume_yes=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument '$1' (try --help)" ;;
  esac
done

if [ -z "$device" ]; then
  usage
  echo
  list_disks
  exit 2
fi

# ---------------------------------------------------------------- validation

case "$os" in
  Darwin) whole_disk_re='^/dev/r?disk[0-9]+$' ;;
  Linux) whole_disk_re='^/dev/(sd[a-z]+|mmcblk[0-9]+|nvme[0-9]+n[0-9]+)$' ;;
  *) die "unsupported platform: $os" ;;
esac

if ! printf '%s' "$device" | grep -Eq "$whole_disk_re"; then
  echo "error: '$device' is not a whole-disk device path." >&2
  case "$os" in
    Darwin)
      echo "Expected something like /dev/rdisk4 — not a partition (/dev/disk4s1)," >&2
      echo "and not a typo. Available:" >&2
      ;;
    Linux)
      echo "Expected something like /dev/sdb or /dev/mmcblk0 — not a partition." >&2
      ;;
  esac
  echo >&2
  list_disks >&2
  exit 2
fi

[ -e "$device" ] || {
  echo "error: '$device' does not exist." >&2
  echo >&2
  list_disks >&2
  exit 1
}

if [ "$os" = "Darwin" ]; then
  # /dev/diskN works but is buffered and much slower; nudge toward the raw node.
  raw="$device"
  case "$device" in
    /dev/disk*) raw="/dev/r${device#/dev/}" ;;
  esac

  plist="$(diskutil info -plist "$device" 2>/dev/null)" || die "diskutil cannot read $device"
  extract() { printf '%s' "$plist" | plutil -extract "$1" raw -o - - 2>/dev/null || echo "$2"; }

  ident="$(extract DeviceIdentifier "?")"
  internal="$(extract Internal true)"
  ejectable="$(extract Ejectable false)"
  removable="$(extract RemovableMedia false)"
  total="$(extract TotalSize 0)"
  media="$(extract MediaName "unknown")"
  protocol="$(extract BusProtocol "unknown")"

  boot_disk="$(diskutil info -plist / 2>/dev/null | plutil -extract ParentWholeDisk raw -o - - 2>/dev/null || echo "")"
  if [ -n "$boot_disk" ] && [ "$ident" = "$boot_disk" ]; then
    die "$device is the disk this Mac booted from. Refusing."
  fi

  if [ "$internal" = "true" ] && [ "$ejectable" != "true" ] && [ "$removable" != "true" ]; then
    die "$device is an internal, non-ejectable disk ($media). Refusing.
If this really is your card reader, eject and re-seat the card, or use --list
to find the right device."
  fi

  size_bytes="$total"
  describe="$media (${protocol}), $(printf '%s' "$total" | awk '{printf "%.1f GB", $1/1000000000}')"
else
  base="$(basename "$device")"
  rm_flag="$(lsblk -ndo RM "$device" 2>/dev/null | tr -d ' ')" || die "lsblk cannot read $device"
  type_flag="$(lsblk -ndo TYPE "$device" 2>/dev/null | tr -d ' ')"
  size_bytes="$(lsblk -ndbo SIZE "$device" 2>/dev/null | tr -d ' ')"
  model="$(lsblk -ndo MODEL "$device" 2>/dev/null | sed 's/  *$//')"

  [ "$type_flag" = "disk" ] || die "$device is not a whole disk (type=$type_flag)"

  root_src="$(findmnt -no SOURCE / 2>/dev/null || echo "")"
  if [ -n "$root_src" ]; then
    root_disk="$(lsblk -ndo PKNAME "$root_src" 2>/dev/null || echo "")"
    [ "$root_disk" = "$base" ] && die "$device holds the running root filesystem. Refusing."
  fi

  [ "$rm_flag" = "1" ] || die "$device is not removable. Refusing.
Use --list to see removable disks."

  raw="$device"
  describe="${model:-unknown} , $(printf '%s' "$size_bytes" | awk '{printf "%.1f GB", $1/1000000000}')"
fi

if [ "$size_bytes" -gt 0 ] && [ "$size_bytes" -lt "$img_bytes" ]; then
  die "$device is smaller than the image ($size_bytes < $img_bytes bytes)."
fi

# 512 GB is far larger than any plausible SD card, and a strong hint that this
# is an external SSD holding something valuable.
if [ "$size_bytes" -gt 512000000000 ]; then
  echo "warning: $device is $(printf '%s' "$size_bytes" | awk '{printf "%.0f GB", $1/1000000000}')," >&2
  echo "         which is very large for an SD card. Check this is right." >&2
fi

# ------------------------------------------------------------------- confirm

cat <<EOF

  image   $img
          $(printf '%s' "$img_bytes" | awk '{printf "%.1f GB", $1/1000000000}')
  target  $raw
          $describe

This ERASES everything on $raw.
EOF

if [ "$assume_yes" -ne 1 ]; then
  printf '\nType the device path again to confirm: '
  read -r confirm
  if [ "$confirm" != "$raw" ] && [ "$confirm" != "$device" ]; then
    die "got '$confirm', expected '$raw'. Nothing written."
  fi
fi

# ---------------------------------------------------------------------- write

echo
case "$os" in
  Darwin)
    echo "Unmounting $device ..."
    diskutil unmountDisk "$device" || die "could not unmount $device"
    ;;
  Linux)
    for part in "$device"?*; do
      [ -b "$part" ] && umount "$part" 2>/dev/null || true
    done
    ;;
esac

echo "Writing (this needs sudo, and takes a few minutes) ..."
if [ "$os" = "Darwin" ]; then
  sudo dd if="$img" of="$raw" bs=4m status=progress
else
  sudo dd if="$img" of="$raw" bs=4M status=progress conv=fsync
fi

echo "Flushing ..."
sync

case "$os" in
  Darwin) diskutil eject "$device" >/dev/null 2>&1 && echo "Ejected $device." || true ;;
  Linux) echo "Done. Safe to remove $device." ;;
esac

echo
echo "The rootfs expands on first boot, so expect an extra reboot."
echo "Then: ssh admin@tabletop   (see docs/FLASHING.md)"
