# Install the NVMe system onto the board's SSD, from this machine.
#
# Destructive: it repartitions the target drive. Everything before the
# confirmation prompt is read-only, and the prompt requires the device path to
# be typed rather than accepting "y".
#
# This does NOT write U-Boot. The boot ROM cannot read NVMe, so a board that has
# only been provisioned still boots from its SD card — which is exactly the
# state you want to be in while checking the install worked. `nix run
# .#flash-spi` is the separate step that makes the SSD bootable on its own.
#
# TABLETOP_HOST, TABLETOP_SYSTEM and TABLETOP_LABEL are substituted by flake.nix.

host="$TABLETOP_HOST"
device="/dev/nvme0n1"
assume_yes=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host) host="$2"; shift 2 ;;
    --device) device="$2"; shift 2 ;;
    --yes) assume_yes=1; shift ;;
    -h|--help)
      echo "usage: nix run .#provision-ssd -- [--host user@host] [--device /dev/nvme0n1] [--yes]"
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

sshb() { ssh -o ConnectTimeout=10 "$host" "$@"; }

echo "==> target: $host  device: $device"

# --- preflight, all read-only -------------------------------------------------

if ! sshb true 2>/dev/null; then
  echo "cannot reach $host over ssh" >&2
  exit 1
fi

root_src=$(sshb "findmnt -n -o SOURCE /" 2>/dev/null || true)
echo "    current root:  $root_src"

# Refuse if the target is where the running system lives. Comparing prefixes
# rather than exact strings because root is a partition and the target is a
# whole disk.
case "$root_src" in
  "$device"*)
    echo "REFUSING: $device holds the running root filesystem ($root_src)." >&2
    exit 1 ;;
esac

if ! sshb "test -b $device" 2>/dev/null; then
  echo "REFUSING: $device is not a block device on $host." >&2
  exit 1
fi

case "$device" in
  /dev/nvme*) ;;
  *)
    echo "REFUSING: $device is not an NVMe device." >&2
    echo "This installs to an SSD; pass --device explicitly if that is wrong." >&2
    exit 1 ;;
esac

model=$(sshb "cat /sys/block/$(basename "$device")/device/model 2>/dev/null" || true)
size=$(sshb "lsblk -bdno SIZE $device 2>/dev/null" 2>/dev/null || true)
size=$(printf '%s' "$size" | tr -dc '0-9')
size=${size:-0}
echo "    drive:         ${model:-unknown} ($((size / 1000000000)) GB)"

# `grep -c` prints its count and still exits non-zero when that count is zero,
# so an `|| echo 0` fallback here yields "0\n0" and then a syntax error in the
# comparison. Sanitise instead of guessing.
mounted=$(sshb "lsblk -no MOUNTPOINT $device 2>/dev/null | grep -c ." 2>/dev/null || true)
mounted=$(printf '%s' "$mounted" | tr -dc '0-9' | head -c 3)
mounted=${mounted:-0}
if [ "$mounted" -gt 0 ]; then
  echo "REFUSING: something on $device is mounted. Unmount it first:" >&2
  sshb "lsblk -o NAME,SIZE,MOUNTPOINT $device" >&2
  exit 1
fi

echo "    existing partitions:"
sshb "lsblk -o NAME,SIZE,FSTYPE,LABEL $device 2>/dev/null | tail -n +2 | sed 's/^/      /'" || true

# --- confirmation -------------------------------------------------------------

if [ -z "$assume_yes" ]; then
  echo
  echo "This will ERASE $device on $host and install the NVMe system onto it."
  printf "Type the device path to continue: "
  read -r reply
  if [ "$reply" != "$device" ]; then
    echo "aborted."
    exit 1
  fi
fi

# --- partition and format -----------------------------------------------------

# One ext4 partition filling the drive, with /boot inside it. U-Boot reads the
# kernel itself and understands ext4, so no separate boot partition is needed —
# and a FAT firmware partition would only earn its keep on a board whose WiFi
# credentials have to be edited from a laptop. This one has Ethernet.
echo "==> partitioning $device"
sshb "sudo sh -c '
  set -e
  wipefs -a $device
  printf \"label: gpt\\n,,L\\n\" | sfdisk $device
  udevadm settle
'" || { echo "partitioning failed" >&2; exit 1; }

part="${device}p1"
sshb "test -b $part" || { echo "expected partition $part did not appear" >&2; exit 1; }

echo "==> formatting $part as ext4, label $TABLETOP_LABEL"
sshb "sudo sh -c '
  set -e
  mkfs.ext4 -q -F -L $TABLETOP_LABEL $part
  udevadm settle
'" || { echo "mkfs failed" >&2; exit 1; }

# --- copy the closure ---------------------------------------------------------

# Copied to the board's own store first, then installed from there. The
# alternative — building on the board — would need the flake and a compiler on a
# kiosk.
echo "==> copying system closure to $host (this is the slow part)"
nix copy --to "ssh://$host" "$TABLETOP_SYSTEM" 2>&1 | tail -3

# --- install ------------------------------------------------------------------

echo "==> installing onto $part"
sshb "sudo sh -c '
  set -e
  mkdir -p /mnt
  mount $part /mnt
  trap \"umount -R /mnt 2>/dev/null || true\" EXIT
  nix --extra-experimental-features \"nix-command flakes\" shell nixpkgs#nixos-install-tools -c \
    nixos-install --root /mnt --system $TABLETOP_SYSTEM --no-root-passwd --no-channel-copy
  test -f /mnt/boot/extlinux/extlinux.conf
'" || { echo "install failed" >&2; exit 1; }

echo
echo "==> installed. Verifying what U-Boot will find:"
sshb "sudo sh -c '
  mount $part /mnt 2>/dev/null || true
  echo \"    generations: \$(ls /mnt/boot/extlinux/ 2>/dev/null | wc -l) entries\"
  grep -m1 LINUX /mnt/boot/extlinux/extlinux.conf 2>/dev/null | sed \"s/^/    /\"
  umount /mnt 2>/dev/null || true
'" || true

cat <<EOF

The SSD now holds a complete system, but the board still boots from its SD card:
the boot ROM cannot read NVMe. To make the SSD bootable:

    nix run .#flash-spi

Do that with the SD card still inserted. U-Boot tries mmc before nvme, so the
card keeps winning until you remove it — which is what lets you verify the SPI
write before depending on it.
EOF
