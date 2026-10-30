# NVIDIA 580 kmalloc-64 slab leak: KDE lock screen + virtual output (Sunshine)

## Status as of 2026-10-29

**Root cause narrowed down.** The memory loss is a kernel-side leak of 64-byte objects in a single generic kmalloc cache. It grows only while the KDE lock-screen greeter is on screen. It is not filesystem metadata churn, which was the earlier working theory (see "Superseded interpretation" below).

The leak was caught live on boot `d05a2542-9029-4773-9e22-af94ca9fa00a`:

| | Value |
|---|---|
| Leaking cache | `kmalloc-rnd-12-64` |
| Objects | 230,084,260 active / 230,084,288 total (~100% in use) |
| Size | 14.4 GB (≈ all of the `SUnreclaim` growth) |
| `SUnreclaim` | 0.70 GiB (2026-10-28 11:45) → 14.3 GiB (2026-10-29 08:35) |
| `MemAvailable` | 16.0 GiB → 5.5 GiB of 31.3 GiB |
| Growth rate | ~7.8 MiB / 30 s, linear (≈ 4,400 leaked allocations/s) |
| Leak window | 2026-10-28 17:22:49 → 2026-10-29 08:34:32 |

After the leak stopped, `SUnreclaim` stayed flat at ~15.0 GB. The memory was **not** freed when the greeter process exited; only a reboot recovered it.

**Current state (boot `87cd5481`, rebooted 2026-10-29 08:48):**

- No kernel leak this boot. `SUnreclaim` is ~0.6 GiB, rising ~20 MiB/h.
- A 32-minute **static** lock with the Deck streaming did **not** leak (Finding 6). The trigger is still unknown; it probably needs continuous rendering while locked.
- The plasmashell `sync_file` fd leak is worked around with `__NV_DISABLE_EXPLICIT_SYNC=1`. This is a **standing configuration change** that persists across reboots and is inherited by apps launched from Plasma (Finding 4).

Evidence (not included in this repository; the relevant figures are quoted in this document):

- a `/proc/slabinfo` snapshot taken at 2026-10-29 08:37, while the leaked memory was still allocated (the table above)
- the output of `kmalloc64-leakers.bt` at 08:39, which attributes 64-byte allocations to call sites. It was captured **after** the leak stopped, so it does not contain the leaking call site (table in Finding 3).
- the monitor's 30-second meminfo CSV covering the whole leak (the source of the timeline and rates)

## Findings

### 1. It is one cache, one call site

`slabtop` and `/proc/slabinfo` both show `kmalloc-rnd-12-64` at 14.4 GB. The next largest cache is `ext4_inode_cache` at 1.3 GB, which is reclaimable and normal. Reclaimable slab (`SReclaimable`) did not grow at all, so `drop_caches` will not help.

The kernel is built with `CONFIG_RANDOM_KMALLOC_CACHES=y`. Each kmalloc size class is therefore split into 16 caches (`kmalloc-rnd-00-64` … `-15-64`), and the cache a call lands in is chosen by hashing the **caller's address** with a **per-boot random seed**. Because the entire leak landed in one cache, it is almost certainly from a single call site.

Consequences:

- **The leaking cache will have a different name after every reboot.** Do not monitor a fixed `kmalloc-rnd-NN-64` name. The old `memwatch.sh` watched `kmalloc-rnd-15-64` and `rnd-06-64` for this reason, and it would have missed this cache.
- The cache name alone cannot identify the caller. A trace is needed.

### 2. The leak runs only while the lock-screen greeter is up

The Plasma lock screen shows a greeter (password / fingerprint prompt) when a locked screen is woken. fprintd is started at that moment, so `Started fprintd.service` in the journal marks "greeter appeared".

Timeline for this boot:

| Time | Event | Greeter up for | Leak? |
|---|---|---|---|
| 10-27 13:53:48 → 13:53:52 | greeter → unlock | 4 s | negligible |
| 10-28 08:45:44 → 08:45:50 | greeter → unlock | 6 s | negligible |
| 10-28 14:41:26 → 14:41:29 | greeter → unlock | 3 s | negligible |
| **10-28 17:22:27 → 10-29 08:34:25** | greeter → unlock (next morning) | **~15 h** | **yes: 0.77 → 15.0 GiB** |

- Leak onset: between the samples at 17:22:19 and 17:22:49, with the greeter appearing at 17:22:27.
- Leak end: the 08:34:32 sample shows a partial increase, and growth is ~0 from 08:36 on. Unlock was at 08:34:25.
- The greeter process (`kscreenlocker_greet`, PID 752574) was alive for the whole window and exited on unlock.
- Ruled out:
  - fprintd: it exited at 17:22:57 and the leak continued.
  - Discord AppArmor audit spam: same rate before and after onset.

~4,400 objects/s ≈ ~70 per frame at 60 Hz, which is consistent with a per-frame leak in the rendering path.

### 3. The explicit-sync / NVIDIA path is the prime suspect

Environment:

| Component | Version |
|---|---|
| GPU | NVIDIA GM200 (GTX 980 Ti) |
| Kernel driver | `nvidia` 580.178.04 |
| Kernel | 7.0.0-38-generic |
| Plasma / KWin | 6.6.6, Wayland |

The 15-second trace (`kmalloc64-leakers.bt`, taken after the leak stopped) shows the active 64-byte allocators on this system:

| Call site | Allocs / 15 s | Freed |
|---|---|---|
| `ext4_dir_open` | 4889 | 4889 |
| `nv_drm_calloc` | 4449 | 4449 |
| `os_alloc_mem` (nvidia) | 3249 | 3134 |
| `__vmalloc_area_node` | 3057 | 3057 |
| `nvkms_alloc` | 1324 | 1282 |
| `drm_syncobj_create` | 1110 | 1110 |
| `dma_fence_allocate_private_stub` | 737 | 0 * |

\* `dma_fence` objects are freed via RCU / bulk free, which the `kmem:kfree` tracepoint may not see, so `0` here is not proof of a leak.

`struct dma_fence` is exactly 64 bytes on x86_64. That makes DRM explicit-sync fences (via `nv_drm` / `drm_syncobj`) the leading candidate, but this is **not yet proven**. A trace has to be captured while the greeter is up.

### 4. Related bug: plasmashell exhausts file descriptors on sync_files

plasmashell (PID 560771, started 2026-10-28 09:57) holds **886 `anon_inode:sync_file` fds** and has reached its 1024 soft `RLIMIT_NOFILE`. From 08:34:52 it logs:

```
error marshalling arguments for import_timeline: dup failed: Too many open files
Error marshalling request for wp_linux_drm_syncobj_manager_v1.import_timeline: Too many open files
qt.qpa.wayland: eglSwapBuffers failed with 0x3000
```

The previous plasmashell process (PID 4467) hit the same limit on 2026-10-27 13:53:46, and its replacement started at 09:57:33 on 2026-10-28. This is a separate userspace fd leak in the same explicit-sync path (`wp_linux_drm_syncobj_v1`), which strengthens the explicit-sync hypothesis.

To recover the shell without rebooting, run `systemctl --user restart plasma-plasmashell.service`. This does **not** free the kernel slab.

After the 2026-10-29 reboot, with the Deck streaming, plasmashell's `sync_file` count grew at ~2.4/min: 40 at 08:50, 54 at 08:55, 66 at 09:01, 74 at 09:06. The previous plasmashell averaged ~0.6/min over its lifetime.

Other processes also hold `sync_file` fds; at 09:06, 188 in total for this user. Firefox (51), Telegram (17) and VS Code (14) hold the most after plasmashell. `UserSyncFiles` in the CSV tracks the total.

**The leak is per frame rendered, not per unit of time** (2026-10-29, plasmashell PID 5964, 7.5 h of 30 s samples):

- `sync_file` fds went from 40 to 601, out of 770 fds total. Every other fd type (eventfd, sockets, `/dev/nvidia*`, inotify, caches) stayed stable.
- 88% of samples showed no change. Growth came in bursts of ~10–50, matching popup, notification and tooltip animations; the unlock at 14:05 alone added 19.
- During a 32-minute screen lock, growth was exactly zero.
- Hovering a task-manager entry added 1–5 `sync_file` fds per hover, never closed.
- Firefox showed the same pattern (51 → 475 over the same period), so this is any EGL Wayland client, not Plasma specifically.

**`__NV_DISABLE_EXPLICIT_SYNC=1` fixes it for plasmashell.** It was set via a systemd drop-in and plasmashell was restarted at 16:44 (PID 302882):

```ini
# ~/.config/systemd/user/plasma-plasmashell.service.d/override.conf
[Service]
Environment=__NV_DISABLE_EXPLICIT_SYNC=1
```

With it, a hover creates one `sync_file` that is closed when the hover ends, and the count stays flat at ~13. The leaked fds are therefore the fences egl-wayland creates for `wp_linux_drm_syncobj_v1` on each swap, not anything in Qt or Plasma.

**This is a standing configuration change, and it spreads:**

- The drop-in persists: every login and reboot starts plasmashell with the variable.
- Apps launched from the panel, menu or KRunner **inherit** plasmashell's environment. Confirmed with Firefox: relaunched from Plasma at 16:54 (PID 309680, unit `app-firefox@….service`), it had the variable without it being set for Firefox, and started with ~6 `sync_file` fds. After 31 minutes including heavy scrolling (Facebook) it held 10, versus ~1/min before the workaround, so the workaround fixes Firefox too. At 18:11 both were still flat: plasmashell 13 after ~1.5 h (≈ +90 expected without the workaround) and Firefox 13 after ~1.3 h (≈ +75 expected). Facebook also felt smoother, but the restart (the old Firefox had a 3.5–5.7 GiB content process and the system was swapping) is a confound.
- Not affected: apps started before plasmashell picked it up, autostart apps, apps launched from a terminal that predates it, and systemd services (KWin, Sunshine).
- Readings taken with the override active must not be read as "the fd leak is fixed upstream".

To undo: `systemctl --user revert plasma-plasmashell.service`, then restart plasmashell and relaunch the affected apps.

### 5. A Steam Deck virtual monitor was being streamed for the whole leak

The desktop has a fourth, software-only output that lets the Steam Deck act as an extra monitor:

- `krfb-virtualmonitor --resolution 1280x800 --name deck-vm` creates a KWin virtual output, **`Virtual-deck-vm`** (1280×800@60). There is no DRM connector behind it, so KWin renders it on the NVIDIA GPU with no physical display.
- **Sunshine** streams that output to Moonlight on the Deck with `capture = kwin` (a KWin screencast over PipeWire). Every streamed frame passes dma-buf buffers and sync fences between KWin and Sunshine. That is the same explicit-sync machinery (`sync_file`, `drm_syncobj`, `dma_fence`) the other findings point at.
- Sunshine's `global_prep_cmd` runs `~/.config/sunshine/deck-vm-start.sh` when a session starts and `deck-vm-stop.sh` when it ends. The stop script kills `krfb-virtualmonitor`, removing the output.
- A systemd drop-in (`app-dev.lizardbyte.app.Sunshine.service.d/override.conf`) also kills any leftover `krfb-virtualmonitor` when Sunshine starts.

On the leaking boot, the Deck connected on 2026-10-27 at 08:52 and **never disconnected**: the journal has no disconnect and no stop command. So the virtual output was being streamed for the entire boot, including the 15 h leak.

The stream alone did not leak, though. For ~32 h before 17:22 it was active and `SUnreclaim` stayed flat. The leak needed the stream **and** the lock-screen greeter on screen.

A plausible mechanism (not verified): when the session is locked, the physical monitors power off, but a virtual output has no power state. KWin may therefore keep rendering the lock screen at 60 Hz into the screencast all night. A small per-frame leak on the lock-screen render path would not show up during normal desktop use.

### 6. A static locked screen with the stream active did not leak (2026-10-29)

Boot `87cd5481`, with Moonlight streaming continuously since shortly after boot:

| Lock | Duration | `DeckVm` | `SUnreclaim` before → peak → after unlock |
|---|---|---|---|
| 13:30:11 | < 1 min | 1 | 557.4 → 559.2 → 557.5 MiB |
| 13:32:12 → 14:04:31 | 32 min | 1 | 557.1 → 558.4 → 558.4 MiB |

- The physical monitors powered off during the 32-minute lock: GPU memory stepped down from 3.3 GB to 2.1 GB at 13:36, 13:42 and 13:50, and powerdevil logged the monitors' DDC/i2c devices reappearing at the 14:04 unlock.
- The machine was effectively idle: `sync_file` counts did not move, and `SUnreclaim` changed by a few KiB per sample.
- On the leak night onset came ~22 s after the greeter appeared, so 32 minutes is a fair negative. Lock + greeter + stream is **not sufficient**.

The leak night's ~4,400 objects/s (~70 per frame at 60 Hz) means something kept frames coming all night, whereas today's lock screen was static. Since both the kernel leak and the plasmashell fd leak (Finding 4) scale with frames rendered, the missing factor is probably **continuous rendering while locked**: for example lock-screen media controls updating, an animated wallpaper, or the greeter staying visible with the screens on.

## Hypothesis

While the Plasma 6.6.6 lock-screen greeter is on screen **and** the `Virtual-deck-vm` output is being screencast to the Steam Deck through KWin and PipeWire, each frame leaks DRM explicit-sync kernel objects. These are most likely 64-byte `dma_fence` objects, allocated through the `nvidia-drm` / `drm_syncobj` path on NVIDIA 580.178.04 under Wayland, and they are never released. They are not tied to the greeter's file descriptors, because they survive the process exiting.

Normal desktop rendering, even while streaming, either does not hit the same path or does not leak at a measurable rate. The plasmashell `sync_file` fd leak is likely a sibling symptom of the same explicit-sync integration, and it may be faster while streaming.

Not yet confirmed:

- which exact function makes the leaked allocations
- whether the leak is in `nvidia-drm` / `nvidia-modeset`, core DRM syncobj / dma-fence code, or the KWin screencast path
- whether the trigger is the stream (Sunshine screencast) or just the virtual output existing
- what kept frames rendering on the leak night. A static lock with the stream active did not leak (Finding 6). `kscreenlocker_greet` runs for the whole lock, so `Locked` and `Greeter` do not separate "locked" from "greeter visible".

## Next steps

1. ~~**Reboot** to recover the ~14 GB.~~ Done 2026-10-29 08:48.
2. **Reproduce on purpose.** Note whether the plasmashell `__NV_DISABLE_EXPLICIT_SYNC=1` drop-in was active and how the animating app was launched (Finding 4): the leak night ran **without** the override, so a test with it in place is a different condition. If an animated lock does not leak, revert the drop-in, launch the animating app from a terminal, and repeat. Each run: lock the screen, wake it so the greeter shows, and leave it ~5 minutes without unlocking. Watch `tail -f ~/.local/state/memwatch/memwatch-$(cat /proc/sys/kernel/random/boot_id).v2.csv`; `SUnreclaim` is column 6, and the `Locked`, `Greeter` and `DeckVm` columns record the conditions.

   Test A with a static lock screen was negative (Finding 6), so repeat it with something animating on the lock screen, e.g. music playing in Tidal so the media controls update, or the greeter kept visible with the screens on. Check with `./status.sh` (the "Lock episodes" section).

   | Test | Deck stream | Virtual output | Expected if the hypothesis is right |
   |---|---|---|---|
   | A | connected | on | leaks ~8 MiB per 30 s sample (static lock: **no leak**, 2026-10-29) |
   | B | disconnected in Moonlight (stop script runs) | off | no leak |
   | C | disconnected | on (run `~/.config/sunshine/deck-vm-start.sh` by hand) | separates "stream" from "virtual output exists" |

   Also compare plasmashell's `sync_file` growth rate (`PlasmashellSyncFiles`) with the Deck connected and disconnected.
3. **Trace during the reproduction**, from SSH or a text console (Ctrl+Alt+F3) so the greeter stays up:
   ```
   cd ~/mem-leak && sudo bpftrace kmalloc64-leakers.bt | tee kmalloc64-leakers-$(date +%F-%H%M).txt
   ```
   The leaker will show ~66k `@alloc` in 15 s with few or no `@freed`. If the top suspect is `dma_fence_allocate_private_stub` (whose frees may be invisible to the tracepoint), follow up with a `kstack` trace filtered on that call site to see which driver path calls it.
4. **Work around it in the meantime:** end the Moonlight session before locking or walking away. That runs the stop script and removes the virtual output. Otherwise, unlock promptly. The monitor's `deck_while_locked` alert reminds you of this.
5. **Report upstream.** Done so far: data posted on #1331 and egl-wayland #196 (see "Upstream reports"). Still to do: post the leaking call site to #1331 once traced, and file with KDE (KWin 6.6.6 explicit sync / screencast of virtual outputs) if the trigger turns out to be on the KWin side. Mention Sunshine `capture = kwin` with `krfb-virtualmonitor`.
6. **Check driver updates** for an NVIDIA release that fixes explicit-sync fence leaks.

## Upstream reports

- **[NVIDIA/open-gpu-kernel-modules#1331](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1331)** is a near-exact match for the kernel leak:
  - `kmalloc-64`, `nvkms_alloc`, ~3,600 objects/s, a headless output under Wayland explicit sync, and reboot-only recovery.
  - Commenters attribute it to `nvKmsKapiRegisterSemaphoreSurfaceCallback()` (`nvkms-kapi-sync.c`) not freeing `cb` on `ALREADY_SIGNALLED`, with a user-tested one-line `nvKmsKapiFree(cb)` fix on 610.57.04.
  - It is filed against the open modules on 595/610/615. `__NV_DISABLE_EXPLICIT_SYNC=1` reportedly does **not** stop it.
  - No NVIDIA response as of 2026-10-29.
  - **Our data was posted 2026-10-29:** [comment](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1331#issuecomment-6497680295) (proprietary 580.178.04, KDE, virtual output + lock-screen trigger). No `nvkms_alloc` stack trace from a live leak has been captured yet. If one is captured during the reproduction, post it as a follow-up.
- **plasmashell `sync_file` fd leak:** [KDE bug 497424](https://www.mail-archive.com/kde-bugs-dist@kde.org/msg1030614.html), the [NVIDIA forum thread](https://forums.developer.nvidia.com/t/fd-leak-with-explicit-sync-and-kde-plasma/317293) (NVIDIA internal bug 5556719), and [egl-wayland#196](https://github.com/NVIDIA/egl-wayland/issues/196).
  - The egl-wayland report has 580 with egl-wayland 1.1.21, the same as here, leaking one fd per `eglSwapBuffers`.
  - Reported still present on 580.x.
  - Fixes: 590.44.01+ with egl-wayland2 reportedly fixes it, but reports are mixed. Maxwell is believed to be limited to 580, so this upgrade is likely unavailable.
  - Workarounds: `__NV_DISABLE_EXPLICIT_SYNC=1` (for plasmashell), restarting plasmashell, or Plasma software rendering.
  - **`__NV_DISABLE_EXPLICIT_SYNC=1` confirmed to fix it here, and our data was posted 2026-10-29:** [comment](https://github.com/NVIDIA/egl-wayland/issues/196#issuecomment-6507971319) (per-frame bursts, hover test, before/after). See Finding 4.

## Monitor

The monitor runs as the user unit `memwatch.service`, which executes `~/.local/bin/memwatch.sh`. That installed script is generated by `memwatch-service.sh` in this folder (the script body is a heredoc inside it). It survives the terminal session and continues across a login session.

Logs for the service live in `~/.local/state/memwatch/`:

- `memwatch-<boot_id>.v2.csv` — 30-second snapshots. Boots before the v2 install (2026-10-29) have `memwatch-<boot_id>.csv` instead, with only the 13 meminfo columns. The v2 columns are:

  | Columns | Source / meaning |
  |---|---|
  | `ts` | timestamp |
  | `MemAvailable` … `SwapCached` (12) | `/proc/meminfo`, KiB |
  | `Locked` | logind `LockedHint`: 1 = session locked, empty if unavailable |
  | `Greeter` | 1 while `kscreenlocker_greet` is running |
  | `DeckVm` | 1 while `krfb-virtualmonitor` is running, i.e. the `Virtual-deck-vm` output exists |
  | `PlasmashellPid`, `PlasmashellFds`, `PlasmashellSyncFiles`, `PlasmashellFdLimit` | plasmashell fd usage and soft fd limit |
  | `SysOpenFiles` | system-wide open files (`/proc/sys/fs/file-nr`). Covers kwin, whose fds are not readable as this user. |
  | `UserSyncFiles`, `UserDmabufs` | `sync_file` and dma-buf fds summed over all of this user's readable processes |
  | `GpuMemMiB` | `nvidia-smi` GPU memory used |

  Collecting the session and fd columns takes ~230 ms per sample.
- `memwatch-<boot_id>.alerts` — ALERT and TREND messages (also sent to the journal via `logger -t memwatch`)
- `memwatch-<boot_id>.start` — marker for the first service start in that boot

### Alert policy

ALERTs are **latched**:

- `notify-send` fires once when the condition starts.
- While it continues, an `ALERT (ongoing)` reminder is sent every `ALERT_REPEAT_SEC=3600` seconds.
- A `CLEARED` line is written to the log (with no notification) when the condition ends.

TREND events go to the alert log only. They are skipped for the first `TREND_GRACE_SEC=300` seconds after boot, while the desktop is starting up.

Thresholds (KiB unless noted; each can be overridden via environment):

| Alert | Condition | Action |
|---|---|---|
| `sunreclaim_rate` | `SUnreclaim` rose > `SUNRECLAIM_RATE_KIB=262144` (256 MiB) over `SUNRECLAIM_RATE_WINDOW_SEC=1800` | ALERT + notify. This catches the greeter leak (~7.5 GiB/30 min) within ~30 min of onset. |
| `slab_pressure` | `Slab > SLAB_ALERT=10000000` (~9.5 GiB) or `SUnreclaim > SUNRECLAIM_ALERT=8000000` (~7.6 GiB) | ALERT + notify |
| `low_memavailable` | `MemAvailable < MEMAVAILABLE_ALERT=500000` (~488 MiB) | ALERT + notify |
| `plasmashell_fds` | plasmashell open fds ≥ `FD_ALERT_PCT=80`% of its soft limit | ALERT + notify; the message includes the restart command. Should rarely fire while the `__NV_DISABLE_EXPLICIT_SYNC=1` drop-in is in place. |
| `deck_while_locked` | `DeckVm=1` and (`Locked=1` or `Greeter=1`) | ALERT + notify: "disconnect Moonlight". Based on the unconfirmed hypothesis; a static lock with the Deck streaming did not leak (Finding 6). Disable with `DECK_LOCK_ALERT=0`. |
| trends | Slab / SUnreclaim rise or MemAvailable fall > `TREND_DELTA=2000000` over the last 8 samples | log only |

### Deployment history (2026-10-28)

The notify-only-on-ALERT change was made to `memwatch-service.sh` at 10:36 but was not live at first. The installed `~/.local/bin/memwatch.sh` was still the Oct 24 build, which called `notify-send` on every message.

At 11:45 the installer was re-run, and the installed script now matches the heredoc exactly. The service was then restarted at 11:46:15 (PID 619660), so the reduced alert policy has been live since then.

**Deploying a change:** edit the heredoc in `memwatch-service.sh`, run it, then run `systemctl --user restart memwatch.service`. The installer uses `enable --now`, which does **not** restart a service that is already running, so without the restart the old code keeps running.

### Changes on 2026-10-29

These were prompted by the leak: the old monitor first alerted 7.5 h after onset, then sent 927+ popups.

- Added the `sunreclaim_rate` alert and latching for all ALERTs.
- Added the lock-screen greeter and plasmashell fd columns, and the `plasmashell_fds` alert.
- Added the `Locked`, `DeckVm`, `SysOpenFiles`, `UserSyncFiles`, `UserDmabufs` and `GpuMemMiB` columns, and the `deck_while_locked` alert.
- The MemAvailable trend now uses `TREND_DELTA` instead of a hard-coded 500000. Added the post-boot trend grace period.
- Removed the duplicated start-marker block.
- The CSV is now written to a new `.v2.csv` file so that column formats are not mixed within a boot.

### Known limitations

- Monitor power state is not tracked: sysfs `dpms` reports `On` even for disconnected connectors on this driver, so it is unreliable.
- Whether a Moonlight client is connected and pulling frames is not tracked directly. `DeckVm` stands in for it, because the prep commands tie the virtual output to sessions, but it only shows that the output exists. A column from Sunshine's log or API would close this gap.
- Whether anything is rendering on the lock screen (media controls, animated wallpaper, screens on) is not tracked, and Finding 6 suggests it matters.
- The monitor cannot see per-cache growth, because `/proc/slabinfo` is root-only (mode 0400). If needed, add a separate root timer that logs the top 5 slab caches by size every few minutes. Track them by size rank, not by fixed name, since the `kmalloc-rnd-NN` names change every boot.

## Files in this directory

- `memwatch-service.sh` — **source of truth** for the service: installs `~/.local/bin/memwatch.sh` (from its heredoc) and `~/.config/systemd/user/memwatch.service`
- `memwatch.sh` — **not the service script.** An older (Sep 11) standalone foreground monitor that samples every 5s with per-slab-class detail and writes `memwatch-<timestamp>.log` / `.alerts.log` to the current directory. It has no `notify-send`. Its hard-coded slab names (`kmalloc-rnd-15-64` etc.) are only valid for the boot they were taken from. It has the same filename as the installed script, which caused confusion; consider renaming it (e.g. `memwatch-foreground.sh`).
- `status.sh` — read-only one-shot status report (no root): service health, alerts, CSV timeline, last 10 samples, lock episodes, rates and plasmashell fd-limit projection, live meminfo, top RSS processes, and top `sync_file` holders. Run `./status.sh`.
- `kmalloc64-leakers.bt` — bpftrace script that attributes 64-byte kmalloc allocations to call sites and counts frees within 15 s. Run as root.
- `README.md` — canonical summary for this investigation

Not included: the logs, meminfo/slabinfo snapshots and trace outputs gathered during the investigation (`.gitignore` excludes `*.log` and `*.txt`). The figures that matter are quoted above.

## Superseded interpretation

Before 2026-10-29 this note attributed the problem to metadata-heavy caches: `dentry`, `ext4_inode_cache`, `buffer_head`, `extent_status`, `trace_event_file`, `vm_area_struct`, `vmap_area`.

Those caches are large but mostly **reclaimable** (`SReclaimable`). The kernel shrinks them under pressure, and `MemAvailable` already counts much of them as available, so their size alone is not a leak.

The real signal was always `SUnreclaim`, and the leaking cache turned out to be a generic `kmalloc-rnd-*-64` cache. Earlier boots (Sep 11–17) with high slab were likely the same greeter-on-screen leak, but that was not verified.

`trace_event_file` at ~1.2 M objects (130 MiB) is unusually high and still unexplained. It is not growing like the main leak.
