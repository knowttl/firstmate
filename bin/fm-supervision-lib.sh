# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# True when a firstmate home has in-flight work (a state/<id>.meta exists) but no
# watcher can be trusted to be supervising it. The beacon (state/.last-watcher-beat,
# touched every poll cycle) must be within the grace window - but a fresh beacon
# alone is not proof of health, because a watcher can DIE leaving a recently-touched
# beacon behind. The watcher singleton lock disambiguates the two cases that share a
# fresh beacon:
#   - lock ABSENT: a watcher that exits cleanly on a wake releases its lock, so an
#     absent lock is the normal, tolerated gap between a fire and the re-arm - still
#     healthy within the grace window (the pull guard must not false-alarm on every
#     wake). The turn-end hook, which requires the re-arm to have happened by then,
#     is stricter and blocks on an absent lock via fm_watcher_healthy.
#   - lock PRESENT but DEAD: it names a pid that is not alive, carries no identity,
#     or whose identity no longer matches (a reused pid). That is the signature of a
#     watcher that died UNCLEANLY (a crash, a SIGKILL, a reaped pane) and will not
#     re-arm itself - the real silent gap. This now reads as unhealthy IMMEDIATELY,
#     regardless of how fresh the leftover beacon is, instead of staying silent until
#     the beacon ages out of the grace window.
# bin/fm-guard.sh uses this predicate directly for its warning; bin/fm-turnend-guard.sh
# uses the status fields here for its banner and makes its own end-of-turn block
# decision with the live watcher lock check in bin/fm-wake-lib.sh.

# fm_supervision_status needs fm_pid_alive/fm_pid_identity to prove the beacon is
# backed by a live watcher rather than a recent mtime. Source their owner
# (bin/fm-wake-lib.sh) once if the caller has not already; both real callers source
# it themselves, and re-sourcing is idempotent (function defs, mkdir -p).
if ! command -v fm_pid_alive >/dev/null 2>&1; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-wake-lib.sh"
fi

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_sup_watcher_process_live <state-dir>
# True (0) only when the watcher singleton lock names a process that is genuinely
# still this home's watcher: the recorded pid is alive, an identity was recorded
# when it claimed the lock, and that process's current identity still matches. A
# dead pid, a missing identity, or a reused pid (identity no longer matches) all
# fail. This is the check the beacon mtime cannot make on its own - a stale-but-live
# process and a fresh-beacon-but-dead watcher are indistinguishable by mtime.
fm_sup_watcher_process_live() {
  local state=$1 lockdir pid recorded current
  lockdir="$state/.watch.lock"
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  recorded=$(cat "$lockdir/pid-identity" 2>/dev/null || true)
  [ -n "$recorded" ] || return 1
  current=$(fm_pid_identity "$pid") || return 1
  [ "$current" = "$recorded" ]
}

# fm_sup_watcher_lock_is_dead <state-dir>
# True (0) when a watcher singleton lock EXISTS but does not name a genuinely live,
# identity-matched watcher - the signature of a watcher that died uncleanly and left
# its lock behind, or whose pid the OS recycled onto an unrelated process. An ABSENT
# lock is deliberately NOT "dead": a watcher that exits cleanly on a wake releases
# its lock, so an absent lock is the normal fire-to-re-arm gap, left to the beacon
# grace window to tolerate. This is what lets the pull guard stay silent right after
# a normal fire yet still catch a watcher that crashed with a fresh beacon.
fm_sup_watcher_lock_is_dead() {
  local state=$1 lockdir
  lockdir="$state/.watch.lock"
  [ -e "$lockdir" ] || [ -L "$lockdir" ] || return 1
  fm_sup_watcher_process_live "$state" && return 1
  return 0
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_WATCHER_FRESH  true/false - the beacon is within the grace window AND the
#                         watcher lock is not held by a dead/reused pid (an absent
#                         lock within grace is the tolerated fire-to-re-arm gap)
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta beat m age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done

  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      # A recent beacon is necessary but NOT sufficient: a watcher lock naming a
      # dead/reused pid means the watcher died uncleanly and the fresh beacon is a
      # leftover. An absent lock within grace is the normal fire-to-re-arm gap and
      # stays healthy.
      [ "$age" -lt "$grace" ] && ! fm_sup_watcher_lock_is_dead "$state" && FM_SUP_WATCHER_FRESH=true
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly in the dangerous state: in-flight work exists and no
# trustworthy watcher is fresh (a stale beacon, or a dead/reused watcher lock).
# Exit 1 (false) otherwise, including zero in-flight.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_IN_FLIGHT" -gt 0 ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}
