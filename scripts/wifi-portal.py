#!/usr/bin/env python3
"""Local WiFi setup portal for the tabletop kiosk.

Serves a touch-friendly page on 127.0.0.1 that lists nearby networks, takes a
passphrase, writes the credentials file the rest of this repo already expects,
and asks the existing units to provision and connect.

Deliberately narrow, because this runs as root:

  - binds loopback only, so nothing off-device can reach it;
  - shells out with argument lists, never a shell string;
  - validates ssid/psk before they reach a file or a command line;
  - writes the same wifi.conf that scripts/wifi-provision.sh reads, so there is
    one credential path on this device rather than two.

Environment: TABLETOP_WIFI_FILE, TABLETOP_PORTAL_HTML, TABLETOP_PORTAL_PORT,
TABLETOP_LAUNCHER_URL.
"""

import json
import os
import re
import subprocess
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

WIFI_FILE = os.environ.get("TABLETOP_WIFI_FILE", "/boot/firmware/wifi.conf")
HTML_FILE = os.environ["TABLETOP_PORTAL_HTML"]
PORT = int(os.environ.get("TABLETOP_PORTAL_PORT", "8080"))
LAUNCHER = os.environ.get("TABLETOP_LAUNCHER_URL", "about:blank")

# A control character in either field would corrupt the ini file or the keyfile
# derived from it. Length caps are the standard maxima.
BAD = re.compile(r"[\x00-\x1f\x7f]")


def run(args, timeout=25):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        return 1, "", str(e)


def scan():
    """Nearby networks, strongest first, one entry per SSID."""
    run(["nmcli", "device", "wifi", "rescan"], timeout=20)
    rc, out, _ = run(
        ["nmcli", "-t", "-f", "SSID,SIGNAL,SECURITY", "device", "wifi", "list"]
    )
    seen, nets = set(), []
    for line in out.splitlines():
        # nmcli -t escapes literal colons as \:  — unescape after splitting.
        parts = re.split(r"(?<!\\):", line)
        if len(parts) < 3:
            continue
        ssid = parts[0].replace("\\:", ":")
        if not ssid or ssid in seen:
            continue
        seen.add(ssid)
        try:
            signal = int(parts[1])
        except ValueError:
            signal = 0
        nets.append(
            {"ssid": ssid, "signal": signal, "secure": parts[2].strip() not in ("", "--")}
        )
    nets.sort(key=lambda n: -n["signal"])
    return nets


def connected():
    rc, out, _ = run(["nmcli", "-t", "-f", "DEVICE,STATE", "device"], timeout=8)
    return any(
        l.startswith("wl") and l.endswith(":connected") for l in out.splitlines()
    )


def write_credentials(ssid, psk):
    """Write the same ini file scripts/wifi-provision.sh consumes.

    The target is a FAT partition, so the 0600 is aspirational — FAT carries no
    permissions. That is a property of the existing bootstrap design, not
    something introduced here: this file has to be readable by a laptop with no
    network, which is the whole reason it exists.
    """
    tmp = WIFI_FILE + ".tmp"
    body = "ssid = %s\n" % ssid
    if psk:
        body += "psk = %s\n" % psk
    old = os.umask(0o077)
    try:
        with open(tmp, "w") as f:
            f.write(body)
        os.replace(tmp, WIFI_FILE)
    finally:
        os.umask(old)


def clock_synced():
    """systemd-timesyncd drops this the moment it accepts a sample."""
    return os.path.exists("/run/systemd/timesync/synchronized")


def wait_for_clock(timeout=90):
    """Get the clock right before sending the browser to an HTTPS page.

    This is not optional politeness, it is the bug that made the first working
    version of this portal useless. Joining a network from here succeeds, the
    page redirects to the launcher, and Chromium refuses it: the Pi has no RTC
    battery, so the clock is still at the epoch and every certificate looks
    invalid. On a kiosk with no keyboard there is no way past that interstitial,
    and the only recovery was a reboot — which worked purely because the boot
    path already sequences this correctly.

    Same kick as tabletop-wait-clock uses, and for the same reason: timesyncd
    starts before there is a network, backs off, and would otherwise keep us
    waiting on the backoff rather than the sync.
    """
    if clock_synced():
        return True
    run(["systemctl", "try-restart", "systemd-timesyncd.service"], timeout=20)
    for _ in range(timeout):
        if clock_synced():
            return True
        time.sleep(1)
    return False


def provision_and_connect():
    """Reuse the existing units rather than duplicating their logic."""
    run(["systemctl", "restart", "tabletop-wifi-provision.service"], timeout=40)
    run(["systemctl", "restart", "tabletop-wifi-connect.service"], timeout=90)
    for _ in range(20):
        if connected():
            return True
        time.sleep(1)
    return False


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass  # journal gets our own messages; drop the access log

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            with open(HTML_FILE, "rb") as f:
                self._send(200, f.read(), "text/html; charset=utf-8")
        elif self.path == "/api/scan":
            self._send(200, json.dumps(scan()))
        elif self.path == "/api/status":
            self._send(200, json.dumps({"connected": connected(), "launcher": LAUNCHER}))
        else:
            self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        if self.path != "/api/connect":
            self._send(404, json.dumps({"error": "not found"}))
            return
        try:
            n = int(self.headers.get("Content-Length", "0"))
            if n > 4096:
                raise ValueError("request too large")
            req = json.loads(self.rfile.read(n) or b"{}")
            ssid = str(req.get("ssid", ""))
            psk = str(req.get("psk", ""))
        except Exception:
            self._send(400, json.dumps({"error": "malformed request"}))
            return

        if not ssid or len(ssid) > 32 or BAD.search(ssid):
            self._send(400, json.dumps({"error": "invalid network name"}))
            return
        if psk and (len(psk) < 8 or len(psk) > 63 or BAD.search(psk)):
            self._send(400, json.dumps({"error": "invalid password"}))
            return

        print("portal: provisioning %r" % ssid, flush=True)
        try:
            write_credentials(ssid, psk)
        except OSError as e:
            self._send(
                200, json.dumps({"connected": False, "error": "could not save: %s" % e})
            )
            return

        ok = provision_and_connect()
        if not ok:
            print("portal: failed to connect", flush=True)
            self._send(
                200,
                json.dumps(
                    {
                        "connected": False,
                        "launcher": LAUNCHER,
                        "error": "Could not join that network.",
                    }
                ),
            )
            return

        synced = wait_for_clock()
        print(
            "portal: connected, clock %s"
            % ("synchronised" if synced else "NOT synchronised"),
            flush=True,
        )
        self._send(
            200,
            json.dumps(
                {
                    "connected": True,
                    "clock": synced,
                    "launcher": LAUNCHER,
                    # Redirecting with a wrong clock lands on a certificate
                    # error nobody can dismiss. Say so instead.
                    "error": None
                    if synced
                    else "Connected, but the clock did not synchronise, so secure "
                    "sites will not load. Check that this network allows NTP.",
                }
            ),
        )


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
