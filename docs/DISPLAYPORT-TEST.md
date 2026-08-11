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

## Two channels, and why both

There is now a webcam suspended above the table, attached to the Mac. That
gives two independent views:

```sh
nix run .#screenshot   # what the compositor drew   — the software's claim
nix run .#photo        # what the panel emits       — the world's answer
```

Their **disagreement** is the diagnosis:

| screenshot | photo | meaning |
|---|---|---|
| good | good | working — the fault, if any, is elsewhere |
| good | black | cable, monitor input, or panel. Nothing here will fix it. |
| black | black | ours. Start with cage and Chromium. |
| black | good | impossible; distrust the capture before believing this |

Row two is the one that cost an evening. Every software signal on the board
said healthy, and every one of them was right.

Before starting, still rule out the obvious physical causes: set the monitor's
input **explicitly** rather than auto-select, and use one cable at a time,
noting the physical port.

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
nix run .#photo
```

Take both, every time, and read them as a pair against the table above. A
coredump count says something crashed; only these two together say whether
anyone watching the table would have noticed.

Note that `.#photo` can also answer a question `.#screenshot` cannot: whether
the panel went black *without* the compositor noticing. If a crash leaves
Chromium restarting behind a blank panel, the pair will show it — a good
screenshot alongside a black photo, taken seconds apart, at a known time.
