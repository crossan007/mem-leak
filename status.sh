#!/usr/bin/env bash
# One-shot, read-only status snapshot for the memwatch investigation.
# Gathers everything a "check status" review needs in a single run (no root needed).
# Usage: ./status.sh            (optionally: ./status.sh | tee status-$(date +%F-%H%M).txt)
set -uo pipefail

LOGDIR="${XDG_STATE_HOME:-${HOME}/.local/state}/memwatch"
BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
CSV="${LOGDIR}/memwatch-${BOOT_ID}.v2.csv"
ALERTS="${LOGDIR}/memwatch-${BOOT_ID}.alerts"
MY_UID=$(id -u)
PS_FD_ALERT_PCT=80

section() { printf '\n=== %s ===\n' "$1"; }

section "System"
date '+%F %T %Z'
echo "uptime: $(uptime -p)   boot: $(uptime -s)   boot_id: ${BOOT_ID}"
echo "kernel: $(uname -r)"
head -1 /proc/driver/nvidia/version 2>/dev/null | sed 's/  */ /g'

section "Monitor service"
systemctl --user show memwatch.service -p ActiveState -p SubState -p ActiveEnterTimestamp -p MainPID -p NRestarts 2>&1 | paste -sd' '
if cmp -s ~/.local/bin/memwatch.sh <(sed -n "/<<'EOF'/,/^EOF\$/p" "$(dirname "$0")/memwatch-service.sh" | sed '1d;$d') 2>/dev/null; then
  echo "installed script: matches memwatch-service.sh"
else
  echo "installed script: DIFFERS from memwatch-service.sh (re-run installer + restart service)"
fi

section "Alerts (this boot; TREND lines summarised)"
if [[ -f "$ALERTS" ]]; then
  grep -v 'TREND' "$ALERTS" | tail -20
  echo "TREND lines: $(grep -c 'TREND' "$ALERTS")   last 3:"
  grep 'TREND' "$ALERTS" | tail -3 | sed 's/^/  /'
else
  echo "no alerts file: $ALERTS"
fi

section "CSV timeline (24-column rows; first, ~hourly, last)"
if [[ -f "$CSV" ]]; then
  # Columns: 1 ts,2 MemAvailable,4 Cached,6 SUnreclaim,10 AnonPages,11 SwapTotal,12 SwapFree,
  # 14 Locked,15 Greeter,16 DeckVm,17 PsPid,18 PsFds,19 PsSync,20 PsLimit,21 SysOpen,22 UserSync,23 Dmabufs,24 GpuMiB
  awk -F, 'NF==24 && $1!="ts"' "$CSV" > "${TMPDIR:-/tmp}/memwatch-status.$$"
  ROWS="${TMPDIR:-/tmp}/memwatch-status.$$"
  trap 'rm -f "$ROWS"' EXIT
  echo "rows: $(wc -l < "$ROWS") (30 s each)   file: $CSV"
  awk -F, -v n="$(wc -l < "$ROWS")" '
    function g(k) { return sprintf("%6.2f", k/1048576) }
    BEGIN { printf "%-19s %6s %6s %6s %6s %6s  L G D  %5s %5s %5s %6s %5s\n",
            "ts","Avail","SUnrec","Anon","Cache","SwapU","PsFd","PsSyn","UsSyn","SysOpn","GpuMi" }
    NR==1 || NR==n || NR%120==1 {
      printf "%-19s %s %s %s %s %s  %s %s %s  %5s %5s %5s %6s %5s\n",
        $1, g($2), g($6), g($10), g($4), g($11-$12), ($14==""?"-":$14), $15, $16, $18, $19, $22, $21, $24 }
  ' "$ROWS"

  section "Rates"
  last=$(tail -1 "$ROWS")
  IFS=, read -r -a L <<< "$last"
  ps_pid=${L[16]}
  # Rows at ~1 h ago and first row with the current plasmashell PID (rates reset on restart).
  hour=$(tail -121 "$ROWS" | head -1)
  ps_first=$(awk -F, -v p="$ps_pid" '$17==p {print; exit}' "$ROWS")
  first=$(head -1 "$ROWS")
  rate() {  # rate <row_a> <col_index0> <scale> -> per-hour change from row_a to last
    local a="$1" c="$2" s="$3" ta tb va vb
    IFS=, read -r -a A <<< "$a"
    ta=$(date -d "${A[0]}" +%s); tb=$(date -d "${L[0]}" +%s)
    (( tb > ta )) || { echo "n/a"; return; }
    va=${A[$c]:-0}; vb=${L[$c]:-0}
    awk -v a="$va" -v b="$vb" -v dt=$((tb-ta)) -v s="$s" 'BEGIN { printf "%+.1f/h (over %.1f h)", (b-a)/s/dt*3600, dt/3600 }'
  }
  echo "SUnreclaim MiB:   last hour $(rate "$hour" 5 1024)   since first $(rate "$first" 5 1024)   (leak night: ~+940/h)"
  echo "AnonPages MiB:    last hour $(rate "$hour" 9 1024)"
  echo "plasmashell fds:  $(rate "$ps_first" 17 1) since pid ${ps_pid} first seen; now ${L[17]}/${L[19]}"
  echo "plasmashell sync: $(rate "$ps_first" 18 1); now ${L[18]}"
  echo "user sync_files:  last hour $(rate "$hour" 21 1); now ${L[21]}"
  # Projection to the plasmashell fd alert and hard limit, from the per-PID fd rate.
  IFS=, read -r -a P <<< "$ps_first"
  awk -v a="${P[17]}" -v b="${L[17]}" -v lim="${L[19]}" -v pct="$PS_FD_ALERT_PCT" \
      -v dt=$(( $(date -d "${L[0]}" +%s) - $(date -d "${P[0]}" +%s) )) -v now="$(date -d "${L[0]}" +%s)" '
    BEGIN {
      if (dt <= 0 || b <= a || lim == "") { print "plasmashell projection: n/a"; exit }
      r = (b-a)/dt; alert = lim*pct/100
      ta = now + (alert-b)/r; tl = now + (lim-b)/r
      ("date -d @" int(ta) " +%a\\ %H:%M") | getline sa; ("date -d @" int(tl) " +%a\\ %H:%M") | getline sl
      printf "plasmashell projection: %d-fd alert ~%s, %d limit ~%s\n", alert, (b>=alert?"now":sa), lim, sl
    }'
else
  echo "no CSV: $CSV"
fi

section "Live /proc/meminfo"
grep -E '^(MemTotal|MemAvailable|Cached|AnonPages|Slab|SUnreclaim|SReclaimable|SwapTotal|SwapFree):' /proc/meminfo \
  | awk '{ printf "%-14s %7.2f GiB\n", $1, $2/1048576 }'

section "Top 8 processes by RSS"
ps -eo pid,rss,args --sort=-rss --no-headers | head -8 \
  | awk '{ a=""; for (i=3;i<=NF;i++) a=a" "$i; printf "%7d %6.2f GiB %.90s\n", $1, $2/1048576, a }'

section "Top sync_file / dmabuf holders (uid ${MY_UID})"
for d in /proc/[0-9]*; do
  [[ -O "$d" ]] || continue
  s=$(find "$d/fd" -maxdepth 1 -lname 'anon_inode:sync_file' 2>/dev/null | wc -l)
  m=$(find "$d/fd" -maxdepth 1 -lname '*dmabuf*' 2>/dev/null | wc -l)
  (( s + m > 0 )) || continue
  f=$(find "$d/fd" -maxdepth 1 -type l 2>/dev/null | wc -l)
  lim=$(awk '/Max open files/ {print $4}' "$d/limits" 2>/dev/null)
  printf '%s\t%6s %-16s sync=%-5s dmabuf=%-5s fds=%s/%s\n' "$s" "${d#/proc/}" "$(cat "$d/comm" 2>/dev/null)" "$s" "$m" "$f" "$lim"
done | sort -nr -k1,1 | cut -f2- | head -10

section "Session"
sid=$(loginctl show-user "$MY_UID" -p Display --value 2>/dev/null)
echo "session ${sid:-?}: LockedHint=$(loginctl show-session "$sid" -p LockedHint --value 2>/dev/null)" \
     " greeter=$(pgrep -u "$MY_UID" -x kscreenlocker_g >/dev/null && echo 1 || echo 0)" \
     " deck-vm=$(pgrep -u "$MY_UID" -x krfb-virtualmon >/dev/null && echo 1 || echo 0)" \
     " sunshine=$(systemctl --user is-active sunshine.service 2>/dev/null || echo ?)"
echo "file-nr: $(cat /proc/sys/fs/file-nr)"
