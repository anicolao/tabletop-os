# DisplayPort test plan

## Why this document exists

DisplayPort on the Orange Pi 5 Plus was made to work — `3840x2160 @ 60`,
verified on hardware — and then reverted in `3cb2955` because the board
appeared to become unusable. The reasoning behind that revert was partly
wrong, and this plan exists to establish what is actually true before the
work is either restored or abandoned.

## What went wrong with the previous diagnosis

Two mistakes, both worth naming so the same evening is not repeated.

**A black screen was read as a software fault.** It was not. A `grim` capture
taken at the end showed the launcher rendering perfectly, in a correctly bound
framebuffer, on an active CRTC routed to a connected connector whose EDID the
board could read. The fault was downstream of the HDMI socket — cable, monitor
input selection, or panel. Hours of configuration changes were made against a
system that was never broken.

**"Chromium crashes on DisplayPort" was asserted from a correlation that does
not survive scrutiny.** Nine coredumps, all with the same stack:

```
wl_proxy_marshal_array_flags -> realloc -> PartitionExcessiveAllocationSize
```

They all occurred during the DisplayPort session, and none occurred during the
HDMI session that followed. But that DisplayPort session was also the period of
constant interference: cage restarts, redeploys, cables being plugged and
unplugged. And DisplayPort demonstrably *worked* twice during it — once
spanning both outputs, once alone.

A better hypothesis: that stack is what unbounded growth of libwayland's
outbound buffer looks like, which is consistent with Chromium reacting to a
storm of `wl_output` events. DisplayPort-over-USB-C appears late, after PD
negotiation and alt-mode entry, and can re-announce — so it produces far more
output-topology churn than HDMI. That would make DisplayPort a *trigger for
churn*, not a cause of crashes.

The tests below are designed to separate those.

## Before starting

Rule out the physical layer first, since it dominated last time:

- Set the monitor's input **explicitly**, not on auto-select.
- Use one cable at a time. Note which physical port.
- After any change, capture what the board thinks it is showing:

```sh
nix run .#screenshot
```

A correct image with a black panel means the fault is the cable, the input
selection, or the monitor — nothing in this repository will fix it.

## Restoring the DisplayPort work

It is preserved at `a256f9f`:

```sh
git show a256f9f -- hosts/opi5plus.nix modules/kiosk.nix
```

Two device-tree overlays and one cage flag:

- `dp0-over-usbc` — enables `dp0` on `vp2` so a `DP-1` connector exists
- `usbc-displayport-altmode` — declares `svid = 0xff01` on the connector, without
  which `tcpm` never enters DP Alt Mode
- `-m last` on cage — use one output rather than spanning all of them

## Test 1 — is DisplayPort stable when left alone?

The control the previous session never ran.

1. DisplayPort cable only. No HDMI attached.
2. Cold boot. **Touch nothing** — no restarts, no deploys, no replugging.
3. Wait 30 minutes.
4. `ssh admin@tabletop-opi5plus 'coredumpctl list --no-pager | grep -c chromium'`

**No crashes** — DisplayPort is fine in steady state, and the previous
diagnosis was an artefact of interference. Go to test 2.

**Crashes with no interaction** — DisplayPort itself is implicated. Go to
test 3.

## Test 2 — does output churn trigger it?

Only if test 1 was clean.

1. From the stable state above, plug in HDMI. Wait 2 minutes. Check the count.
2. Unplug HDMI. Wait 2 minutes. Check again.
3. `sudo systemctl restart cage-tty1`. Wait 2 minutes. Check again.

A crash appearing at a plug/unplug event, and not otherwise, confirms output
topology change as the trigger. That is a Chromium/wlroots interaction and the
mitigation is to avoid changing outputs at runtime — which a fixed installation
does anyway.

## Test 3 — mode or path?

Only if test 1 crashed unprompted. This separates bandwidth from the DP output
path.

Force DisplayPort to a lower mode using the mechanism already in
`hosts/opi5plus.nix`:

```nix
forceHdmi1080p60 = true;   # adapt the connector name to DP-1
```

- Stable at a lower mode → bandwidth or link timing at 4K60.
- Still crashes → the DisplayPort output path itself.

## Recording results

Capture, for each test:

```sh
ssh admin@tabletop-opi5plus '
  coredumpctl list --no-pager | tail -5
  sudo journalctl -u cage-tty1 -b --no-pager | tail -20
  for c in /sys/class/drm/card*-*/status; do echo "$c $(cat $c)"; done
'
nix run .#screenshot
```

The screenshot is the important one. It is the only artefact that distinguishes
"the kiosk is broken" from "the panel is not showing what the kiosk drew", and
failing to take one is what cost the previous session.
