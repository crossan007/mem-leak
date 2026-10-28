#!/usr/bin/env bash

set -u

INTERVAL=${INTERVAL:-5}
WINDOW=${WINDOW:-12}
LOG_DIR=${LOG_DIR:-$(pwd)}
RUN_ID=$(date +%Y%m%d-%H%M%S)
LOG_BASENAME="memwatch-${RUN_ID}"
DETAIL_LOG="${LOG_DIR}/${LOG_BASENAME}.log"
ALERT_LOG="${LOG_DIR}/${LOG_BASENAME}.alerts.log"

SLAB_NAMES=(
  kmalloc-rnd-15-64
  dentry
  ext4_inode_cache
  trace_event_file
  buffer_head
  radix_tree_node
  vm_area_struct
  vmap_area
  kernfs_node_cache
  anon_vma_chain
  anon_vma
  inode_cache
  proc_inode_cache
  shmem_inode_cache
  extent_status
  filp
  lsm_file_cache
  kmalloc-rnd-07-512
  kmalloc-rnd-06-64
  kmalloc-rnd-06-1k
  kmalloc-rnd-06-512
)

SLAB_RISE_ALERT=${SLAB_RISE_ALERT:-200000}
S_UNRECLAIM_ALERT=${S_UNRECLAIM_ALERT:-200000}
MEMAVAILABLE_DROP_ALERT=${MEMAVAILABLE_DROP_ALERT:-500000}
CACHED_RISE_ALERT=${CACHED_RISE_ALERT:-200000}
ROLLING_ALERT_DELTA=${ROLLING_ALERT_DELTA:-150000}

read_kib() {
    awk -v key="$1" '$1 == key { print $2; exit }' /proc/meminfo
}

make_kib_human() {
    local v="$1"
    awk -v v="$v" 'BEGIN { printf "%.1fMiB", v / 1024 }'
}

make_kib_human_exact() {
    local v="$1"
    awk -v v="$v" 'BEGIN { printf "%.0fKiB", v }'
}

write_log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$1" >> "$DETAIL_LOG"
}

write_alert() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$1" | tee -a "$ALERT_LOG" >&2
}

read_slab_line() {
    local name="$1"
    awk -v name="$name" '$3 == name { print $0; exit }' /proc/slabinfo
}

probe_slab_focus() {
    local name line active total obj_size slabs cache_kib
    for name in "${SLAB_NAMES[@]}"; do
        line=$(read_slab_line "$name")
        if [ -n "$line" ]; then
            active=$(awk '{print $2}' <<< "$line")
            total=$(awk '{print $3}' <<< "$line")
            obj_size=$(awk '{print $4}' <<< "$line")
            slabs=$(awk '{print $5}' <<< "$line")
            cache_kib=$(awk '{print $6}' <<< "$line")
            printf '%-28s active=%-12s total=%-12s obj_size=%-8s slabs=%-8s cache=%s\n' \
                "$name" "$active" "$total" "$obj_size" "$slabs" "$(make_kib_human_exact "$cache_kib")"
        fi
    done
}

declare -a slab_hist=()
declare -a sun_hist=()
declare -a avail_hist=()
declare -a cached_hist=()

for key in MemAvailable MemFree Slab SUnreclaim Cached; do
    eval "last_${key}=$(read_kib ${key}:)"
done

record_hist() {
    local val="$1"
    local arr_name="$2"
    case "$arr_name" in
        slab) slab_hist+=("$val") ;;
        sun)  sun_hist+=("$val") ;;
        avail) avail_hist+=("$val") ;;
        cached) cached_hist+=("$val") ;;
    esac
    case "$arr_name" in
        slab) if [ ${#slab_hist[@]} -gt "$WINDOW" ]; then slab_hist=("${slab_hist[@]:1}"); fi ;;
        sun)  if [ ${#sun_hist[@]} -gt "$WINDOW" ]; then sun_hist=("${sun_hist[@]:1}"); fi ;;
        avail) if [ ${#avail_hist[@]} -gt "$WINDOW" ]; then avail_hist=("${avail_hist[@]:1}"); fi ;;
        cached) if [ ${#cached_hist[@]} -gt "$WINDOW" ]; then cached_hist=("${cached_hist[@]:1}"); fi ;;
    esac
}

trend_alert() {
    local name="$1"
    local hist_ref="$2"
    local hist=()

    case "$hist_ref" in
        slab) hist=("${slab_hist[@]}") ;;
        sun)  hist=("${sun_hist[@]}") ;;
        avail) hist=("${avail_hist[@]}") ;;
        cached) hist=("${cached_hist[@]}") ;;
    esac

    if [ ${#hist[@]} -lt 3 ]; then
        return
    fi

    local first="${hist[0]}"
    local last="${hist[$(( ${#hist[@]} - 1 ))]}"
    local delta=$(( last - first ))

    case "$name" in
        slab)
            if [ "$delta" -gt "$ROLLING_ALERT_DELTA" ]; then
                write_alert "TREND: Slab rose by $(make_kib_human "$delta") over the last ${#hist[@]} samples"
            fi
            ;;
        sun)
            if [ "$delta" -gt "$ROLLING_ALERT_DELTA" ]; then
                write_alert "TREND: SUnreclaim rose by $(make_kib_human "$delta") over the last ${#hist[@]} samples"
            fi
            ;;
        avail)
            if [ "$delta" -lt "-$ROLLING_ALERT_DELTA" ]; then
                write_alert "TREND: MemAvailable fell by $(make_kib_human "$(( -delta ))") over the last ${#hist[@]} samples"
            fi
            ;;
        cached)
            if [ "$delta" -gt "$ROLLING_ALERT_DELTA" ]; then
                write_alert "TREND: Cached rose by $(make_kib_human "$delta") over the last ${#hist[@]} samples"
            fi
            ;;
    esac
}

mkdir -p "$LOG_DIR"
: > "$DETAIL_LOG"
: > "$ALERT_LOG"

write_log "memwatch start: interval=${INTERVAL}s window=${WINDOW} log_dir=${LOG_DIR}"
write_log "uname=$(uname -a)"
write_log "uptime=$(uptime -p)"
write_log "kernel=$(uname -r)"

printf '=== memory monitor ===\n'
printf 'interval=%ss window=%s\n' "$INTERVAL" "$WINDOW"
printf 'details log: %s\n' "$DETAIL_LOG"
printf 'alerts log: %s\n' "$ALERT_LOG"
printf 'target slab names: %s\n' "${SLAB_NAMES[*]}"
printf '======================\n\n'

while true; do
    cur_Slab=$(read_kib 'Slab:')
    cur_SUnreclaim=$(read_kib 'SUnreclaim:')
    cur_MemAvailable=$(read_kib 'MemAvailable:')
    cur_Cached=$(read_kib 'Cached:')
    cur_MemFree=$(read_kib 'MemFree:')
    cur_Active=$(read_kib 'Active:')
    cur_Inactive=$(read_kib 'Inactive:')
    cur_AnonPages=$(read_kib 'AnonPages:')
    cur_SwapTotal=$(read_kib 'SwapTotal:')
    cur_SwapFree=$(read_kib 'SwapFree:')
    cur_SwapUsed=$(( cur_SwapTotal - cur_SwapFree ))

    record_hist "$cur_Slab" slab
    record_hist "$cur_SUnreclaim" sun
    record_hist "$cur_MemAvailable" avail
    record_hist "$cur_Cached" cached

    delta_Slab=$(( cur_Slab - last_Slab ))
    delta_SUnreclaim=$(( cur_SUnreclaim - last_SUnreclaim ))
    delta_MemAvailable=$(( cur_MemAvailable - last_MemAvailable ))
    delta_Cached=$(( cur_Cached - last_Cached ))
    delta_MemFree=$(( cur_MemFree - last_MemFree ))

    timestamp=$(date '+%Y-%m-%d %H:%M:%S %z')

    printf '%s | MemAvail=%s | MemFree=%s | Cached=%s | Slab=%s | SUnreclaim=%s | SwapUsed=%s | Active=%s | Inactive=%s\n' \
        "$timestamp" \
        "$(make_kib_human "$cur_MemAvailable")" \
        "$(make_kib_human "$cur_MemFree")" \
        "$(make_kib_human "$cur_Cached")" \
        "$(make_kib_human "$cur_Slab")" \
        "$(make_kib_human "$cur_SUnreclaim")" \
        "$(make_kib_human_exact "$cur_SwapUsed")" \
        "$(make_kib_human "$cur_Active")" \
        "$(make_kib_human "$cur_Inactive")"

    if [ "$delta_Slab" -gt "$SLAB_RISE_ALERT" ]; then
        write_alert "ALERT: Slab changed by +$(make_kib_human "$delta_Slab") since last sample"
    fi

    if [ "$delta_SUnreclaim" -gt "$S_UNRECLAIM_ALERT" ]; then
        write_alert "ALERT: SUnreclaim changed by +$(make_kib_human "$delta_SUnreclaim") since last sample"
    fi

    if [ "$delta_MemAvailable" -lt "-$MEMAVAILABLE_DROP_ALERT" ]; then
        write_alert "ALERT: MemAvailable changed by -$(make_kib_human "$(( -delta_MemAvailable ))") since last sample"
    fi

    if [ "$delta_Cached" -gt "$CACHED_RISE_ALERT" ]; then
        write_alert "ALERT: Cached changed by +$(make_kib_human "$delta_Cached") since last sample"
    fi

    if [ "$delta_MemFree" -lt 0 ]; then
        write_alert "ALERT: MemFree dropped by $(make_kib_human "$(( -delta_MemFree ))") since last sample"
    fi

    trend_alert slab slab
    trend_alert sun sun
    trend_alert avail avail
    trend_alert cached cached

    write_log "MemAvailable=${cur_MemAvailable}kiB Cached=${cur_Cached}kiB Slab=${cur_Slab}kiB SUnreclaim=${cur_SUnreclaim}kiB MemFree=${cur_MemFree}kiB Active=${cur_Active}kiB Inactive=${cur_Inactive}kiB AnonPages=${cur_AnonPages}kiB SwapUsed=${cur_SwapUsed}kiB"
    write_log "delta: Slab=${delta_Slab}kiB SUnreclaim=${delta_SUnreclaim}kiB MemAvailable=${delta_MemAvailable}kiB Cached=${delta_Cached}kiB MemFree=${delta_MemFree}kiB"
    write_log "slab_focus: $(probe_slab_focus | tr '\n' '; ' )"

    last_Slab="$cur_Slab"
    last_SUnreclaim="$cur_SUnreclaim"
    last_MemAvailable="$cur_MemAvailable"
    last_Cached="$cur_Cached"
    last_MemFree="$cur_MemFree"

    sleep "$INTERVAL"
done
