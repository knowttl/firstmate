#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# Read one process's parent, command name, and full argument string into
# FM_ROW_PPID / FM_ROW_COMM / FM_ROW_ARGS. Returns 1 when the pid is gone or
# unreadable.
#
# Prefer /proc, which needs no fork at all; the ps snapshot is the portable
# fallback for hosts without a Linux-format /proc (macOS). The snapshot is taken
# at most once per shell because a single ps costs about half a second on a
# loaded machine.
FM_ROW_PPID=
FM_ROW_COMM=
FM_ROW_ARGS=
FM_PROCESS_SNAPSHOT=
fm_process_row() {  # <pid>
  local pid=$1 proc_root stat_line rest arg row_pid found
  FM_ROW_PPID=; FM_ROW_COMM=; FM_ROW_ARGS=
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/$pid/stat" ]; then
    IFS= read -r stat_line < "$proc_root/$pid/stat" 2>/dev/null || return 1
    # "<pid> (<comm>) <state> <ppid> ...", where comm may contain spaces and
    # parentheses: take it between the first "(" and the LAST ")".
    FM_ROW_COMM=${stat_line#*(}
    FM_ROW_COMM=${FM_ROW_COMM%)*}
    rest=${stat_line##*)}
    # After the comm delimiter the fields are "<state> <ppid> ...".
    read -r _ FM_ROW_PPID _ <<< "$rest"
    case "$FM_ROW_PPID" in
      ''|*[!0-9]*) FM_ROW_PPID=; FM_ROW_COMM=; return 1 ;;
    esac
    if [ -r "$proc_root/$pid/cmdline" ]; then
      while IFS= read -r -d '' arg; do
        FM_ROW_ARGS="$FM_ROW_ARGS $arg"
      done < "$proc_root/$pid/cmdline"
    fi
    return 0
  fi
  if [ -z "$FM_PROCESS_SNAPSHOT" ]; then
    FM_PROCESS_SNAPSHOT=$(ps -A -o pid= -o ppid= -o comm= -o args= 2>/dev/null) || return 1
    [ -n "$FM_PROCESS_SNAPSHOT" ] || return 1
  fi
  found=0
  while read -r row_pid FM_ROW_PPID FM_ROW_COMM FM_ROW_ARGS; do
    [ "$row_pid" = "$pid" ] || continue
    found=1
    break
  done <<EOF
$FM_PROCESS_SNAPSHOT
EOF
  [ "$found" -eq 1 ] || { FM_ROW_PPID=; FM_ROW_COMM=; FM_ROW_ARGS=; return 1; }
  return 0
}

# Walk the current process ancestry (up to 16 hops) and print a harness pid.
# For every harness except Claude, the first match wins (innermost pid), which
# is where e.g. Pi's shared signed-wrapper ancestry actually holds the session:
# a "pi-signed" launcher can be the direct parent of the inner "pi" engine
# pid that owns the lock, and the wrapper pid above it is not that owner.
# Claude Code's bg-spare hook worker chain is the opposite shape: it nests
# several claude-named processes directly parent-child with no non-harness
# process between them, and the lock is held by the outermost pid of that
# run. So once a claude-named match is found, this keeps walking past it
# looking for a still-more-ancestral claude-named match, and stops the
# instant a non-match follows - never walking past that gap to an unrelated
# claude-named process further up the real process tree (e.g. the live
# session that launched a test as its own subprocess). The harness pid lives
# as long as the session, unlike the transient subshell pid of any one tool
# call.
#
# One process-table snapshot, then a fork-free walk. Latency is load-bearing:
# bin/fm-claude-stop-autoarm.sh resolves ancestry before it may claim a home,
# and bin/fm-turnend-guard.sh --claude allows a stop only if that claim lands
# inside FM_CLAUDE_AUTOARM_SYNC_WAIT_MS. Per-hop ps/basename/grep forks put the
# walk at 2.5-3.3s on a loaded machine (measured 2026-07-27), far past that
# window, so the guard blocked turns whose auto-arm was working normally.
fm_harness_ancestry_pid() {
  local pid=$$ best='' bc extending=0 hit=0 is_claude=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    fm_process_row "$pid" || break
    bc=${FM_ROW_COMM##*/}
    hit=0; is_claude=0
    if [[ $bc =~ $FM_HARNESS_RE ]]; then
      hit=1
      case "$bc" in *claude*) is_claude=1 ;; esac
    else
      # Bare interpreter (e.g. node): match the harness name in its script path.
      case "$FM_ROW_COMM" in
        *node*|*python*)
          if [[ $FM_ROW_ARGS =~ $FM_HARNESS_RE ]]; then
            hit=1
            case "$FM_ROW_ARGS" in *claude*) is_claude=1 ;; esac
          fi
          ;;
      esac
    fi
    if [ "$hit" -eq 1 ]; then
      best="$pid"
      if [ "$is_claude" -eq 1 ]; then
        extending=1
      else
        break
      fi
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$FM_ROW_PPID
    case "$pid" in
      ''|*[!0-9]*) break ;;
    esac
    [ "$pid" -gt 1 ] || break
  done
  [ -n "$best" ] && { echo "$best"; return 0; }
  return 1
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  if printf '%s' "$(basename "$comm")" | grep -qE "$FM_HARNESS_RE"; then
    return 0
  fi
  case "$comm" in
    *node*|*python*)
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"
      ;;
    *) return 1 ;;
  esac
}

# True when state dir $1 holds a session lock whose pid is the harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. A missing lock, a lock held by another live harness, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid my_pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  my_pid=$(fm_harness_ancestry_pid) || return 1
  [ "$my_pid" = "$lock_pid" ]
}
