# Make the tabletop able to describe itself.
#
# The device has no keyboard and its only display is the panel the kiosk owns.
# When something is wrong, the two questions are always "what is its IP" and
# "is the GPU actually being used", and neither is answerable from a blank
# console. This module answers both in two places:
#
#   - an HTML tab inside the browser, behind the launcher
#   - a console notice on tty1 while the kiosk restarts
#
# Both render the same script so they cannot drift.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.tabletop.status;
  kioskCfg = config.tabletop.kiosk;

  statusText = pkgs.writeShellApplication {
    name = "tabletop-status";
    runtimeInputs = with pkgs; [
      coreutils
      iproute2
      gnugrep
      gnused
      gawk
      procps
      nettools
      systemd
    ];
    text = ''
      TABLETOP_KIOSK_URL=${lib.escapeShellArg kioskCfg.url}
      export TABLETOP_KIOSK_URL
    ''
    + builtins.readFile ../scripts/status.sh;
  };

  # Deliberately plain. This is a diagnostic page, not part of the product, and
  # it must stay legible when the thing it is diagnosing is broken.
  statusHtml = pkgs.writeShellApplication {
    name = "tabletop-status-html";
    runtimeInputs = [
      statusText
      pkgs.coreutils
    ];
    text = ''
      out=/run/tabletop/status.html
      tmp="$out.tmp"
      {
        cat <<'HTML'
      <!doctype html>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <!-- Regenerated on a timer; reload to pick up address changes. -->
      <meta http-equiv="refresh" content="${toString cfg.refreshSeconds}">
      <title>tabletop status</title>
      <style>
        :root { color-scheme: dark; }
        body { background:#0b1a22; color:#cfe6ee; font:16px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace;
               margin:0; display:flex; align-items:center; justify-content:center; min-height:100vh; }
        main { padding:2rem; }
        h1 { font-size:1rem; letter-spacing:.25em; text-transform:uppercase; color:#7fd4c1; margin:2rem 0 1rem; }
        h1:first-child { margin-top:0; }
        pre { margin:0; font-size:1.1rem; }
        footer { margin-top:1.5rem; color:#5e8ea0; font-size:.85rem; }
      </style>
      <main>
      <h1>Tabletop status</h1>
      <pre>
      HTML
        tabletop-status
        cat <<'HTML'
      </pre>
      <h1>Graphics, as the browser sees it</h1>
      <pre id="gl">probing...</pre>
      <footer>Refreshes automatically. Ctrl+W closes this tab.</footer>
      </main>
      <script>
      // chrome://gpu cannot be opened from the command line — Chromium silently
      // drops chrome:// URLs given as arguments. This asks the same question in
      // the way that actually matters here: what renderer does WebGL get?
      //
      // "llvmpipe" or "SwiftShader" means everything is on the CPU and the
      // whole point of this board has been lost. On the Orange Pi expect
      // Mali-G610 via Panfrost; in the emulator llvmpipe is correct and normal.
      (function () {
        var out = [];
        function row(k, v) { out.push((k + "          ").slice(0, 10) + v); }
        var c = document.createElement("canvas");
        var gl = c.getContext("webgl2");
        var ver = "webgl2";
        if (!gl) { gl = c.getContext("webgl"); ver = "webgl1"; }
        if (!gl) {
          row("webgl", "UNAVAILABLE — no hardware or software renderer");
        } else {
          row("version", ver + "  " + gl.getParameter(gl.VERSION));
          var dbg = gl.getExtension("WEBGL_debug_renderer_info");
          if (dbg) {
            row("renderer", gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL));
            row("vendor", gl.getParameter(dbg.UNMASKED_VENDOR_WEBGL));
          } else {
            row("renderer", gl.getParameter(gl.RENDERER) + "  (masked)");
          }
          row("glsl", gl.getParameter(gl.SHADING_LANGUAGE_VERSION));
          row("texture", "max " + gl.getParameter(gl.MAX_TEXTURE_SIZE) + "px");
        }
        var s = out.join("\n");
        var r = /llvmpipe|swiftshader|softpipe/i.test(s)
          ? "\n\nSOFTWARE RENDERING — expected in the emulator, a bug on the board."
          : "";
        document.getElementById("gl").textContent = s + r;
      })();
      </script>
      HTML
      } > "$tmp"
      mv "$tmp" "$out"
    '';
  };

  # Shown on tty1 in the gap between the kiosk exiting and restarting. Without
  # this the panel goes to a blank VT with a cursor, which looks like a crash.
  restartNotice = pkgs.writeShellApplication {
    name = "tabletop-restart-notice";
    runtimeInputs = [
      statusText
      pkgs.coreutils
    ];
    text = ''
      tty=/dev/tty1
      [ -w "$tty" ] || exit 0
      {
        printf '\033[2J\033[H\033[?25l'
        printf '\033[1;36m  Tabletop kiosk is restarting\033[0m\n\n'
        tabletop-status | sed 's/^/  /'
        printf '\n  \033[2mThe launcher will reappear in a few seconds.\033[0m\n'
        printf '  \033[2mssh admin@%s\033[0m\n' "$(hostname 2>/dev/null || echo tabletop)"
      } > "$tty" 2>/dev/null || true
    '';
  };
in
{
  options.tabletop.status = {
    enable = lib.mkEnableOption "the self-describing status page and restart notice" // {
      default = true;
    };

    refreshSeconds = lib.mkOption {
      type = lib.types.int;
      default = 10;
      description = "How often the in-browser status page reloads itself.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ statusText ];

    systemd.services.tabletop-status = {
      description = "Regenerate the tabletop status page";
      serviceConfig = {
        Type = "oneshot";
        RuntimeDirectory = "tabletop";
        RuntimeDirectoryPreserve = true;
        ExecStart = lib.getExe statusHtml;
      };
      # Written before the kiosk starts, so the tab has content on first paint.
      wantedBy = [ "multi-user.target" ];
      before = [ "cage-tty1.service" ];
    };

    systemd.timers.tabletop-status = {
      description = "Keep the tabletop status page current";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10s";
        OnUnitActiveSec = "${toString cfg.refreshSeconds}s";
        AccuracySec = "1s";
      };
    };

    # `+` runs this as root regardless of the unit's User=kiosk, which is what
    # it takes to write to the console after the session has been torn down.
    systemd.services.cage-tty1.serviceConfig.ExecStopPost = [ "+${lib.getExe restartNotice}" ];
  };
}
