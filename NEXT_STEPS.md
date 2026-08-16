# Raspberry Pi 5 debugging — retrospective and plan

Written 2026-08-16 ~03:45, at the end of a long session. Nothing in here has
been committed; the working tree and the deployed generation are described
below so tomorrow can start from a known position.

---

## 1. What is actually fixed

These are measured, reproduced across multiple cold boots, and I am confident
in them.

### WiFi association — solved

The Pi's radio had never once completed an association: 14 boots, 18 four-way
handshake failures. The cause was **the 2.4GHz radio**, not credentials, not
power save, not the regulatory domain.

Every failure was on a `…:7d:…` BSSID and every success on a `…:7e:…` one:

```
E0:63:DA:7D:45:54   chan 1     2412 MHz   signal 74    <- fails, every time
E0:63:DA:7E:45:54   chan 149   5745 MHz   signal 61    <- works, first try
```

The same split held across two *different* physical access points, which rules
out one sick AP. And because 2.4GHz is the **stronger** signal here, the
supplicant ranked it first and tried it first on every boot. The link was never
intermittent — it failed deterministically, then fell through to 5GHz and
worked. How long a boot took depended only on how many retries that needed.

Fix: `tabletop.wifi.band = "a"`, plus a lower-priority unrestricted profile so a
portable table carried out of 5GHz range still gets a link.

| | before | after |
|---|---|---|
| boot | 1m19s | **~42s** |
| handshake failures | 3 | **0** |
| `set chanspec … reason -52` | 40 | **0** |
| wifi connect | 55.7s | ~11s |

The illegal-channel scanning disappeared as a *consequence* — restricting to
5GHz means the scan never visits the 2.4GHz channels the firmware was refusing.

### Boot time — 1m19s to ~42s

From the WiFi fix plus, earlier in the session, dropping a blocking `nmcli
reload` (2m21s), and not waiting through timesyncd's backoff.

### The watchdog works

Commit `6783c25` was written blind and never tested. It is now tested: three
hangs in a row on the night of the 16th, three automatic resets, no human. That
converts "the tabletop didn't come up" into "the tabletop took an extra minute".

**But see §3 — it also hid the fault from my own instrumentation.**

---

## 2. The tor question — you were right, I was wrong

I asserted several times that tor was not in the image. That was false, and the
photos settle it. Here is the full mechanism.

The image is built through **`nixos-images`' `image-installer` module**
(`flake.lock` pins `nixos-images` rev `cbbd6db3`; the module is
`nix/image-installer/module.nix`). It contains, verbatim:

```nix
network_status="Root password: $(cat /var/shared/root-password)
Local network addresses:
$(ip -brief -color addr | grep -v 127.0.0.1)
$([[ -e /var/shared/onion-hostname ]] && echo "Onion address: $(cat …)" \
   || echo "Onion address: Waiting for tor network to be ready...")
Multicast DNS: $(hostname).local"
…
msgs+=("Press 'Ctrl-C' for console access")
```

That is character-for-character what you photographed at 03:23:02 and 03:23:18.

It reaches the screen because the same profile sets up an autologin root getty:

```
agetty --login-program …/login --issue-file /etc/issue:/etc/issue.d:/run/issue:/run/issue.d \
       --autologin root
```

### Why my checks missed it, three different ways

1. **It never goes through the journal or the kernel console.** It is painted on
   tty1 by a login program. My `journalctl | grep` and my serial-log searches
   were looking in places it structurally cannot appear. Zero matches was a true
   answer to the wrong question.
2. **`grep` without `-a`.** The serial capture contains terminal escape bytes,
   so GNU/BSD grep classifies it as binary and reports **no matches at all**,
   exit 1. I ran `grep -icE "tor|onion" serial.log` and read "0" as evidence of
   absence. This is the *same bug* that made my hang counter report
   `kernel_boots=1` through a hang (§3). One bad habit, two false conclusions.
3. **I checked the thing I had disabled, not the thing you saw.**
   `services.tor.enable = lib.mkForce false` and masking
   `hidden-ssh-announce.service` are both real and both verified. They removed
   the tor *daemon* and the *announce* unit. They did nothing about the status
   screen, which prints "Waiting for tor network to be ready…" whenever
   `/var/shared/onion-hostname` is missing — so **disabling tor made that
   message permanent rather than removing it.**

### Two things this uncovers that matter more than the message

**(a) A random root password is set on every activation, and displayed.**

```nix
system.activationScripts.root-password = ''
  ${pkgs.xkcdpass}/bin/xkcdpass --numwords 3 … > /var/shared/root-password
  echo "root:$(cat /var/shared/root-password)" | chpasswd
'';
services.openssh.settings.PermitRootLogin = "yes";
```

`modules/base.nix` states there is "deliberately no password anywhere in this
repo" and sets `users.mutableUsers = false`. That claim is false in the shipped
image: the installer profile sets a root password behind it, and prints it on
the tabletop's screen in a room where anyone can read it
(`panoramic-emptier-untried`, in your photo). `hosts/rpi5.nix` does force
`PermitRootLogin = "prohibit-password"`, so remote password login is blocked —
but console and serial login as root are not, and the serial capture shows
`root@tabletop-rpi5` prompts from exactly this autologin.

**Treat that password as compromised; it is in two photos and in this repo's
issue history.** It is regenerated on each activation, so a rebuild rotates it.

**(b) It is a strong suspect for the cage restarts.**

`getty@tty1` (autologin root, painting this screen) and `cage-tty1` want the
same VT. The kiosk watchdog has been restarting cage on essentially every boot —
three times, then a stubborn one. I attributed that to a timing bug in the
watchdog (real, and fixed in the working tree), but contention for tty1 is a
better explanation for why cage came up with no renderer in the first place, and
it was never on my list because I did not know a getty was there.

---

## 3. Where I went wrong, and the pattern

Recorded because the pattern cost more time than any individual mistake.

| # | Claim I made | Reality |
|---|---|---|
| 1 | Power save off is "the fix" for association | A real contributor. Declared a fix on **one** lucky boot; the next boot failed 3 handshakes with it active. |
| 2 | Regdom flapping breaks the handshake; pinning CA fixes it | Helped marginally (3→2 failures). Not the mechanism. Also `cfg80211.ieee80211_regdom=` registers as a **USER hint**, not the core default, so the flapping it was meant to stop continues. |
| 3 | The udev `RUN+="iw …"` rule causes the boot hang | Removed for good independent reasons, but the hang continued. I compared 5 hangs to 4 clean boots and called it. |
| 4 | Deferring `brcmfmac` will confirm the driver is at fault | Disproved it instead — see §4. |
| 5 | Tor is not in the image | Wrong. §2. |

**The pattern is over-claiming from small samples on an intermittent fault, and
trusting instrumentation I had not validated.** Two concrete instrumentation
failures:

- `grep` without `-a` on a binary-ish log silently returned "no matches" — used
  both for the hang counter and the tor search.
- `systemd-udev-settle.service` does not exist on this system, so my first
  ordering anchor was inert. I only caught that one because I checked.

There is an irony worth keeping: I criticised the kiosk watchdog for a check
that "fails open and reports success either way", and then shipped exactly that
in my own hang counter.

**Sample sizes needed.** The hang rate is roughly 1 in 7. To claim a fix:

| observed rate | boots needed for ~95% confidence it is gone |
|---|---|
| 1 in 7 (~14%) | **~20 consecutive clean boots** |
| 1 in 3 | ~8 |

Nothing under 20 clean boots should be called a fix tomorrow.

---

## 4. The hang — current best understanding

**It is time-locked, not driver-locked.** Nine occurrences:

```
8.879  8.918  8.923  8.978  9.087  9.096  9.143  9.203  9.228
```

All inside a **350 ms window**. Before deferring brcmfmac, the last line was
always `brcmfmac … wld0: renamed from wlan0`. After deferring it — so brcmfmac
was not loading at all in that window — the board still hung at 8.879s and
8.918s, with a new last line:

```
vc4-drm axi:gpu: [drm] fb0: vc4drmfb frame buffer device
```

So brcmfmac was never the cause; it was whatever happened to print last. The
constant across both configurations is the **DRM framebuffer console handover**.
In a healthy boot, `fb0: vc4drmfb` lands at 8.917s — the same instant.

### Working hypothesis: console_lock deadlock in the fbcon/DRM handover

This explains every symptom that made the fault look like a power fault:

- **No panic, no oops, dead serial.** Everything that printk's or writes to
  `/dev/console` blocks. The kernel need not have crashed to go silent.
- **Boot stops entirely.** systemd writes to the console constantly, so it
  blocks too — no progress, no SSH.
- **Nothing in the journal afterwards.** journald never got the messages.
- **Varies by a factor of six in earlier reports (7s–41s).** Those were measured
  before continuous serial capture, against a different config, and are the
  weakest data we have. Every death recorded *with* continuous capture is in the
  350 ms window.

Plymouth is in this window too (`Stopped Plymouth switch root service` at
8.077s) and performs its own KMS handover, so it is part of the same suspect
region rather than a separate theory.

### Retracted: booting the known-good Raspberry Pi OS card

**You are right, and this should not be in the plan.** I proposed it when the
working theory was a hardware or power fault, where it would have discriminated
hardware from image. That theory is dead: the fault is time-locked to a specific
software transition, in a code path this image controls, on an image carrying an
installer profile we did not intend to ship. Meanwhile you have used the
known-good card daily for weeks with none of these symptoms — which is already
the observation the experiment would have produced.

There is **no live hypothesis it would discriminate**, so it is off the plan. If
one ever appears — something like "the SD slot or PSU degraded this week" —
it comes back, but nothing currently points that way.

---

## 5. State to resume from

**Deployed on the Pi** (generation `fx7ja8l9…`, and the board is off for the
night): band=a + fallback profile, no regdom param, no udev `RUN+=` rule, cage
watchdog polling fix, `systemd.settings.Manager` watchdog rename, brcmfmac
deferral.

**Uncommitted working tree** — matches the deployed generation:

```
 M hosts/rpi5.nix              (+103)
 M modules/kiosk.nix            (+52)
 M modules/wifi.nix            (+252)
 M scripts/wifi-provision.sh    (+63)
```

**Unpushed commits:** `d4b8bb3`, `fe311fb`, `6783c25`.

**Scratch data** (session dir, will not survive indefinitely — copy anything
worth keeping): `serial.log` (all boots, continuous), `results.tsv`,
`results-with-regdom.tsv`, `results-udev-rule-present.tsv`, `cycle.sh`,
`serialcap.py`.

---

## 6. Plan for tomorrow

Ordered so that the highest-value, lowest-risk work happens first, and so the
hang investigation runs against a clean image rather than one with an installer
profile in it.

### Phase 0 — hygiene (30 min, no hardware needed)

1. Revert the brcmfmac deferral in `hosts/rpi5.nix` (disproved, adds variables).
   Keep the death-window evidence as a comment or move it here.
2. Decide what to commit. Suggested split: (a) band preference + fallback
   profile, (b) udev `RUN+=` removal, (c) cage watchdog polling fix, (d)
   watchdog option rename. Each message should state what was *measured*, and
   should not claim the hang is fixed.
3. Correct `modules/base.nix`'s "no password anywhere" comment, which is false
   while the installer profile is present.
4. Update the `rpi5-boot-hangs-unsolved` memory: the six "disproved theories"
   list is misleading, because every one of those experiments was run with the
   udev rule in place and without continuous serial capture.

### Phase 1 — get the installer profile out of the image

**Hypothesis:** the image should not contain an installer profile at all. It
brings a random root password set on every activation, an autologin root getty
on tty1, the tor status screen, and `PermitRootLogin = yes`.

`hosts/rpi5.nix` already fights this piecemeal (lines ~46–61 disable ZFS, root
SSH, its networking; ~100–104 disable tor and the announce unit). That is
whack-a-mole against a module we do not want.

Tasks:
1. Find out whether `nixos-raspberrypi` can produce a non-installer SD image.
   `flake.nix` (~line 313) notes the image comes from the `sdimage-installer`
   module and "mirrors nixos-raspberrypi's own installerImages" — establish
   whether a plain `sdImage` path exists.
2. If it does not, neutralise explicitly and assert it stays neutralised:
   - `system.activationScripts.root-password = lib.mkForce ""`
   - no autologin getty on tty1 (`services.getty.autologinUser = null`, and stop
     `getty@tty1` from being wanted — cage owns that VT)
   - drop the `network-status` display
3. Add a build-time assertion that root has no password, so this cannot
   regress silently.

**Falsification / done when:** freshly flashed image has no root password set,
no getty on tty1, and the tabletop shows the kiosk rather than a login box.

**Watch for:** `cage_restarts` going to 0. If removing the getty fixes the cage
restarts, that is a second real bug closed, and it means the kiosk watchdog has
been masking a VT-ownership conflict this whole time.

### Phase 2 — the hang, against the cleaned image

Re-measure the baseline first: **20 cold boots on the Phase 1 image**, using
`cycle.sh` (with the `grep -ac` fix). It is possible Phase 1 changes this on its
own, since removing the getty removes one contender for the console.

Then, one variable at a time, 20 boots each:

**Experiment A — take the kernel console off the framebuffer.**
Drop `console=tty1` from `boot.kernelParams`, keep `console=serial0`.
*Predicts:* if the deadlock is in the fbcon handover, hangs stop, or a panic
finally prints on serial.
*Cost:* no kernel messages on the HDMI screen. Cosmetic.

**Experiment B — remove plymouth.**
`boot.plymouth.enable = false`, drop `splash`.
*Predicts:* if the handover plymouth performs is the trigger, hangs stop.
*Cost:* no boot splash.

**Experiment C — capture what the console cannot report.**
This is the one that converts the hang from silent to diagnosable, and it is
worth doing **before** A and B if either of them comes back inconclusive:

- Configure **ramoops/pstore** so a panic or oops survives the reset. The
  system already has `systemd-pstore.service`; the RPi5 needs a `ramoops`
  reserved-memory node in the device tree or `ramoops.mem_address=` parameters.
- Add `boot.kernelParams`: `hung_task_panic=1`, `hung_task_timeout_secs=30`,
  `softlockup_panic=1`, `panic=10`.
  *Predicts:* if the CPU is alive but blocked on a lock, the hung-task detector
  fires at 30s and — with pstore — we get the blocked task and its stack after
  the reboot, which names the lock and ends the guessing.

**Experiment D — only if A/B/C all come back clean.**
Boot headless (HDMI unplugged) for 20 cycles. If hangs vanish with no display,
the fault is in display bring-up regardless of which layer. If they persist with
no display at all, the console theory is dead and the next suspect is SDIO/mmc
contention during coldplug.

### Phase 3 — finish the kiosk work

Deferred tonight, still outstanding:

- Confirm the cage watchdog polling fix actually removes the per-boot restart
  (it is deployed but was never measured against a clean image).
- The panel modesets at 2560x1440@70Hz while `modes` also lists 3840x2160 —
  worth checking that this is the intended mode for this table.
- `tabletop-wait-clock` gates the kiosk on time sync because the Pi has **no RTC
  battery** (`rpi-rtc: setting system clock to 1970-01-01`). This is correct, but
  it means ~18s of every boot is waiting for the network. If that matters, an
  RTC battery is a hardware fix worth more than any config change.

### Method rules for tomorrow

1. `grep -a` on any captured log, always.
2. Validate every counter against the raw data once before trusting it.
3. No fix claimed under 20 consecutive clean boots.
4. Change one variable per run.
5. Start the serial capture before the first reboot, and leave it running.

---

## 7. Open questions

- Does `nixos-raspberrypi` offer a non-installer image path, or must the
  installer profile be neutralised in place?
- Is the 2.4GHz failure a property of this room, or of the Pi 5's radio next to
  a 2560x1440 HDMI link? Untested, and it does not block anything — 5GHz works —
  but it would be good to know before this image goes on a second board.
- Why did one watchdog recovery take 4m34s when others took ~85s?
