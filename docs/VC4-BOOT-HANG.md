# Raspberry Pi 5 boot hang in vc4 — findings for an upstream report

Reproduced on `tabletop-os` (2026-08-18), Raspberry Pi 5 / BCM2712,
`nixos-raspberrypi` vendor kernel **6.18.34-unstable_20260604**.

## Symptom

Roughly **40–57% of cold boots** stop dead partway through boot. The kernel
stops emitting, there is no panic and no oops, the serial console goes silent
and accepts no input, and nothing reaches the journal. Only the hardware
watchdog recovers the board, which it has now done ~60 times without a single
failure (~85s each).

## It is vc4, and only vc4

Four configurations, 71 boots:

| vc4 | v3d | boots | hangs | rate |
|:---:|:---:|---:|---:|---:|
| blacklisted | blacklisted | 15 | 0 | 0% |
| blacklisted | loaded | 5 | 0 | 0% |
| loaded | blacklisted | 7 | 2 | 29% |
| loaded | loaded | 44 | 25 | 57% |

0 hangs in 20 vc4-absent boots against the pooled vc4-present rate is p≈0.0002.
v3d is cleared: it does comparable work in the same window and never hangs.

## Where it dies

With `drm.debug=0x06` and `boot.consoleLogLevel = 8` (both required — see
"instrumentation traps"), hangs stop inside vc4's connector bring-up, e.g.:

```
update_display_info: [CONNECTOR:35:HDMI-A-1] HDMI sink / HF-VSDB / ELD
check_connector_changed: [CONNECTOR:35:HDMI-A-1] status updated, Changed epoch
drm_sysfs_connector_hotplug_event
drm_client_hotplug: fbdev: ret=0
drm_connector_helper_hpd_irq_event          <- last line, 10/10 in one config
```

**Caveat:** the last printed line varies with configuration
(`drm_connector_helper_hpd_irq_event` with fbdev off, `drm_client_hotplug` with
`force_hotplug=1`). It is a lower bound on progress, not necessarily the
faulting function.

## Discriminator

Hung boots show **≥2** `drm_client_hotplug` events; healthy boots show 0 or 1.
Across six configurations: **20 of 20 hangs, 0 of 39 healthy**. This held
through every change that altered the base rate.

## What does NOT fix it

| attempt | result |
|---|---|
| `drm_kms_helper.poll=0` | hangs continue; same signature. vc4 uses HPD interrupts, not the poll timer |
| `drm_kms_helper.fbdev_emulation=0` | hangs continue, with **zero** atomic checks in the whole boot |
| `vc4.force_hotplug=1` | hangs continue (35%, 23 boots) — and this **disables the HPD IRQ handler entirely** (`!force_hotplug` guard in `vc4_hdmi_hpd_irq_thread`) |
| removing a duplicated helper call (patch below) | hangs continue; signature unchanged |
| HDMI physically unplugged | 40% hang rate, 25 boots |
| `hung_task_panic=1` + `softlockup_panic=1` | **never fire.** Recovery stays at the watchdog's 85s |

That last row matters: with both detectors verified live in `sysctl`, neither
ever fires. After the hang **no CPU is executing kernel timer or scheduler
code** — this is not a lock deadlock with the rest of the kernel running.

## Not the cause, but a real defect

`vc4_hdmi_handle_hotplug()` in this vendor tree calls
`drm_atomic_helper_connector_hdmi_hotplug()` **twice** with identical arguments,
separated only by a comment block. Upstream (torvalds/linux master) calls it
once and has neither the second call, the legacy CEC block, nor the mutex
comment. Each call does a full EDID read over DDC I2C plus a CEC
physical-address update, on a path whose own comment says it runs **without**
`vc4_hdmi->mutex` because taking the lock deadlocks against CEC.

Patch: `patches/vc4-hdmi-single-hotplug.patch`. **Tested and it does not fix
the hang** — reported only because the divergence from upstream is real.

## Instrumentation traps

Four settings were accepted and silently did nothing. Anyone reproducing this
should verify the *effect*, not that the setting took:

- `hung_task_timeout_secs=` is **not** a boot parameter, only a sysctl. The
  kernel says so (`Unknown kernel command line parameters`) and `/proc/cmdline`
  shows it regardless. At the 120s default the detector fires *after* the
  watchdog resets the board.
- `vc4.dyndbg=+p` enables exactly **one** callsite; DRM uses `drm_dbg_*()`, not
  `pr_debug`. Use the `drm.debug` bitmask.
- `drm.debug` alone goes only to the journal, which dies with the board.
  `boot.consoleLogLevel = 8` is required to reach serial, because `drm_dbg()`
  prints at `KERN_DEBUG` and printk needs `level < console_loglevel`.
- Death **time** is not the signal. It moved 8.9s → 9.3s → 22.2s across
  configurations, always in a tight cluster, which repeatedly suggested
  "time-locked" and was repeatedly wrong. Count sequence positions instead.

## Raw data

~20MB of serial captures covering every boot, plus per-run result tables, in
`~/projects/games/tabletop/rpi5-hang-data/`.
