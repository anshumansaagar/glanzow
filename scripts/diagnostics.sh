#!/bin/bash
# Collects Glanzow diagnostics into one text file on the Desktop, for tuning and bug reports.
# Numbers and text only: no camera images, no keystrokes, no window contents.
set -u
OUT="${GLANZOW_DIAG_OUT:-$HOME/Desktop/glanzow-diagnostics-$(date +%Y%m%d-%H%M).txt}"
SUPPORT="$HOME/Library/Application Support/Glanzow"
BUNDLE=dev.glanzow.Glanzow
APP_PID=$(pgrep -x Glanzow | head -1)

{
echo "# Glanzow diagnostics, $(date)"
echo
echo "## System"
sw_vers | tr '\n' ' '; echo
sysctl -n machdep.cpu.brand_string
system_profiler SPDisplaysDataType 2>/dev/null | grep -E "^ {8}[^ ].*:$|Resolution|UI Looks like|Main Display"
system_profiler SPCameraDataType 2>/dev/null | grep -E "^ {4}[^ ].*:$"
echo
echo "## App"
echo "running: ${APP_PID:-no}"
[ -n "${APP_PID:-}" ] && ps -o etime=,rss= -p "$APP_PID" | awk '{print "uptime " $1 ", memory " int($2/1024) " MB"}'
(cd "$(dirname "$0")/.." 2>/dev/null && git log -1 --format='build: commit %h, %ad, %s' --date=short 2>/dev/null)
echo
echo "## Settings"
defaults read "$BUNDLE" 2>/dev/null
echo
echo "## Calibration"
python3 - "$SUPPORT/calibration.json" <<'PY'
import json, math, sys
try: models = json.load(open(sys.argv[1]))["models"]
except Exception as e: print("no calibration:", e); sys.exit()
for m in models:
    c = m["covariance"]
    print(f"- {m['name']} ({m['key']}), {m['sampleCount']} samples, {m['calibratedAt']}")
    print(f"  head yaw {m['mean'][0]:+.1f}° ±{math.sqrt(c['xx']):.1f}, pitch {m['mean'][1]:+.1f}° ±{math.sqrt(c['yy']):.1f}, face scale {m['meanFaceScale']:.3f}")
    g = m.get("gaze")
    if not g: print("  gaze map: none (calibrated before window focus existed)"); continue
    he, ee = g["headError"], g.get("eyesError")
    line = f"  gaze map: head-only error {he*100:.1f}% of screen"
    if ee is not None:
        line += f", with eyes {ee*100:.1f}%, eyes improve it by {(1-ee/he)*100:.0f}%"
        e = g["eyes"]; line += f"; pupil weights x {e[0][3]:+.4f} {e[0][4]:+.4f}, y {e[1][3]:+.4f} {e[1][4]:+.4f}"
    print(line)
PY
echo
echo "## Switch log"
python3 - "$SUPPORT/events.jsonl" <<'PY'
import json, sys, statistics as st, collections, datetime as dt
try: rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
except Exception as e: print("no switch log:", e); sys.exit()
sw = [r for r in rows if r.get("event") == "switch"]
if not sw: print("no switches logged"); sys.exit()
t = [dt.datetime.fromisoformat(r["at"].replace("Z", "+00:00")) for r in sw]
hours = max((t[-1] - t[0]).total_seconds() / 3600, 1e-9)
print(f"{len(sw)} switches from {t[0]:%Y-%m-%d %H:%M} to {t[-1]:%H:%M} UTC ({len(sw)/hours:.1f} per hour)")
def pct(v, p): v = sorted(v); return v[min(len(v)-1, int(p * len(v)))]
for kind, group in (("screen", [r for r in sw if not r.get("region")]), ("window/pane", [r for r in sw if r.get("region")])):
    ok = [r for r in group if r["outcome"] != "skipped"]
    print(f"- {kind}: {len(ok)} done, {len(group)-len(ok)} skipped")
    for k in ("settleToFocusMs", "frameToFocusMs", "focusMs"):
        v = [r[k] for r in ok if k in r]
        if v: print(f"  {k}: median {st.median(v):.0f}, 90th percentile {pct(v, .9):.0f}, worst {max(v):.0f}")
    reasons = collections.Counter(r.get("reason", "") for r in group if r["outcome"] == "skipped")
    if reasons: print("  skipped because:", dict(reasons))
drift = [r for r in rows if r.get("event") == "drift"]
if drift: print(f"drift alerts: {len(drift)}")
print("\nlast 40 entries:")
for r in rows[-40:]: print(" ", json.dumps(r, sort_keys=True))
PY
echo
echo "## Processor and memory use over 60 seconds"
if [ -n "${APP_PID:-}" ]; then
  top -l 31 -s 2 -pid "$APP_PID" -stats pid,cpu,mem,power 2>/dev/null | awk -v p="$APP_PID" '
    $1 == p { n++; if (n > 1) { cpu += $2; pw += $4; c++ }; mem = $3 }
    END { if (c) printf "average CPU %.1f%% of one core, average energy impact %.1f, memory %s (%d samples)\n", cpu/c, pw/c, mem, c }'
else
  echo "Glanzow isn't running"
fi
echo
echo "## App log, last 2 hours"
log show --predicate 'subsystem == "dev.glanzow"' --last 2h --style compact 2>/dev/null | tail -300
} > "$OUT" 2>&1

echo "Wrote $OUT"
echo "It contains settings, calibration numbers, switch timings and app log lines; no images or keystrokes."
