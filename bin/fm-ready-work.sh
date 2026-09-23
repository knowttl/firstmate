#!/usr/bin/env bash
# fm-ready-work.sh - the ready-work backstop: surface queued backlog work that
# became dispatchable without this home acting, and report whether gated queued
# work still needs a watcher to notice it.
#
# Usage: fm-ready-work.sh surface|wake
#   Surface queued task ids released by a date or blocker gate since the last
#   delivery; wake appends them to the durable wake queue.
# Sourced (. bin/fm-ready-work.sh): fm_ready_work_scan, fm_ready_work_commit,
# fm_ready_work_release (bin/fm-watch.sh), and fm_ready_work_live_gates
# (bin/fm-supervision-lib.sh).
#
# WHY. Queued work gated on a date (`tasks-axi hold --until`, including captain
# holds deferred with bin/fm-captain-hold.sh --until) or on blockers can become
# ready without any turn in this home: a date passes, or a blocker is closed by a
# captain answer, a hand-run backlog close, or work elsewhere. Teardown and
# session start re-evaluate the queue, but nothing else did, so such work waited
# for the next unrelated teardown or session start.
#
# READINESS is tasks-axi's own derivation, read from one `tasks-axi list` through
# bin/fm-tasks-axi.sh: its derived `blocked` and `held` fields already apply
# dependency state and compare hold dates to the local date. Ready means queued,
# not blocked, not held, and not a public-followup obligation, which is never
# dispatchable - the same set `tasks-axi ready` lists.
#
# ONCE PER TRANSITION. state/.ready-work-surfaced lists gated ready ids already
# surfaced. A scan reports gated ready ids missing from it; the caller commits
# the current gated ready set only after delivery. An id leaves the record when
# it is dispatched, closed, or re-held, so its next readiness is new again.
# state/.ready-work.lock serializes scan-to-commit across callers, so one
# transition is reported by exactly one of them.
#
# LIVE GATES (supervision need). A queued item's gate is live when it can clear
# without this home acting: a hold with a future date, or a blocker that is in
# flight or itself live-gated. An undated hold - or a blocker chain that ends in
# one, or in queued ready work this home has not dispatched - waits on this
# home's own next turn, so it never keeps a watcher alive; a dated gate keeps one
# only until its date, when the scan surfaces the item and the gate stops
# counting.
#
# STEPPING ASIDE. tasks-axi missing from PATH, config/backlog-backend=manual, a
# missing data directory, a markdown home with no backlog file, or a listing that
# fails, times out (FM_READY_WORK_TIMEOUT seconds, default 10), or cannot be
# parsed all mean nothing to surface and no need: this backstop never blocks a
# turn or a teardown on its own failure. The home's data and config directories
# come from FM_HOME unless FM_DATA_OVERRIDE / FM_CONFIG_OVERRIDE name them.

FM_READY_WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_READY_WORK_ELIGIBLE=
FM_READY_WORK_LIVE=0
FM_READY_WORK_NEW=
FM_READY_WORK_LOCK=

# Classify one `tasks-axi list` listing. Prints `eligible <id>` per gated ready item and
# a final `live <count>`; exits 2 when the listing lacks the expected table.
fm_ready_work_classify() {
  LC_ALL=C awk '
    function split_row(line, out,   n, i, c, field, inq, esc) {
      n = 0; field = ""; inq = 0; esc = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (esc) { field = field c; esc = 0; continue }
        if (inq) {
          if (c == "\\") { esc = 1; continue }
          if (c == "\"") { inq = 0; continue }
          field = field c
          continue
        }
        if (c == "\"") { inq = 1; continue }
        if (c == ",") { out[++n] = field; field = ""; continue }
        field = field c
      }
      out[++n] = field
      return n
    }
    /^tasks: / { table = 1; next }
    /^tasks\[[0-9]+\]\{/ {
      header = $0
      sub(/^[^{]*\{/, "", header)
      sub(/\}:.*$/, "", header)
      ncol = split(header, cols, ",")
      for (i = 1; i <= ncol; i++) col[cols[i]] = i
      table = 1
      rows = 1
      next
    }
    rows && /^  / {
      line = substr($0, 3)
      split_row(line, f)
      id = f[col["id"]]
      n++
      ids[n] = id
      state[id] = f[col["state"]]
      kind[id] = f[col["kind"]]
      blocked[id] = f[col["blocked"]]
      held[id] = f[col["held"]]
      until[id] = f[col["hold_until"]]
      blockers[id] = f[col["blocked_by"]]
      deps[id] = f[col["deps"]]
      next
    }
    { rows = 0 }
    END {
      if (!table) exit 2
      if (n > 0 && !("id" in col && "state" in col && "kind" in col && "blocked" in col \
          && "blocked_by" in col && "deps" in col && "held" in col && "hold_until" in col)) exit 2
      for (i = 1; i <= n; i++) {
        id = ids[i]
        if (state[id] != "queued" || kind[id] == "public-followup") continue
        if (blocked[id] == "no" && held[id] == "no") {
          if (deps[id] != "none" && deps[id] != "-" && deps[id] != "" \
              || until[id] != "-" && until[id] != "") print "eligible " id
        }
        if (held[id] == "yes" && until[id] != "-" && until[id] != "") live[id] = 1
      }
      # A blocked item is live when any open blocker is in flight or live itself;
      # iterate to the fixpoint so a chain inherits its root gate. An undated
      # hold stays not live even when blocked, since only this home releases it.
      do {
        changed = 0
        for (i = 1; i <= n; i++) {
          id = ids[i]
          if (state[id] != "queued" || live[id] || blocked[id] != "yes") continue
          if (held[id] == "yes" && (until[id] == "-" || until[id] == "")) continue
          m = split(blockers[id], bs, ",")
          for (j = 1; j <= m; j++) {
            b = bs[j]
            if (state[b] == "in_flight" || live[b]) { live[id] = 1; changed = 1; break }
          }
        }
      } while (changed)
      count = 0
      for (id in live) if (live[id]) count++
      print "live " count
    }
  '
}

# fm_ready_work_read <state-dir>
# Sets FM_READY_WORK_ELIGIBLE (sorted gated ready ids, one per line) and
# FM_READY_WORK_LIVE (live-gated queued count). Returns 0 on a good read, 1 when
# this home has no readable tasks-axi backlog (see STEPPING ASIDE).
fm_ready_work_read() {
  local state=$1 home data config root backend listing classified
  FM_READY_WORK_ELIGIBLE=
  FM_READY_WORK_LIVE=0
  home=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$FM_READY_WORK_DIR/.." && pwd)}}
  data=${FM_DATA_OVERRIDE:-$home/data}
  config=${FM_CONFIG_OVERRIDE:-$home/config}
  [ -d "$data" ] || return 1
  command -v tasks-axi >/dev/null 2>&1 || return 1
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  command -v fm_tasks_axi_backend >/dev/null 2>&1 \
    || . "$FM_READY_WORK_DIR/fm-tasks-axi-lib.sh" || return 1
  fm_backlog_backend_manual "$config" && return 1
  root=$(CDPATH='' cd -- "$data/.." 2>/dev/null && pwd -P) || return 1
  backend=$(fm_tasks_axi_backend "$root" 2>/dev/null) || return 1
  if [ "$backend" = markdown ] && [ ! -e "$data/backlog.md" ]; then
    return 1
  fi
  # shellcheck source=bin/fm-timeout-lib.sh
  command -v fm_run_timed >/dev/null 2>&1 \
    || . "$FM_READY_WORK_DIR/fm-timeout-lib.sh" || return 1
  listing=$(FM_HOME="$home" FM_DATA_OVERRIDE="$data" \
    fm_run_timed "${FM_READY_WORK_TIMEOUT:-10}" \
    "$FM_READY_WORK_DIR/fm-tasks-axi.sh" list --fields blocked,blocked_by,deps,held,hold_until \
    2>/dev/null </dev/null) || return 1
  classified=$(printf '%s\n' "$listing" | fm_ready_work_classify) || return 1
  FM_READY_WORK_ELIGIBLE=$(printf '%s\n' "$classified" | sed -n 's/^eligible //p' | LC_ALL=C sort -u)
  FM_READY_WORK_LIVE=$(printf '%s\n' "$classified" | sed -n 's/^live //p')
  case "$FM_READY_WORK_LIVE" in ''|*[!0-9]*) FM_READY_WORK_LIVE=0; return 1 ;; esac
  return 0
}

# fm_ready_work_live_gates <state-dir>: print the live-gated queued count.
fm_ready_work_live_gates() {
  if fm_ready_work_read "$1"; then
    printf '%s\n' "$FM_READY_WORK_LIVE"
  else
    printf '0\n'
  fi
}

# fm_ready_work_scan <state-dir>
# Takes state/.ready-work.lock, reads the backlog, and sets FM_READY_WORK_NEW to
# the space-separated gated ready ids not yet surfaced. Returns 0 with the lock held, to be finished by
# fm_ready_work_commit; returns 1 with no lock held when there is nothing to
# read or the lock stays contended.
fm_ready_work_scan() {
  local state=$1 record
  FM_READY_WORK_NEW=
  # shellcheck source=bin/fm-wake-lib.sh
  command -v fm_lock_acquire_wait_bounded >/dev/null 2>&1 \
    || . "$FM_READY_WORK_DIR/fm-wake-lib.sh" || return 1
  FM_READY_WORK_LOCK="$state/.ready-work.lock"
  fm_lock_acquire_wait_bounded "$FM_READY_WORK_LOCK" "${FM_READY_WORK_TIMEOUT:-10}" || return 1
  if ! fm_ready_work_read "$state"; then
    fm_ready_work_release
    return 1
  fi
  record="$state/.ready-work-surfaced"
  [ -e "$record" ] || record=/dev/null
  FM_READY_WORK_NEW=$(printf '%s\n' "$FM_READY_WORK_ELIGIBLE" | LC_ALL=C awk '
    FILENAME == ARGV[1] { if ($0 != "") seen[$0] = 1; next }
    $0 != "" && !($0 in seen) { printf "%s%s", sep, $0; sep = " " }
  ' "$record" -)
  return 0
}

# fm_ready_work_commit <state-dir>: record the scanned gated ready set as surfaced and
# release the scan lock.
fm_ready_work_commit() {
  local state=$1 record tmp status=0
  record="$state/.ready-work-surfaced"
  if tmp=$(mktemp "$state/.ready-work-surfaced.XXXXXX"); then
    if [ -n "$FM_READY_WORK_ELIGIBLE" ]; then
      printf '%s\n' "$FM_READY_WORK_ELIGIBLE" > "$tmp" || status=1
    fi
    if [ "$status" -eq 0 ]; then
      mv -f -- "$tmp" "$record" || status=1
    fi
    [ "$status" -eq 0 ] || rm -f -- "$tmp"
  else
    status=1
  fi
  fm_ready_work_release
  return "$status"
}

fm_ready_work_release() {
  [ -n "$FM_READY_WORK_LOCK" ] || return 0
  fm_lock_release "$FM_READY_WORK_LOCK" || true
  FM_READY_WORK_LOCK=
}

fm_ready_work_main() {
  local state mode
  case "${1:-}" in
    surface|wake) mode=$1 ;;
    -h|--help)
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      return 0
      ;;
    *)
      printf 'usage: fm-ready-work.sh surface|wake\n' >&2
      return 2
      ;;
  esac
  state=${FM_STATE_OVERRIDE:-${FM_HOME:-$(cd "$FM_READY_WORK_DIR/.." && pwd)}/state}
  fm_ready_work_scan "$state" || return 0
  if [ -n "$FM_READY_WORK_NEW" ]; then
    if [ "$mode" = wake ]; then
      . "$FM_READY_WORK_DIR/fm-wake-lib.sh"
      fm_wake_append check ready-work "check: ready-work: $FM_READY_WORK_NEW" || {
        fm_ready_work_release
        return 1
      }
    else
      printf '%s\n' "$FM_READY_WORK_NEW" || {
        fm_ready_work_release
        return 1
      }
    fi
  fi
  fm_ready_work_commit "$state"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_ready_work_main "$@"
fi
