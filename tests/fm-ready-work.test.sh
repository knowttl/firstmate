#!/usr/bin/env bash
# tests/fm-ready-work.test.sh - the ready-work backstop (bin/fm-ready-work.sh):
# queued backlog work that becomes ready without this home acting is surfaced
# once per readiness transition, live-gated queued work counts as supervision
# need only while its gate can clear on its own, and a real fm-watch.sh
# subprocess wakes exactly once for a blocker cleared outside teardown.
# Every home is a scratch directory with its own real tasks-axi backlog.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

command -v tasks-axi >/dev/null 2>&1 || { printf 'skip: tasks-axi not found\n'; exit 0; }

WATCH="$ROOT/bin/fm-watch.sh"
READY="$ROOT/bin/fm-ready-work.sh"
TMP_ROOT=$(fm_test_tmproot fm-ready-work-tests)

# A far-east date that is always later than today in a far-west zone, so one
# hold date reads as future under WEST and due under EAST without waiting.
EAST=Etc/GMT-14
WEST=Etc/GMT+12
EAST_TODAY=$(TZ=$EAST date +%F)

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

axi() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" "$@" >/dev/null || fail "tasks-axi $* failed in $home"
}

external_axi() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  tasks-axi "$@" --file "$home/data/backlog.md" >/dev/null \
    || fail "external tasks-axi $* failed in $home"
}

wake_ready() {  # <home> [env assignments...]
  local home=$1
  shift
  env FM_HOME="$home" "$@" "$READY" wake || fail "ready-work wake failed in $home"
}

ready_wake_count() {  # <home> <id>
  local queue="$1/state/.wake-queue"
  [ -f "$queue" ] || { printf '0\n'; return; }
  grep -Fc "check: ready-work: $2" "$queue" || true
}

live_gates() {  # <home> [env assignments...]
  local home=$1
  shift
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  env FM_HOME="$home" "$@" bash -c '. "$1"; fm_ready_work_live_gates "$2"' _ "$READY" "$home/state"
}

test_surfaces_once_per_readiness_transition() {
  local home
  home=$(make_home transition)
  axi "$home" add blocker "the blocker"
  axi "$home" add dependent "the dependent"
  axi "$home" block dependent --by blocker
  axi "$home" start blocker
  wake_ready "$home"
  [ "$(ready_wake_count "$home" dependent)" = 0 ] || fail "blocked work woke"

  # Closed by hand, not by this home's teardown.
  axi "$home" "done" blocker
  wake_ready "$home"
  [ "$(ready_wake_count "$home" dependent)" = 1 ] || fail "a cleared blocker did not wake its dependent"
  wake_ready "$home"
  [ "$(ready_wake_count "$home" dependent)" = 1 ] || fail "an unchanged ready item woke twice"

  axi "$home" hold dependent --reason "wait"
  wake_ready "$home"
  [ "$(ready_wake_count "$home" dependent)" = 1 ] || fail "re-holding woke dependent work"
  axi "$home" unhold dependent
  wake_ready "$home"
  [ "$(ready_wake_count "$home" dependent)" = 2 ] || fail "released work did not wake as a new transition"

  axi "$home" start dependent
  wake_ready "$home"
  [ "$(ready_wake_count "$home" dependent)" = 2 ] || fail "dispatched work woke"
  grep -qx dependent "$home/state/.ready-work-surfaced" \
    && fail "dispatched work kept its surfaced marker"
  pass "ready work is surfaced once per readiness transition and its marker retires on dispatch"
}

test_date_gate_surfaces_when_due() {
  local home
  home=$(make_home date-gate)
  axi "$home" add dated "deferred by the captain"
  axi "$home" hold dated --reason "revisit later" --kind captain --until "$EAST_TODAY"
  wake_ready "$home" TZ=$WEST
  [ "$(ready_wake_count "$home" dated)" = 0 ] || fail "a future gate woke"
  [ "$(live_gates "$home" TZ=$WEST)" = 1 ] || fail "a future-dated captain hold is not a live gate"
  wake_ready "$home" TZ=$WEST
  [ "$(ready_wake_count "$home" dated)" = 0 ] || fail "a hold not yet due woke"
  wake_ready "$home" TZ=$EAST
  [ "$(ready_wake_count "$home" dated)" = 1 ] || fail "a captain hold whose date passed did not wake"
  [ "$(live_gates "$home" TZ=$EAST)" = 0 ] || fail "a due hold still counts as a live gate"
  pass "a dated captain hold surfaces once its date arrives and stops needing a watcher"
}

test_first_scan_and_source_close() {
  local home state
  home=$(make_home first-scan)
  state="$home/state"
  axi "$home" add ready "ready from creation"
  axi "$home" add due "held until today"
  axi "$home" hold due --reason later --until "$EAST_TODAY"
  wake_ready "$home" TZ=$EAST
  [ "$(ready_wake_count "$home" due)" = 1 ] || fail "the first scan did not wake an already due gate"
  [ "$(ready_wake_count "$home" ready)" = 0 ] || fail "work ready from creation woke"
  wake_ready "$home" TZ=$EAST
  [ "$(ready_wake_count "$home" due)" = 1 ] || fail "the due gate woke twice"

  axi "$home" add blocker "a queued blocker"
  axi "$home" add dependent "dependent work"
  axi "$home" block dependent --by blocker
  axi "$home" "done" blocker
  grep -F 'check: ready-work: dependent' "$state/.wake-queue" >/dev/null \
    || fail "closing a queued blocker did not queue a dependent wake"
  wake_ready "$home"
  [ "$(ready_wake_count "$home" dependent)" = 1 ] || fail "a source wake repeated through the scanner"
  pass "a first due scan surfaces its gate and a queued close wakes its dependent"
}

test_alternate_state_keeps_home_backlog() {
  local home state
  home=$(make_home alternate-state)
  state="$home/other-state"
  mkdir -p "$state"
  axi "$home" add due "held until today"
  axi "$home" hold due --reason later --until "$EAST_TODAY"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" TZ=$EAST "$READY" wake
  grep -F 'check: ready-work: due' "$state/.wake-queue" >/dev/null \
    || fail "alternate state read the wrong backlog"
  pass "an alternate state directory still reads the configured home backlog"
}

test_live_gates_are_bounded() {
  local home
  home=$(make_home undated)
  axi "$home" add question "a captain call"
  axi "$home" hold question --reason "captain decides" --kind captain
  axi "$home" add after-question "gated on the call"
  axi "$home" block after-question --by question
  axi "$home" add queued-ready "waiting on this home to dispatch it"
  axi "$home" add after-ready "gated on undispatched work"
  axi "$home" block after-ready --by queued-ready
  [ "$(live_gates "$home")" = 0 ] \
    || fail "undated holds or undispatched blockers counted as live gates: $(live_gates "$home")"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-supervision-lib.sh"
    if FM_HOME="$home" fm_supervision_needed "$home/state" 300; then
      fail "a home with only undated holds gained a watcher need"
    fi
  ) || exit 1

  home=$(make_home live)
  axi "$home" add running "in flight"
  axi "$home" start running
  axi "$home" add after-running "gated on in-flight work"
  axi "$home" block after-running --by running
  axi "$home" add dated "future date"
  axi "$home" hold dated --reason later --until "$EAST_TODAY"
  axi "$home" add after-dated "gated on a dated item"
  axi "$home" block after-dated --by dated
  [ "$(live_gates "$home" TZ=$WEST)" = 3 ] \
    || fail "in-flight, dated, and inherited gates were not all live: $(live_gates "$home" TZ=$WEST)"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-supervision-lib.sh"
    FM_HOME="$home" TZ=$WEST fm_supervision_needed "$home/state" 300 \
      || fail "live-gated queued work did not need supervision"
    [ "$FM_SUP_GATED" = 3 ] || fail "FM_SUP_GATED reported $FM_SUP_GATED"
  ) || exit 1

  printf 'manual\n' > "$home/config/backlog-backend"
  [ "$(live_gates "$home" TZ=$WEST)" = 0 ] || fail "a manual-backend home read its backlog"
  pass "only gates that can clear on their own count as supervision need"
}

test_watcher_wakes_once_for_a_cleared_blocker() (
  local dir state socket_dir out pid
  dir=$(make_home watcher-ready)
  state="$dir/state"; socket_dir="$dir/tmux"; out="$dir/watch.out"
  mkdir -p "$socket_dir"
  TMUX_TMPDIR="$socket_dir" TMUX='' tmux new-session -d -s fm-ready-work-test \
    || fail "could not start an isolated tmux server"
  trap 'TMUX_TMPDIR="$socket_dir" TMUX="" tmux kill-server >/dev/null 2>&1 || true' EXIT
  axi "$dir" add blocker "the blocker"
  axi "$dir" add dependent "the dependent"
  axi "$dir" block dependent --by blocker
  axi "$dir" start blocker
  wake_ready "$dir"
  external_axi "$dir" "done" blocker
  [ ! -s "$state/.wake-queue" ] || fail "setup queued a wake before the watcher: $(cat "$state/.wake-queue"); $(FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" list --fields blocked,blocked_by,held,hold_until)"

  TMUX_TMPDIR="$socket_dir" TMUX='' FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "the watcher did not wake for newly ready work"; }
  grep -Fx 'check: ready-work: dependent' "$out" >/dev/null \
    || fail "the watcher wake did not name the ready work: $(cat "$out")"
  grep -F "$(printf '\tcheck\tready-work\tcheck: ready-work: dependent')" "$state/.wake-queue" >/dev/null \
    || fail "the ready-work wake was not queued durably"

  ack_handled_wakes "$state" || fail "the ready-work wake could not be drained and acknowledged"
  : > "$out"
  TMUX_TMPDIR="$socket_dir" TMUX='' FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  rm -f "$state/.last-ready-scan"
  wait_live "$pid" 40 || fail "the watcher woke again for already surfaced work: $(cat "$out")"
  [ -e "$state/.last-ready-scan" ] || { reap "$pid"; fail "the second watcher never ran a ready-work scan"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "the second watcher printed a wake: $(cat "$out")"
  pass "a real watcher wakes once for work a blocker closed outside teardown made ready"
)

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# Drain the queue and run the generation-bound acknowledgement the drain
# prints, as a supervisor does after handling its wakes.
ack_handled_wakes() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-drain.err"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" \
    --recovery-generation "$generation" >/dev/null 2>&1
}

wait_live() {  # <pid> [ticks]
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

test_surfaces_once_per_readiness_transition
test_date_gate_surfaces_when_due
test_first_scan_and_source_close
test_alternate_state_keeps_home_backlog
test_live_gates_are_bounded
test_watcher_wakes_once_for_a_cleared_blocker
