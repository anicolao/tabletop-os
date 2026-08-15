# Write U-Boot into the board's SPI NOR flash, from this machine.
#
# This is what makes the SSD bootable. The RK3588 boot ROM reads a bootloader
# from SPI NOR, eMMC or SD and nowhere else — never from NVMe — so booting from
# an SSD always means U-Boot lives somewhere the boot ROM can reach.
#
# Do this with the SD card still inserted. U-Boot's boot order is
#
#   boot_targets=mmc1 mmc0 nvme scsi usb pxe dhcp spi
#
# so a card carrying a valid extlinux.conf keeps winning afterwards. That is the
# point: it lets the SPI write be verified while the old path still works, and
# it leaves a rescue path that needs no tools — insert the card.
#
# TABLETOP_HOST and TABLETOP_UBOOT_SPI are substituted by flake.nix.

host="$TABLETOP_HOST"
mtd="/dev/mtd0"
assume_yes=""
backup_dir="."

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host) host="$2"; shift 2 ;;
    --mtd) mtd="$2"; shift 2 ;;
    --backup-dir) backup_dir="$2"; shift 2 ;;
    --yes) assume_yes=1; shift ;;
    -h|--help)
      echo "usage: nix run .#flash-spi -- [--host user@host] [--mtd /dev/mtd0] [--backup-dir .] [--yes]"
      exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

sshb() { ssh -o ConnectTimeout=10 "$host" "$@"; }

echo "==> target: $host  flash: $mtd"

if ! sshb true 2>/dev/null; then
  echo "cannot reach $host over ssh" >&2
  exit 1
fi

# --- preflight, read-only -----------------------------------------------------

if ! sshb "test -c $mtd" 2>/dev/null; then
  echo "REFUSING: $mtd is not a character device on $host." >&2
  echo "Is the SPI flash exposed? Check: ssh $host 'cat /proc/mtd'" >&2
  exit 1
fi

echo "    mtd table:"
sshb "cat /proc/mtd | sed 's/^/      /'" || true

flash_size=$(sshb "cat /sys/class/mtd/$(basename "$mtd")/size 2>/dev/null" 2>/dev/null || true)
flash_size=$(printf '%s' "$flash_size" | tr -dc '0-9')
flash_size=${flash_size:-0}
# GNU stat first: coreutils is in this app's runtimeInputs, so `stat` is the GNU
# one even on macOS, where `-f` means "filesystem status" and dumps block counts
# instead of a size. BSD stat is the fallback for a bare host.
image_size=$(stat -c %s "$TABLETOP_UBOOT_SPI" 2>/dev/null \
  || stat -f %z "$TABLETOP_UBOOT_SPI" 2>/dev/null || true)
image_size=$(printf '%s' "$image_size" | tr -dc '0-9')
image_size=${image_size:-0}
echo "    flash size:    $flash_size bytes"
echo "    image size:    $image_size bytes"

if [ "$flash_size" -gt 0 ] && [ "$image_size" -gt "$flash_size" ]; then
  echo "REFUSING: image is larger than the flash." >&2
  exit 1
fi

# --- back up what is there now ------------------------------------------------

# Cheap insurance: 16 MiB. Kept on the workstation rather than only on the
# board, because the reason to want it is that the board no longer boots.
stamp=$(date +%Y%m%d-%H%M%S)
backup="$backup_dir/spi-backup-$stamp.bin"
echo "==> backing up current flash contents to $backup"
sshb "sudo dd if=$mtd bs=64k status=none" > "$backup" || {
  echo "backup failed; refusing to write" >&2
  rm -f "$backup"
  exit 1
}
echo "    wrote $(wc -c < "$backup") bytes"

# --- confirmation -------------------------------------------------------------

if [ -z "$assume_yes" ]; then
  cat <<EOF

About to overwrite $mtd on $host with U-Boot.

Recovery if this goes wrong: a bootable SD card overrides SPI, so keep the card
inserted. Failing that, the board has a maskrom button and can be re-flashed
over USB-C with rkdeveloptool.

EOF
  printf "Type FLASH to continue: "
  read -r reply
  if [ "$reply" != "FLASH" ]; then
    echo "aborted. Backup kept at $backup"
    exit 1
  fi
fi

# --- write --------------------------------------------------------------------

echo "==> copying image to the board"
scp -q "$TABLETOP_UBOOT_SPI" "$host:/tmp/u-boot-rockchip-spi.bin" || {
  echo "copy failed" >&2; exit 1; }

# flashcp erases and verifies; a raw dd to /dev/mtd0 would skip the erase and
# leave a corrupt image on any block that was not already blank.
echo "==> flashing (erase + write + verify)"
sshb "sudo sh -c '
  set -e
  if command -v flashcp >/dev/null 2>&1; then
    flashcp -v /tmp/u-boot-rockchip-spi.bin $mtd
  else
    nix --extra-experimental-features \"nix-command flakes\" shell nixpkgs#mtdutils -c \
      flashcp -v /tmp/u-boot-rockchip-spi.bin $mtd
  fi
'" || { echo "flash failed — the backup is at $backup" >&2; exit 1; }

# --- verify -------------------------------------------------------------------

echo "==> verifying readback"
remote_sum=$(sshb "sudo dd if=$mtd bs=$image_size count=1 status=none | sha256sum | cut -d' ' -f1")
local_sum=$(sha256sum "$TABLETOP_UBOOT_SPI" | cut -d' ' -f1)
if [ "$remote_sum" = "$local_sum" ]; then
  echo "    OK: flash matches the image"
else
  echo "    MISMATCH: flash does not match the image" >&2
  echo "    expected $local_sum" >&2
  echo "    got      $remote_sum" >&2
  echo "    Backup is at $backup. Keep the SD card inserted." >&2
  exit 1
fi

cat <<EOF

Done. Now, in this order:

  1. Reboot with the SD card still in. It should boot exactly as before — mmc
     precedes nvme, so this proves the SPI write broke nothing without yet
     depending on the new path.
  2. Power off, remove the card, power on. U-Boot now comes from SPI and the
     kernel from the SSD.
  3. Keep that card. It is the rescue path and it works by being inserted.

EOF
