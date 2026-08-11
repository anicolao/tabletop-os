# Debugging graphics performance remotely

Instructions for working on the launcher's rendering performance without
sitting in front of the table. Everything here runs from a development machine
against the real hardware over SSH.

## Read this first: what is already known

Do not spend time re-establishing these. They were measured on the Orange Pi 5
Plus at 3840x2160, and they rule out most of the usual suspects.

**The graphics stack is accelerated and working.** `nix run .#cdp -- gpu`:

```
gpu_compositing        enabled          <- CSS compositing runs on the GPU
rasterization          enabled_force
2d_canvas              enabled
webgl                  enabled
webgpu                 enabled
opengl                 enabled_on
device: ANGLE (Mesa, Mali-G610 MC4 (Panfrost), OpenGL ES 3.1 Mesa 26.1.6)
```

**The platform sustains frame rate under heavy compositing.** 200 elements
animating `transform` and `opacity` simultaneously, with gradients and
`will-change`, at 4K: **57.4 fps**. An idle `requestAnimationFrame` loop on the
launcher: **60.3 fps**, `innerWidth` 3840, `devicePixelRatio` 1.

So anything that stays on the compositor is effectively free here. If the
launcher feels slow, the cost is on the main thread or in paint — not in the
GPU configuration, and not in a missing flag.

Two things genuinely are *not* accelerated, in case they matter: `video_decode`
and `video_encode` both report `disabled_software` despite
`--enable-features=VaapiVideoDecodeLinuxGL`, and `vulkan` is off.

## The tools

```sh
nix run .#cdp -- targets       # list debuggable pages
nix run .#cdp -- gpu           # what is hardware accelerated
nix run .#cdp -- fps [secs]    # frames actually delivered
nix run .#cdp -- eval '<js>'   # run JavaScript in the launcher
nix run .#cdp -- tap X Y       # synthetic touch tap
nix run .#cdp -- swipe X1 Y1 X2 Y2 [steps] [ms]
nix run .#cdp -- profile [secs] [out]
nix run .#cdp -- profile-swipe X1 Y1 X2 Y2 [reps] [ms] [out]
```

Plus the two ground-truth tools, which answer a different question:

```sh
nix run .#screenshot           # what the compositor drew
nix run .#photo                # what the panel emits, via the overhead webcam
```

`cdp` tells you about the page. Those tell you what actually reached the glass.
When they disagree, believe the photo.

### How it connects

The kiosk exposes Chromium's DevTools protocol on port 9222, bound to
loopback. `cdp` opens an SSH tunnel automatically. To drive it by hand, or to
attach a real DevTools UI:

```sh
ssh -L 9222:127.0.0.1:9222 admin@tabletop-opi5plus
# then open  chrome://inspect  and add 127.0.0.1:9222 as a target
```

Loopback binding is deliberate: the protocol executes arbitrary script in the
kiosk's browser, so it must never be reachable from the network. It is
configured by `tabletop.kiosk.remoteDebuggingPort` in `hosts/opi5plus.nix`.

## The workflow that finds things

**1. Confirm the kiosk is alive.** This is not optional — see the wedge below.

```sh
ssh admin@tabletop-opi5plus 'pgrep -c chromium'   # 10 = healthy, 4 = wedged
```

**2. Get a baseline frame rate while idle.**

```sh
nix run .#cdp -- fps 3
```

Below ~58 while nothing is happening means something is running every frame.

**3. Profile while actually interacting.** This is the one that matters. It
sends synthetic touch drags and captures a JS CPU profile across them, then
prints the top functions by self time:

```sh
nix run .#cdp -- profile-swipe 1200 1080 2600 1080 3 800
```

Coordinates are CSS pixels. `devicePixelRatio` is 1 here, so they are also
physical pixels: the screen is 3840x2160 and its centre is 1920,1080.

A real result from the launcher, swiping across the wheel:

```
3547ms  (idle)
 800ms  (program)
  49ms  getBoundingClientRect
  30ms  (garbage collector)
```

`getBoundingClientRect` forces synchronous layout. Being the largest
application cost during a drag is a strong signal of layout thrashing —
reading geometry inside a loop or a rAF handler that also writes style. That is
the kind of thing to look for.

The full profile is written as a `.cpuprofile` file, which can be loaded into
Chrome DevTools' Performance panel on any machine for a flame chart.

**4. Check whether animations are actually composited.** Anything animating a
property other than `transform`, `opacity` or `filter` forces paint, and at 4K
a full-screen repaint is 8.3 million pixels. That is where this hardware feels
slow even though compositing is free.

```sh
nix run .#cdp -- eval 'JSON.stringify(
  [...document.getAnimations()].map(a => ({
    target: a.effect && a.effect.target ? a.effect.target.className : "?",
    props: Object.keys((a.effect && a.effect.getKeyframes ? a.effect.getKeyframes()[0] : null) || {})
             .filter(k => !["offset","computedOffset","easing","composite"].includes(k))
  })).filter(x => x.props.some(p => !["transform","opacity","filter"].includes(p))).slice(0,20)
)'
```

**5. Count layers and elements**, since both scale the compositor's work:

```sh
nix run .#cdp -- eval 'document.querySelectorAll("*").length'
nix run .#cdp -- eval '[...document.querySelectorAll("*")].filter(e => getComputedStyle(e).willChange !== "auto").length'
```

## Starting point for the launcher, as measured

Taken with the commands above, so they can be re-run for comparison:

| measurement | value |
|---|---|
| elements in the document | 114 |
| elements with `will-change` | 0 |
| Web Animations touching non-composited properties | 0 |
| idle frame rate | 60.3 fps |
| top JS self time during a 3-swipe profile | `getBoundingClientRect`, 49ms |

That combination is worth reading carefully. The document is small, nothing is
promoted to its own layer, and no Web Animation touches a property that would
force paint — yet `getBoundingClientRect` dominates. That points at
JavaScript-driven layout reads rather than at CSS: geometry being measured
per-frame, most likely to position the wheel, which forces a synchronous layout
each time it is interleaved with a style write.

The first thing to try is caching those measurements and recomputing them only
on resize or when the layout genuinely changes, and driving the wheel with a
`transform` computed from cached geometry. Note also that `getAnimations()`
returning nothing means the motion is not using the Web Animations API at all,
so it is running on the main thread by definition — moving it to CSS
animations or WAAPI on `transform` would hand it to the compositor, where this
hardware has headroom to spare.

## What good looks like

- `fps` stays at 58-60 during a swipe, not only when idle.
- No single application function above a few ms of self time in a 5s profile.
- Animations restricted to `transform` / `opacity`.
- `will-change` used sparingly. Every promoted layer costs GPU memory, and at
  4K each full-screen layer is ~33 MB.

## Gotchas that will cost you an hour each

**The kiosk wedges intermittently.** cage comes up, sets the mode, and the
browser then blocks with only its three zygotes — four processes, no renderer,
no GPU process. `systemctl` reports everything active and the panel is black.
`pgrep -c chromium` returning 4 is the tell. A restart clears it:

```sh
ssh admin@tabletop-opi5plus 'sudo systemctl restart cage-tty1'
```

A watchdog does this automatically at boot, but only at boot — a kiosk that
wedges hours later stays wedged. If `cdp` reports no DevTools, check this
before anything else.

**Only one CDP session per page target.** Opening a second connection corrupts
the first's message stream, and `Profiler.stop` comes back unparseable. That is
why `profile-swipe` exists: it sends the touch events down the same socket as
the profiler commands rather than running `swipe` in parallel.

**cage's log is not under its unit.** journald files wlroots output under
`cage[PID]`, so `journalctl -u cage-tty1` shows almost nothing:

```sh
ssh admin@tabletop-opi5plus 'sudo journalctl -b | grep "cage\["'
```

That is where modeset failures appear.

**`chrome://gpu` is unreachable on this device.** Chromium discards `chrome://`
URLs passed on the command line, and kiosk mode has no address bar.
`cdp gpu` asks the same question through `SystemInfo.getInfo`.

**Mouse events are the wrong input.** This is a touch device and the UI may
ignore them entirely. Use `tap` and `swipe`, which dispatch real touch events.

**DisplayPort is not always up.** On some cold boots the DP AUX channel fails,
the connector reports `connected` with a zero-byte EDID and only fallback
modes, and no mode can be set at all. If the panel is dark, check that before
blaming the page:

```sh
ssh admin@tabletop-opi5plus 'cat /sys/class/drm/card1-DP-1/status; sudo wc -c < /sys/class/drm/card1-DP-1/edid'
```

A zero-byte EDID means the link, not the launcher.
