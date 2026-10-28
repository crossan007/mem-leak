#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_PATH="${HOME}/.local/bin/memwatch.sh"
UNIT_PATH="${HOME}/.config/systemd/user/memwatch.service"
LOGDIR="${XDG_STATE_HOME:-${HOME}/.local/state}/memwatch"
mkdir -p "$(dirname "$SCRIPT_PATH")" "$(dirname "$UNIT_PATH")" "$LOGDIR"

cat >"$SCRIPT_PATH" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

LOGDIR="${XDG_STATE_HOME:-${HOME}/.local/state}/memwatch"
mkdir -p "$LOGDIR"

BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
CSV="${LOGDIR}/memwatch-${BOOT_ID}.v2.csv"
ALERTS="${LOGDIR}/memwatch-${BOOT_ID}.alerts"
START_MARKER="${LOGDIR}/memwatch-${BOOT_ID}.start"
SAMPLE_SEC="${SAMPLE_SEC:-30}"
SLAB_ALERT="${SLAB_ALERT:-10000000}"
SUNRECLAIM_ALERT="${SUNRECLAIM_ALERT:-8000000}"
MEMAVAILABLE_ALERT="${MEMAVAILABLE_ALERT:-500000}"
TREND_DELTA="${TREND_DELTA:-2000000}"
TREND_GRACE_SEC="${TREND_GRACE_SEC:-300}"
# SUnreclaim is normally flat; sustained growth is the leak signature.
SUNRECLAIM_RATE_KIB="${SUNRECLAIM_RATE_KIB:-262144}"
SUNRECLAIM_RATE_WINDOW_SEC="${SUNRECLAIM_RATE_WINDOW_SEC:-1800}"
FD_ALERT_PCT="${FD_ALERT_PCT:-80}"
ALERT_REPEAT_SEC="${ALERT_REPEAT_SEC:-3600}"
# Hypothesis (unconfirmed): the slab leak needs the lock screen plus the Deck
# virtual output being streamed. Set to 0 to disable the reminder.
DECK_LOCK_ALERT="${DECK_LOCK_ALERT:-1}"
MY_UID="$(id -u)"
RATE_SAMPLES=$(( SUNRECLAIM_RATE_WINDOW_SEC / SAMPLE_SEC + 1 ))

if [ ! -f "$START_MARKER" ]; then
  echo "$(date '+%F %T') boot_id=${BOOT_ID} service_start" >> "$ALERTS"
  touch "$START_MARKER"
fi

read_kib() {
  local key="$1"
  awk -v k="$key" '$1 == k { print $2; exit }' /proc/meminfo
}

warn() {
  local msg="$1"
  local notify="${2:-yes}"

  logger -t memwatch "$msg"
  echo "$(date '+%F %T') $msg" >> "$ALERTS"

  if [ "$notify" = "yes" ] && command -v notify-send >/dev/null 2>&1; then
    notify-send -u critical "memwatch" "$msg" >/dev/null 2>&1 || true
  fi
}

declare -A alert_on=()
declare -A alert_last=()

# Notify when a condition first trips, remind every ALERT_REPEAT_SEC while it
# holds, and log (without notifying) when it clears.
latch() {
  local key="$1"
  local active="$2"
  local msg="$3"
  local now
  now=$(date +%s)

  if [ "$active" = "1" ]; then
    if [ "${alert_on[$key]:-0}" = "0" ]; then
      warn "ALERT: $msg" "yes"
      alert_on[$key]=1
      alert_last[$key]=$now
    elif [ $(( now - ${alert_last[$key]} )) -ge "$ALERT_REPEAT_SEC" ]; then
      warn "ALERT (ongoing): $msg" "yes"
      alert_last[$key]=$now
    fi
  elif [ "${alert_on[$key]:-0}" = "1" ]; then
    warn "CLEARED: ${key}: $msg" "no"
    alert_on[$key]=0
  fi
}

declare -a slab_hist=()
declare -a sun_hist=()
declare -a avail_hist=()
declare -a sun_rate_hist=()

append_hist() {
  slab_hist+=("$Slab")
  sun_hist+=("$SUnreclaim")
  avail_hist+=("$MemAvailable")
  sun_rate_hist+=("$SUnreclaim")

  if [ "${#slab_hist[@]}" -gt 8 ]; then slab_hist=("${slab_hist[@]:1}"); fi
  if [ "${#sun_hist[@]}" -gt 8 ]; then sun_hist=("${sun_hist[@]:1}"); fi
  if [ "${#avail_hist[@]}" -gt 8 ]; then avail_hist=("${avail_hist[@]:1}"); fi
  if [ "${#sun_rate_hist[@]}" -gt "$RATE_SAMPLES" ]; then sun_rate_hist=("${sun_rate_hist[@]:1}"); fi
}

# Lock state, lock-screen greeter (the leak trigger), Deck virtual output,
# fd / GPU counters. plasmashell leaks anon_inode:sync_file fds until it hits
# RLIMIT_NOFILE; kwin's fds are not readable as this user, so the system-wide
# open-file count stands in for it.
read_session_state() {
  local sid locked_hint

  Locked=""
  sid=$(loginctl show-user "$MY_UID" -p Display --value 2>/dev/null || true)
  if [ -n "$sid" ]; then
    locked_hint=$(loginctl show-session "$sid" -p LockedHint --value 2>/dev/null || true)
    case "$locked_hint" in
      yes) Locked=1 ;;
      no)  Locked=0 ;;
    esac
  fi

  # Match process names (comm, truncated to 15 chars), not command lines,
  # so shells or editors mentioning them do not count.
  Greeter=0
  if pgrep -u "$MY_UID" -x 'kscreenlocker_g' >/dev/null 2>&1; then Greeter=1; fi
  DeckVm=0
  if pgrep -u "$MY_UID" -x 'krfb-virtualmon' >/dev/null 2>&1; then DeckVm=1; fi

  SysOpenFiles=$(awk '{ print $1 }' /proc/sys/fs/file-nr 2>/dev/null || true)

  # Other users' /proc/<pid>/fd are unreadable; find's errors are expected.
  read -r UserSyncFiles UserDmabufs < <(
    find /proc/[0-9]*/fd -mindepth 1 -maxdepth 1 \
      \( -lname 'anon_inode:sync_file' -o -lname '*dmabuf*' \) -printf '%l\n' 2>/dev/null \
      | awk '/sync_file/ { s++ } /dmabuf/ { d++ } END { print s + 0, d + 0 }' || true
  )

  GpuMemMiB=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d ' ' || true)

  PsPid=$(pgrep -u "$MY_UID" -x plasmashell 2>/dev/null | head -n1 || true)
  PsFds=""
  PsSyncFiles=""
  PsFdLimit=""
  if [ -n "$PsPid" ] && [ -d "/proc/$PsPid/fd" ]; then
    PsFds=$(find "/proc/$PsPid/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l || true)
    PsSyncFiles=$(find "/proc/$PsPid/fd" -mindepth 1 -maxdepth 1 -lname 'anon_inode:sync_file' 2>/dev/null | wc -l || true)
    PsFdLimit=$(awk '/^Max open files/ { print $4 }' "/proc/$PsPid/limits" 2>/dev/null || true)
  fi
}

log_snapshot() {
  ts=$(date '+%F %T')
  MemAvailable=$(read_kib "MemAvailable:")
  MemFree=$(read_kib "MemFree:")
  Cached=$(read_kib "Cached:")
  Slab=$(read_kib "Slab:")
  SUnreclaim=$(read_kib "SUnreclaim:")
  SReclaimable=$(read_kib "SReclaimable:")
  Active=$(read_kib "Active:")
  Inactive=$(read_kib "Inactive:")
  AnonPages=$(read_kib "AnonPages:")
  SwapTotal=$(read_kib "SwapTotal:")
  SwapFree=$(read_kib "SwapFree:")
  SwapCached=$(read_kib "SwapCached:")
  read_session_state

  echo "$ts,$MemAvailable,$MemFree,$Cached,$Slab,$SUnreclaim,$SReclaimable,$Active,$Inactive,$AnonPages,$SwapTotal,$SwapFree,$SwapCached,$Locked,$Greeter,$DeckVm,$PsPid,$PsFds,$PsSyncFiles,$PsFdLimit,$SysOpenFiles,$UserSyncFiles,$UserDmabufs,$GpuMemMiB" >> "$CSV"

  append_hist
}

check_alerts() {
  local active delta uptime_sec

  active=0
  if [ "$Slab" -gt "$SLAB_ALERT" ] || [ "$SUnreclaim" -gt "$SUNRECLAIM_ALERT" ]; then active=1; fi
  latch slab_pressure "$active" "slab pressure high: Slab=${Slab}k SUnreclaim=${SUnreclaim}k MemAvailable=${MemAvailable}k"

  active=0
  if [ "$MemAvailable" -lt "$MEMAVAILABLE_ALERT" ]; then active=1; fi
  latch low_memavailable "$active" "low MemAvailable: ${MemAvailable}k"

  if [ "${#sun_rate_hist[@]}" -ge "$RATE_SAMPLES" ]; then
    delta=$(( ${sun_rate_hist[-1]} - ${sun_rate_hist[0]} ))
    active=0
    if [ "$delta" -gt "$SUNRECLAIM_RATE_KIB" ]; then active=1; fi
    latch sunreclaim_rate "$active" "SUnreclaim rose ${delta}k in $(( SUNRECLAIM_RATE_WINDOW_SEC / 60 ))min (now ${SUnreclaim}k, lock-screen greeter=${Greeter})"
  fi

  active=0
  if [ -n "$PsFds" ] && [ -n "$PsFdLimit" ] && [ "$PsFdLimit" != "unlimited" ] \
     && [ $(( PsFds * 100 )) -ge $(( PsFdLimit * FD_ALERT_PCT )) ]; then
    active=1
  fi
  latch plasmashell_fds "$active" "plasmashell (PID ${PsPid:-?}) has ${PsFds:-?}/${PsFdLimit:-?} fds open (${PsSyncFiles:-?} sync_file); fix: systemctl --user restart plasma-plasmashell.service"

  if [ "$DECK_LOCK_ALERT" = "1" ]; then
    active=0
    if [ "$DeckVm" = "1" ] && { [ "$Locked" = "1" ] || [ "$Greeter" = "1" ]; }; then active=1; fi
    latch deck_while_locked "$active" "Deck virtual output active while screen is locked (locked=${Locked:-?} greeter=${Greeter}); disconnect Moonlight to avoid the slab leak"
  fi

  # Log-only trends; skipped right after boot while the desktop is starting up.
  uptime_sec=$(awk '{ print int($1) }' /proc/uptime)
  if [ "$uptime_sec" -lt "$TREND_GRACE_SEC" ]; then
    return
  fi

  if [ "${#slab_hist[@]}" -ge 3 ]; then
    delta=$(( ${slab_hist[-1]} - ${slab_hist[0]} ))
    if [ "$delta" -gt "$TREND_DELTA" ]; then
      warn "TREND: Slab rising by ${delta}k over recent samples" "no"
    fi
  fi

  if [ "${#sun_hist[@]}" -ge 3 ]; then
    delta=$(( ${sun_hist[-1]} - ${sun_hist[0]} ))
    if [ "$delta" -gt "$TREND_DELTA" ]; then
      warn "TREND: SUnreclaim rising by ${delta}k over recent samples" "no"
    fi
  fi

  if [ "${#avail_hist[@]}" -ge 3 ]; then
    delta=$(( ${avail_hist[0]} - ${avail_hist[-1]} ))
    if [ "$delta" -gt "$TREND_DELTA" ]; then
      warn "TREND: MemAvailable fell by ${delta}k over recent samples" "no"
    fi
  fi
}

if [ ! -f "$CSV" ]; then
  echo "ts,MemAvailable,MemFree,Cached,Slab,SUnreclaim,SReclaimable,Active,Inactive,AnonPages,SwapTotal,SwapFree,SwapCached,Locked,Greeter,DeckVm,PlasmashellPid,PlasmashellFds,PlasmashellSyncFiles,PlasmashellFdLimit,SysOpenFiles,UserSyncFiles,UserDmabufs,GpuMemMiB" >> "$CSV"
fi

while true; do
  log_snapshot
  check_alerts
  sleep "$SAMPLE_SEC"
done
EOF

chmod 700 "$SCRIPT_PATH"

cat >"$UNIT_PATH" <<EOF
[Unit]
Description=Kernel memory monitor and slab growth alert

[Service]
Type=simple
ExecStart=${SCRIPT_PATH}
Restart=always
RestartSec=30
Environment=HOME=${HOME}
Environment=XDG_STATE_HOME=${XDG_STATE_HOME:-${HOME}/.local/state}

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now memwatch.service

echo "Installed memwatch service."
echo "Script: $SCRIPT_PATH"
echo "Unit:   $UNIT_PATH"
echo "Logs:   $LOGDIR"
echo
echo "Useful commands:"
echo "  systemctl --user restart memwatch.service   # required to pick up a changed script"
echo "  systemctl --user status memwatch.service"
echo "  journalctl --user -u memwatch.service -f"
echo "  tail -f \"$LOGDIR/memwatch-\$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown).v2.csv\""
echo "  tail -f \"$LOGDIR/memwatch-\$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown).alerts\""

chmod 700 "$SCRIPT_PATH"

# Manual foreground run only when explicitly requested.
if [[ "${1:-}" == "--run" ]]; then
  exec "$SCRIPT_PATH"
fi

# If invoked manually after installation, just exit, no reboot behavior.
exit 0
