# The Raspberry Pi 5 boot hang — solved

**Cause: plymouth.** Removing it took the hang from 39–57% of cold boots to
0 in 20. Fixed 2026-08-18.

This document exists because the fault took two days and eleven wrong theories
to find, and almost all of the cost was method rather than difficulty.

## Symptom

40–57% of cold boots stopped dead around 9s. No panic, no oops, dead serial
console, nothing in the journal. Only the hardware watchdog recovered the board
(~85s), which it did roughly a hundred times without once failing.

## Cause

Plymouth performs its own KMS/framebuffer handover during early boot, in the
same window where vc4 is binding its connectors. When a connector hotplug event
landed mid-handover, the SoC wedged — all cores, no output.

```
NO PLYMOUTH:  20 boots | 0 hung | 0%
p(0 hangs in 20 | rate were 39%) = 0.000051
```

The clean streak is not the strongest evidence. **Nineteen of those boots
reached the exact signature that had predicted a hang 23 times out of 23 across
seven configurations, and every one survived.** The discriminator inverted.

Plymouth was cosmetic, present since the initial commit, so a keyboard-less
tabletop would not show scrolling kernel messages while Chromium started.

**Unexplained:** plymouth was in the image from 2026-08-08, but hangs were only
reported from the evening of 08-15. Something else changed then that made the
race start losing. Not known.

## Eleven things that were not the cause

Each was tested and rejected by measurement, not argument. Do not re-run without
a new reason.

| ruled out | how |
|---|---|
| undervoltage / power | `in0_lcrit_alarm` reads 0; no surviving log has an undervoltage line, including a battery boot |
| brcmfmac | deferring it moved which line printed last, not the fault |
| console_lock deadlock | `hung_task_panic` + `softlockup_panic` verified live, never fired |
| framebuffer console handover | hangs occur when no framebuffer is ever created |
| display output | 40% hang rate with HDMI physically unplugged, 25 boots |
| connector polling | `drm_kms_helper.poll=0` verified live, no change |
| fbdev emulation | `fbdev_emulation=0`, zero atomic checks in the whole boot, still hung |
| the HPD IRQ handler | `vc4.force_hotplug=1` disables it outright; 35% hang rate anyway |
| a duplicated vc4 helper call | patched out in a from-source kernel; 40%, signature unchanged |
| kernel version | pinned to 6.12.47, the exact release the known-good card runs; 50% |
| CPU governor cap | removed; 39% over 33 boots |

## The methodological failures that cost the time

**Instrumentation that was accepted and did nothing.** Verify the *effect* on
the target, never that the setting took:

- `hung_task_timeout_secs=` is a sysctl, not a boot parameter. `/proc/cmdline`
  shows it; the live sysctl stays at 120. The kernel says so in a line nobody
  read: `Unknown kernel command line parameters`.
- `systemd-udev-settle.service` does not exist on this system, so ordering
  against it is inert.
- `vc4.dyndbg=+p` enables exactly one callsite. DRM uses `drm_dbg_*()`, so the
  knob is the `drm.debug` bitmask.
- `drm.debug` writes only to the journal, which dies with the board.
  `boot.consoleLogLevel = 8` is required to reach serial.
- A hand-written patch verified with macOS BSD `patch` failed under GNU `patch`
  in the Nix sandbox. Generate diffs with `diff -u`; verify with the tool that
  will apply them.

**Analysis errors.**

- `grep` without `-a` reports **no matches** on a log containing terminal escape
  bytes. This produced two false conclusions, including "Tor is not in the
  image" when it demonstrably was.
- Death *time* is not the signal. It moved 8.9s → 9.3s → 22.2s across
  configurations, always in a tight cluster, and repeatedly suggested
  "time-locked". Count sequence positions instead.
- "Last line before silence" is a lower bound on progress, not the faulting
  function. It changes with configuration.
- `drm_client_hotplug` counts **clients notified**, not calls into vc4. On 6.12
  the symbol is `drm_client_dev_hotplug`, so a grep for the 6.18 name silently
  reads zero.
- Comparing our runtime `/proc/cmdline` against the working card's
  `cmdline.txt` **file** invented a dozen differences. Everything before
  `console=` is prepended by the Pi firmware on any card.
- A perfect correlate is not a cause. `>=2 hotplug events` predicted hangs 23
  times out of 23 and was still the passenger, not the driver.

**The one that mattered most:** removing plymouth was Experiment B in the plan
written on 2026-08-16 and was skipped for two days in favour of instrumentation
and a driver bisect. The answer was on the list the whole time.

## What found it

Imaging `working.img` — the known-good card — and asking *what is different*
rather than *does it also fail*. That produced, in twenty minutes: identical
`config.txt`, kernel version ruled out, and the observation that the working
card boots a far simpler userspace. Differential diagnosis against a known-good
reference beat two days of hypothesis-testing on the failing system.

## Raw data

~26MB of serial captures covering every boot of the investigation, plus
per-run result tables, in `~/projects/games/tabletop/rpi5-hang-data/`.
The unapplied kernel patch is at `patches/vc4-hdmi-single-hotplug.patch`; the
duplicated call it removes is a real divergence from upstream and worth
reporting, but it is not this bug.
