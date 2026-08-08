# Architecture

## The seam

Three boards, two completely different hardware stacks:

```
          ┌─────────────────────────────────────────┐
          │  ttlauncher (network, not embedded)     │
          ├─────────────────────────────────────────┤
          │  Chromium --ozone-platform=wayland      │
          │  cage (wlroots compositor)              │  modules/kiosk.nix
          │  users, network, ssh, zram              │  modules/base.nix
          │  libinput, rotation, no blanking        │  modules/touchscreen.nix
          ╞═════════════ DRM / KMS ═════════════════╡  ← the seam
          │  Mesa panfrost    │  Mesa v3d           │
          │  panthor (kernel) │  vc4/v3d (kernel)   │  hosts/*.nix
          │  mainline Linux   │  RPi vendor kernel  │
          │  upstream U-Boot  │  RPi firmware       │
          │  RK3588           │  BCM2711 / BCM2712  │
          └─────────────────────────────────────────┘
```

Everything above the line is byte-identical on every board. Everything below is
mutually exclusive — there is no shared code path, and pretending otherwise is
how the earlier attempts got stuck.

This is why `modules/kiosk.nix` contains no conditionals. If it ever needs to
know which board it is running on, either the abstraction is wrong or something
belongs in `hosts/`.

## Why mainline on RK3588, and why that is the whole point

The Orange Pi 5 Plus can be run two ways:

1. **Vendor BSP** (Rockchip's 6.1 kernel + closed `libmali`). Boots easily.
   Gives you OpenCL and a proprietary GLES blob with a long history of
   compositor incompatibilities.
2. **Mainline** (Linux ≥ 6.13 + panthor + Mesa panfrost). More work to bring up.
   Gives you a **conformant open GLES 3.1 driver** that Chromium's Wayland/ANGLE
   path is actually tested against.

We take mainline, because option 1 cannot deliver the project's stated goal.

The relevant mainline history:

| Kernel | What landed |
| --- | --- |
| 6.10 | `panthor` — Mali-G610, Valhall with Command Stream Frontend |
| 6.13 | HDMI output on RK3588 becomes possible at all |
| 7.0 | HDMI 2.1 FRL (48 Gbps), H.264/HEVC stateless decoders |

Before 6.13 there was simply no display output on this SoC in mainline. That is
why `hosts/opi5plus.nix` pins `linuxPackages_latest` rather than a stable
kernel — it is a hard floor, not a preference.

The existing community flakes were evaluated and rejected:

- **gnull/nixos-rk3588** — the maintained fork of the abandoned
  `ryan4yin/nixos-rk3588`. Integrates Armbian's vendor kernel. Lists
  Mali/panthor support as a TODO; Ethernet, audio, WiFi and GPIO unverified.
- **tlan16/nixos-orange-5-pro** — 29 commits, kernel 6.1, closed `libmali`.

Neither reaches the open panfrost stack, which is the only reason to prefer this
board in the first place.

## Naming trap

The kernel driver is **panthor**. The Mesa userspace driver is **panfrost**.
They are not alternatives — panfrost (userspace) drives G610 *through* panthor
(kernel). The older `panfrost` kernel driver handles pre-Valhall Malis and is
not what this board uses. Expect to be confused by this at least once.

## Why the browser flags are what they are

In `modules/kiosk.nix`. The load-bearing ones:

- **`--ignore-gpu-blocklist`** — Chromium blocklists *both* panfrost and v3d by
  default. Without this it silently falls back to SwiftShader and every other
  flag in the list is inert. This is the single most important line in the repo.
- **`--use-angle=gles-egl`** — native GLES through ANGLE, the path that makes
  WebGL hardware-accelerated on Mali and VideoCore alike. The older
  `--use-gl=egl` spelling is deprecated and now ignored, which is a quiet way to
  lose acceleration while believing you configured it.
- **`--ozone-platform=wayland`** — talk to cage directly instead of via XWayland.
- **`--canvas-oop-rasterization`** — Canvas2D on the GPU rather than the CPU.

`cage` is used rather than a full compositor because it runs exactly one client
fullscreen and gives Chromium a direct-scanout path to KMS — the shortest route
from the browser's compositor to the panel. Chromium's own `ozone-platform=drm`
backend would be shorter still but is poorly maintained.

## Verifying acceleration — the one check that matters

Everything above is theatre if the GPU is not actually being used. On a running
board:

```sh
# 1. Did the GPU driver bind at all?
dmesg | grep -i panthor

# 2. What is Mesa actually using?
eglinfo | grep -i renderer     # expect: Mali-G610 / panfrost
glxinfo -B | grep -i renderer

# 3. What does the browser think? Navigate to chrome://gpu
```

`chrome://gpu` must report the renderer as Mesa **panfrost** (Orange Pi) or
**V3D** (Pi), with rasterization, canvas and WebGL all "Hardware accelerated".

If you see **llvmpipe** or **SwiftShader**, the entire stack is on the CPU. That
one check distinguishes a working image from a broken one, and it is worth
running before trusting any performance measurement.

If panthor did not bind, the usual cause is missing firmware: it requests
`arm/mali/arch10.8/mali_csffw.bin` at probe time. There is no
`mali-g610-firmware` package in nixpkgs — it ships inside `linux-firmware`,
pulled in via `hardware.enableRedistributableFirmware`.

## Why the launcher is not embedded

`tabletop.kiosk.url` points at `https://anicolao.github.io/ttlauncher/`.

The launcher is a SvelteKit app backed by Firebase. Embedding a build of it in
the image would mean reflashing every board to ship a launcher change, and would
not buy real offline capability anyway, because the Firebase backend is remote
regardless. Serving it over the network means a launcher release is a `git push`.

The cost is that the kiosk needs a network at boot. `modules/kiosk.nix` therefore
orders `cage-tty1` after `network-online.target`, so the browser does not race
DHCP and land on an error page that nobody is present to dismiss.

## History

Two earlier repositories attempted this, both RPi4-only, both dormant since
September 2025:

- **nix-tabletop** — hand-written, used real `nixos-hardware` APIs and
  `services.cage`. The right shape. Never built: its `flake.lock` contains only
  `nixpkgs` despite `flake.nix` declaring `nixos-hardware`, and its last five
  commits are escalating attempts to force a `dw-hdmi` kernel module via
  `boot.kernelPatches` — which forces a from-source aarch64 kernel build and was
  unfinishable on the 1-core builder that existed at the time.
- **tabletop-image** — GitHub Copilot output. Imports no hardware module at all,
  uses NixOS options removed years earlier, and has a malformed flake output.
  Superseded despite looking more complete on its default branch.

Two lessons carried forward: **never use `boot.kernelPatches` on these targets**,
and fix the builder before blaming the configuration.
