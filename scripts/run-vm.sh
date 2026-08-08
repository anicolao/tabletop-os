# Wrapper around the generated NixOS VM runner.
#
# Exists to make display resolution a runtime choice. The virtio-gpu device is
# baked into the runner with id=gpu0, so `-set device.gpu0.xres=...` overrides
# its properties without adding a second GPU (which is what passing another
# -device would do).
#
# TABLETOP_VM_RUNNER and TABLETOP_VM_DEFAULT_RES are substituted by flake.nix.

usage() {
  cat <<EOF
Boot the tabletop kiosk in QEMU.

Usage:
  nix run .#vm
  nix run .#vm -- --resolution 3840x2160
  nix run .#vm -- --resolution 1280x800 -display none -serial stdio

Options:
  -r, --resolution WxH   emulated panel size (default $TABLETOP_VM_DEFAULT_RES)
  -h, --help             this message

Any other arguments are passed straight through to QEMU.

The guest also advertises 5120x2160 and 4096x2160. Set this to match the real
tabletop panel before judging layout — the launcher is laid out radially and is
sensitive to aspect ratio.

Disk state lives in ./tabletop-vm.qcow2 relative to where you run this, and is
reused across boots. Delete it, or set NIX_DISK_IMAGE, for a clean start.
SSH is forwarded: ssh -p 2222 admin@localhost
EOF
}

resolution=""
passthrough=()

while [ $# -gt 0 ]; do
  case "$1" in
    -r | --resolution)
      if [ $# -lt 2 ]; then
        echo "error: $1 needs an argument like 1920x1080" >&2
        exit 2
      fi
      resolution="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      passthrough+=("$1")
      shift
      ;;
  esac
done

if [ -n "$resolution" ]; then
  # Accept WxH only, and require both halves to be plain positive integers.
  # A malformed value would otherwise reach qemu as a device property and
  # produce a much less obvious error.
  if ! printf '%s' "$resolution" | grep -Eq '^[0-9]+x[0-9]+$'; then
    echo "error: --resolution must look like 1920x1080, got '$resolution'" >&2
    exit 2
  fi
  width="${resolution%x*}"
  height="${resolution#*x}"
  if [ "$width" -lt 640 ] || [ "$height" -lt 480 ]; then
    echo "error: refusing a panel smaller than 640x480 ($resolution)" >&2
    exit 2
  fi
  passthrough+=(-set "device.gpu0.xres=$width" -set "device.gpu0.yres=$height")
  echo "tabletop-vm: display $resolution"
fi

# ${arr[@]+"${arr[@]}"} keeps this working under `set -u` when the array is
# empty, which is the common case.
exec "$TABLETOP_VM_RUNNER" ${passthrough[@]+"${passthrough[@]}"}
