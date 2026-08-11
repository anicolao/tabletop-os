# Drive the kiosk's browser over Chrome DevTools Protocol, from this machine.
#
# The kiosk has no keyboard, no address bar, and no reachable chrome:// pages,
# so this is the only way to ask it what it is rendering or make it do
# something. It opens an SSH tunnel to the board's loopback-bound DevTools port
# and speaks CDP over it.
#
# Ground truth still comes from scripts/screenshot.sh and scripts/photo.sh —
# this tells you about the page, those tell you what reached the panel.
#
# TABLETOP_HOST and TABLETOP_CDP_PORT are substituted by flake.nix.

host="${TABLETOP_HOST}"
port="${TABLETOP_CDP_PORT}"
base="http://127.0.0.1:${port}"

die() { echo "$*" >&2; exit 1; }

# One tunnel per port, reused across invocations. Without -o ExitOnForwardFailure
# a second attempt would appear to succeed while forwarding nothing.
ensure_tunnel() {
  if curl -s --max-time 3 "$base/json/version" >/dev/null 2>&1; then
    return 0
  fi
  ssh -f -N -o ExitOnForwardFailure=yes -L "${port}:127.0.0.1:${port}" "$host" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -s --max-time 3 "$base/json/version" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  die "no DevTools on $host:$port.
Is the kiosk actually running? A wedged kiosk has no browser to talk to:
  ssh $host 'pgrep -c chromium'   # 4 means wedged, 10 means healthy
  ssh $host 'sudo systemctl restart cage-tty1'
Is the port enabled? hosts/<board>.nix needs tabletop.kiosk.remoteDebuggingPort."
}

browser_ws() { curl -s "$base/json/version" | jq -r .webSocketDebuggerUrl; }

# Pick the launcher tab, not the diagnostic tab. Matching on type=="page" alone
# would also catch the status page and, depending on ordering, profile the wrong
# document entirely.
page_ws() {
  local pat="${TABLETOP_PAGE_MATCH:-ttlauncher}"
  local ws
  ws=$(curl -s "$base/json/list" \
    | jq -r --arg p "$pat" '[.[] | select(.type=="page") | select(.url|test($p))][0].webSocketDebuggerUrl')
  if [ -z "$ws" ] || [ "$ws" = "null" ]; then
    ws=$(curl -s "$base/json/list" | jq -r '[.[] | select(.type=="page")][0].webSocketDebuggerUrl')
  fi
  [ -n "$ws" ] && [ "$ws" != "null" ] || die "no page target found (is the kiosk wedged?)"
  printf '%s' "$ws"
}

# websocat's default buffer is 64 KiB, and a CPU profile is far larger than
# that — it arrives truncated mid-object and jq reports "Unfinished JSON term
# at EOF". Everything here goes through this so no caller can forget.
WSCAT_BUF=33554432

# Single request/response.
send1() { printf '%s\n' "$2" | websocat -B "$WSCAT_BUF" -n1 "$1" 2>/dev/null; }

# A sequence of messages down one connection, with pauses between them. Needed
# for anything stateful — Profiler.start and Profiler.stop must share a session,
# and a fresh connection per message would lose it.
send_seq() {
  local ws="$1"; shift
  {
    while [ "$#" -gt 0 ]; do
      case "$1" in
        sleep:*) sleep "${1#sleep:}" ;;
        *) printf '%s\n' "$1" ;;
      esac
      shift
    done
    # Wait for the last reply before closing stdin. A CPU profile is hundreds of
    # kilobytes of JSON and arrives well after the request; closing early
    # truncates it mid-object and jq reports "Unfinished JSON term at EOF".
    sleep "${TABLETOP_CDP_DRAIN:-3}"
  } | websocat -B "$WSCAT_BUF" -t "$ws" 2>/dev/null
}

evaluate() {
  local expr="$1" ws
  ws=$(page_ws)
  send1 "$ws" "$(jq -nc --arg e "$expr" \
      '{id:1,method:"Runtime.evaluate",params:{expression:$e,awaitPromise:true,returnByValue:true}}')" \
    | jq -r 'if .result.exceptionDetails then
               ("EXCEPTION: " + (.result.exceptionDetails.exception.description // .result.exceptionDetails.text))
             else (.result.result.value // .result.result | tostring) end'
}

# Self time per function, which is what tells you where to optimise. The
# profile's own samples are authoritative; timeDeltas convert them to ms.
summarise_profile() {
  jq -r '
    . as $p
    | ($p.nodes | map({key: (.id|tostring), value: .}) | from_entries) as $byid
    | reduce range(0; ($p.samples|length)) as $i ({};
        . + { ($p.samples[$i]|tostring): ((.[$p.samples[$i]|tostring] // 0) + $p.timeDeltas[$i]) })
    | to_entries
    | map({fn: ($byid[.key].callFrame.functionName // "(anonymous)"),
           url: ($byid[.key].callFrame.url // ""),
           ms: (.value/1000)})
    | sort_by(-.ms) | .[:15]
    | .[] | "  \(.ms|floor)ms  \(.fn)  \(.url|split("/")|last)"' "$1"
}

cmd="${1:-help}"; shift 2>/dev/null || true

case "$cmd" in

  targets)
    ensure_tunnel
    curl -s "$base/json/list" | jq -r '.[] | "\(.type)\t\(.title // "-")\t\(.url)"'
    ;;

  gpu)
    # What is actually accelerated. This is the chrome://gpu answer, which is
    # otherwise unreachable on this device.
    ensure_tunnel
    send1 "$(browser_ws)" '{"id":1,"method":"SystemInfo.getInfo"}' \
      | jq -r '.result.gpu as $g
               | ($g.featureStatus | to_entries[] | "  \(.key|.[0:34])  \(.value)"),
                 ($g.devices[]? | "device: \(.deviceString // "") \(.driverVendor // "") \(.driverVersion // "")")'
    ;;

  eval)
    ensure_tunnel
    [ -n "${1:-}" ] || die "usage: eval '<javascript>'"
    evaluate "$1"
    ;;

  fps)
    # Frames actually delivered to the page, over N seconds. requestAnimationFrame
    # is driven by the compositor, so this measures the real pipeline rather than
    # a timer.
    ensure_tunnel
    secs="${1:-3}"
    evaluate "new Promise(r=>{let n=0,t0=performance.now();function f(){n++;if(performance.now()-t0<${secs}000)requestAnimationFrame(f);else r(JSON.stringify({fps:+(n*1000/(performance.now()-t0)).toFixed(1),seconds:${secs},w:innerWidth,h:innerHeight,dpr:devicePixelRatio}))}requestAnimationFrame(f)})"
    ;;

  tap)
    ensure_tunnel
    x="${1:?usage: tap X Y}"; y="${2:?usage: tap X Y}"
    ws=$(page_ws)
    tp="[{\"x\":$x,\"y\":$y,\"radiusX\":12,\"radiusY\":12,\"force\":1,\"id\":1}]"
    send_seq "$ws" \
      "$(jq -nc --argjson t "$tp" '{id:1,method:"Input.dispatchTouchEvent",params:{type:"touchStart",touchPoints:$t}}')" \
      "sleep:0.05" \
      "$(jq -nc '{id:2,method:"Input.dispatchTouchEvent",params:{type:"touchEnd",touchPoints:[]}}')" \
      | jq -c 'select(.id) | {id, error: (.error.message // "ok")}'
    ;;

  swipe)
    # A touch drag, interpolated. The tabletop is a touch device, so mouse
    # events are the wrong input to profile with — a UI that listens for
    # pointer/touch may not respond to them at all.
    ensure_tunnel
    x1="${1:?usage: swipe X1 Y1 X2 Y2 [steps] [ms]}"; y1="${2:?}"; x2="${3:?}"; y2="${4:?}"
    steps="${5:-20}"; ms="${6:-400}"
    ws=$(page_ws); delay=$(awk -v m="$ms" -v s="$steps" 'BEGIN{printf "%.3f", (m/1000)/s}')
    seq_args=""
    seq_args="$seq_args $(jq -nc --argjson x "$x1" --argjson y "$y1" \
      '{id:1,method:"Input.dispatchTouchEvent",params:{type:"touchStart",touchPoints:[{x:$x,y:$y,radiusX:12,radiusY:12,force:1,id:1}]}}')"
    i=1
    while [ "$i" -le "$steps" ]; do
      cx=$(awk -v a="$x1" -v b="$x2" -v i="$i" -v n="$steps" 'BEGIN{printf "%d", a+(b-a)*i/n}')
      cy=$(awk -v a="$y1" -v b="$y2" -v i="$i" -v n="$steps" 'BEGIN{printf "%d", a+(b-a)*i/n}')
      seq_args="$seq_args sleep:$delay $(jq -nc --argjson x "$cx" --argjson y "$cy" --argjson id "$((i+1))" \
        '{id:$id,method:"Input.dispatchTouchEvent",params:{type:"touchMove",touchPoints:[{x:$x,y:$y,radiusX:12,radiusY:12,force:1,id:1}]}}')"
      i=$((i+1))
    done
    seq_args="$seq_args $(jq -nc --argjson id "$((steps+2))" \
      '{id:$id,method:"Input.dispatchTouchEvent",params:{type:"touchEnd",touchPoints:[]}}')"
    # shellcheck disable=SC2086  # intentional word splitting: one arg per message
    send_seq "$ws" $seq_args | jq -sc '[.[] | select(.error)] as $e
      | if ($e|length)>0 then {errors:$e} else {swiped:true, messages:(length)} end'
    ;;

  profile-swipe)
    # Profile *while* interacting, in one CDP session.
    #
    # Two concurrent connections to the same page target do not work — the
    # second corrupts the first's message stream and Profiler.stop comes back
    # unparseable. So the touch events are sent down the same socket as the
    # profiler commands, between start and stop.
    ensure_tunnel
    x1="${1:?usage: profile-swipe X1 Y1 X2 Y2 [reps] [ms] [outfile]}"; y1="${2:?}"; x2="${3:?}"; y2="${4:?}"
    reps="${5:-3}"; ms="${6:-800}"; out="${7:-launcher-profile.cpuprofile}"
    steps=20
    ws=$(page_ws); delay=$(awk -v m="$ms" -v s="$steps" 'BEGIN{printf "%.3f", (m/1000)/s}')
    args="$(jq -nc '{id:1,method:"Profiler.enable"}')"
    args="$args $(jq -nc '{id:2,method:"Profiler.setSamplingInterval",params:{interval:100}}')"
    args="$args $(jq -nc '{id:3,method:"Profiler.start"}') sleep:0.3"
    n=10
    rep=1
    while [ "$rep" -le "$reps" ]; do
      # alternate direction so the UI is exercised both ways
      if [ $((rep % 2)) -eq 1 ]; then ax=$x1; ay=$y1; bx=$x2; by=$y2; else ax=$x2; ay=$y2; bx=$x1; by=$y1; fi
      args="$args $(jq -nc --argjson x "$ax" --argjson y "$ay" --argjson id "$n"         '{id:$id,method:"Input.dispatchTouchEvent",params:{type:"touchStart",touchPoints:[{x:$x,y:$y,radiusX:12,radiusY:12,force:1,id:1}]}}')"
      n=$((n+1)); i=1
      while [ "$i" -le "$steps" ]; do
        cx=$(awk -v a="$ax" -v b="$bx" -v i="$i" -v k="$steps" 'BEGIN{printf "%d", a+(b-a)*i/k}')
        cy=$(awk -v a="$ay" -v b="$by" -v i="$i" -v k="$steps" 'BEGIN{printf "%d", a+(b-a)*i/k}')
        args="$args sleep:$delay $(jq -nc --argjson x "$cx" --argjson y "$cy" --argjson id "$n"           '{id:$id,method:"Input.dispatchTouchEvent",params:{type:"touchMove",touchPoints:[{x:$x,y:$y,radiusX:12,radiusY:12,force:1,id:1}]}}')"
        n=$((n+1)); i=$((i+1))
      done
      args="$args $(jq -nc --argjson id "$n" '{id:$id,method:"Input.dispatchTouchEvent",params:{type:"touchEnd",touchPoints:[]}}') sleep:0.4"
      n=$((n+1)); rep=$((rep+1))
    done
    args="$args $(jq -nc '{id:9999,method:"Profiler.stop"}')"
    # shellcheck disable=SC2086  # intentional word splitting: one arg per message
    send_seq "$ws" $args | grep '"id":9999' | head -1 > "$out.raw"
    [ -s "$out.raw" ] || die "no profile returned (kiosk wedged mid-capture?)"
    jq '.result.profile' "$out.raw" > "$out" && rm -f "$out.raw"
    echo "wrote $out"
    summarise_profile "$out"
    ;;

  profile)
    # A JS CPU profile with per-function self time — the thing to look at when
    # frames are being missed because of main-thread work.
    ensure_tunnel
    secs="${1:-5}"; out="${2:-launcher-profile.cpuprofile}"
    ws=$(page_ws)
    send_seq "$ws" \
      '{"id":1,"method":"Profiler.enable"}' \
      '{"id":2,"method":"Profiler.setSamplingInterval","params":{"interval":100}}' \
      '{"id":3,"method":"Profiler.start"}' \
      "sleep:$secs" \
      '{"id":4,"method":"Profiler.stop"}' \
      | jq -c 'select(.id==4)' > "$out.raw"
    [ -s "$out.raw" ] || die "no profile returned (kiosk wedged mid-capture?)"
    jq '.result.profile' "$out.raw" > "$out" && rm -f "$out.raw"
    echo "wrote $out"
    summarise_profile "$out"
    ;;

  help|*)
    cat <<'USAGE'
usage: nix run .#cdp -- <command>

  targets                       list debuggable pages
  gpu                           what is hardware accelerated (chrome://gpu)
  fps [seconds]                 frames per second actually delivered
  eval '<js>'                   run JavaScript in the launcher, print result
  tap X Y                       synthetic touch tap (CSS pixels)
  swipe X1 Y1 X2 Y2 [steps] [ms]  synthetic touch drag
  profile [seconds] [outfile]   JS CPU profile + top functions by self time
  profile-swipe X1 Y1 X2 Y2 [reps] [ms] [out]
                                profile WHILE swiping, in one session

See docs/GRAPHICS-PERF.md.
USAGE
    ;;
esac
