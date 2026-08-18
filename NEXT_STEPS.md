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

**Working tree is clean.** Phase 0 is done — see §6.

**Unpushed commits** (7; nothing has been pushed to origin):

```
20e227f  Record what the boot hang is not, and correct a false claim about passwords
14e046e  Stop the kiosk watchdog restarting a compositor that was about to work
3a9d410  Use the current names for the watchdog options
dca46cb  Fix the WiFi for real: prefer 5GHz, because 2.4GHz cannot associate
6783c25  Let the watchdog clear the Raspberry Pi's boot hang
fe311fb  Cut 23s from boot: win the power-save race, and stop waiting on backoff
d4b8bb3  Fix the WiFi that never associated: disable power save
```

Each of the four new ones was built individually; all four evaluate clean.

**The board is out of date with the repo.** It is still running generation
`fx7ja8l9…`, which contains the brcmfmac deferral that this repo no longer has.
First action tomorrow, once the Pi is on, is a deploy — that alone changes the
board, so take the Phase 2 baseline *after* it, not before.

**Scratch data** (session dir, will not survive indefinitely — copy anything
worth keeping): `serial.log` (all boots, continuous), `results.tsv`,
`results-with-regdom.tsv`, `results-udev-rule-present.tsv`, `cycle.sh`,
`serialcap.py`.

---

## 6. Plan for tomorrow

Ordered so that the highest-value, lowest-risk work happens first, and so the
hang investigation runs against a clean image rather than one with an installer
profile in it.

### Phase 0 — hygiene — **DONE**

1. ~~Revert the brcmfmac deferral.~~ Done. The blacklist entry and the
   `tabletop-wifi-driver` unit are gone; the death-window evidence stayed as a
   comment in `hosts/rpi5.nix` so the experiment is not repeated.
2. ~~Commit the work.~~ Done, in four commits (§5). One deviation from the
   suggested split: the udev `RUN+=` removal went in *with* the band commit
   rather than separately. Its whole justification is "nothing needs it now,
   because band=a", and both edits land in one contiguous region of
   `modules/wifi.nix` — splitting them would have produced an intermediate
   commit whose comments contradicted its own code.
3. ~~Correct `modules/base.nix`.~~ Done, and expanded: the comment now says what
   the installer profile actually does and points at Phase 1, rather than just
   deleting the false claim.
4. ~~Update the memory.~~ Done. `rpi5-boot-hangs-unsolved` rewritten around the
   350ms window, with the "six disproved theories" list explicitly discredited
   and the known-good-card experiment retracted. Added
   `tabletop-rpi5-installer-profile` and a note on requiring a hypothesis per
   experiment.

### Phase 1 — get the installer profile out of the image — **DONE (needs hardware to confirm)**

A non-installer path existed. `nixos-raspberrypi.lib.nixosInstaller` is exactly
`nixosSystemFull` + `nixosModules.sd-image` + `modules/installer/raspberrypi-installer.nix`,
and that last one imports nixpkgs' `profiles/installation-device.nix`. `flake.nix`
now uses `nixosSystemFull` + `sd-image` and drops both installer layers.

Verified on the evaluated config: no `root-password` activation script,
`getty.autologinUser = null`, root has `hashedPassword`, `initialHashedPassword`
and `password` all null, `tor.enable = false`, and the getty wrapper no longer
passes `--autologin root`. `hidden-ssh-announce.service` is gone from the system
rather than masked. Closure 5.17 → 4.65 GiB. The SD image builds and lands at
`sd-image/tabletop-os-rpi5.img.zst`, which is what `scripts/burn.sh` looks for.

Six of the seven `lib.mkForce` overrides in `hosts/rpi5.nix` were removable —
firewall, PermitRootLogin, `systemd.network.enable`, `useNetworkd`, `iwd` and
`networking.wireless.enable` all reach the right values with no override. **One
was not, and its comment was wrong:** ZFS is not from the installer profile. It
comes from nixos-raspberrypi's own full config, and dropping the override
brought back twenty `zfs-*` units. Kept, with the correct attribution.

Three assertions now fail the build if any of it returns, and each was checked
by injecting the violation rather than assumed to work:

```
users.users.root.initialHashedPassword  ->  FIRED
services.getty.autologinUser = "root"   ->  FIRED
services.tor.enable = true              ->  FIRED
```

They assert the facts, not the absence of an import path, so a rename cannot
slip past them.

**Correction to the hypothesis this phase was partly built on:**
`cage-tty1.service` already declares `Conflicts=getty@tty1.service`, so systemd
was handling the VT handover and the getty was never simply stealing it. What
changed is that tty1 now hosts a plain getty that cage conflicts away, instead
of an autologin root session actively painting a status box onto the
framebuffer. That weakens the "getty explains the cage restarts" idea without
killing it — it is a Phase 2 measurement, not a claim.

**Still unconfirmed on hardware:** that the board boots this image at all, that
the kiosk still comes up, and whether `cage_restarts` changes. Deploy and
measure before believing any of it.

<details>
<summary>Original Phase 1 plan, for reference</summary>

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

</details>

### Phase 2 — the hang — **DONE as far as measurement can take it**

Ran 2026-08-18, ~150 cold boots. The plan's experiments A/B/C/D were largely
superseded once instrumentation started working; what follows is what actually
happened and where it stopped.

**Localised to vc4.** Four cells, 71 boots:

| vc4 | v3d | boots | hangs | rate |
|:---:|:---:|---:|---:|---:|
| out | out | 15 | 0 | 0% |
| out | in | 5 | 0 | 0% |
| in | out | 7 | 2 | 29% |
| in | in | 44 | 25 | 57% |

**Narrowed to the HPD interrupt path.** With `drm.debug=0x06` plus
`boot.consoleLogLevel = 8`, 10 of 10 hangs ended on `drm_connector_helper_hpd_irq_event`,
preceded by an EDID re-read and a connector-state change. An HPD interrupt
arrives during bring-up, `detect()` re-reads EDID over the DDC I2C controller,
and the SoC dies inside it.

**Eight theories falsified by measurement.** Undervoltage/power, brcmfmac,
console_lock deadlock, framebuffer handover, display output, blocked-but-alive
kernel, connector polling, fbdev client atomic commit. The last two were
proposed fixes of mine, deployed and rejected the same afternoon. Details in
the memory note `rpi5-boot-hangs-unsolved` and in commits `17669a4`, `0296b74`,
`29b2985`, `698eb52`.

**The methodological finding worth keeping:** death *time* is not the signal. It
moved 8.9s → 9.3s → 22.2s across configurations while always staying a tight
cluster, which repeatedly suggested "time-locked" and was repeatedly wrong. What
is stable is the **progress count**. Five hangs once shared a byte-identical
signature `(2, 32, 20, 0)` while their death times spread over two seconds.

**Four settings that were accepted and did nothing** — verify the effect, never
that the setting took: `hung_task_timeout_secs=` (sysctl only, not a boot
param), `systemd-udev-settle.service` (does not exist here), `vc4.dyndbg=+p`
(one callsite; DRM uses `drm_dbg_*()`), and `drm.debug` without
`consoleLogLevel = 8` (journal only, and the journal dies with the board).

### Phase 3 — what is left

1. **File upstream** against nixos-raspberrypi / vc4. Nothing in this repo
   touches HPD handling. There is a 40% reproducer, a named function, and 20MB
   of clean serial captures in `~/projects/games/tabletop/rpi5-hang-data/`.
2. **Try `video=HDMI-A-1:2560x1440@70e`** — force the mode so `detect()` has
   less influence. The last cheap local mitigation in sight.
3. **Consider shipping on the watchdog.** It has recovered 40+ hangs without a
   single failure. A tabletop that occasionally takes an extra 85s is a working
   appliance.
4. **Revisit "boot-time power smoothing" in `hosts/rpi5.nix`.** The
   `cpufreq.default_governor=powersave` cap, the Bluetooth blacklist and the Tor
   removal all rest on undervoltage measurements that no surviving log supports
   — `in0_lcrit_alarm` reads 0 and no captured log contains an undervoltage
   line. The cap costs real boot time and the actual cause is now known.
5. **Remove the experiment scaffolding** currently deployed:
   `drm.debug=0x06`, `boot.consoleLogLevel = 8`, `fbdev_emulation=0`, and the
   C0 panic settings. `fbdev_emulation=0` is kept only as a cleaner reproducer;
   it is not a fix and the kiosk does not need it either way.

### Method rules — unchanged and still earning their place

1. `grep -a` on any captured log, always.
2. Validate every counter against the raw data once before trusting it.
3. No fix claimed under 20 consecutive clean boots.
4. Change one variable per run.
5. Start the serial capture before the first reboot, and leave it running.
6. **Verify a setting had its intended effect on the target, not that it was
   accepted.** Four inert knobs in one day.

---

## 7. Open questions

- Why does an HPD interrupt during bring-up kill all cores rather than erroring?
  Needs someone who can read vc4's DDC/I2C and PHY paths.
- Is the 2.4GHz association failure a property of this room or of the Pi 5's
  radio beside a high-pixel-clock HDMI link? Unblocked either way — 5GHz works.
- The RPi5 has no RTC battery, so wall-clock timestamps within a boot are
  unreliable until timesync. Only `journalctl -o short-monotonic` and
  `/proc/uptime` can be trusted on this board.
