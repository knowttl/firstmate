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

surface() {  # <home> [env assignments...]
  local home=$1
  shift
  env FM_HOME="$home" "$@" "$READY" surface
}

live_gates() {  # <home> [env assignments...]
  local home=$1
  shift
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  env "$@" bash -c '. "$1"; fm_ready_work_live_gates "$2"' _ "$READY" "$home/state"
}

test_surfaces_once_per_readiness_transition() {
  local home out
  home=$(make_home transition)
  axi "$home" add blocker "the blocker"
  axi "$home" add dependent "the dependent"
  axi "$home" block dependent --by blocker
  axi "$home" start blocker
  out=$(surface "$home")
  [ -z "$out" ] || fail "seeding a home with no record surfaced work: $out"
  [ -e "$home/state/.ready-work-surfaced" ] || fail "the seeding scan left no record"

  # Closed by hand, not by this home's teardown.
  axi "$home" "done" blocker
  out=$(surface "$home")
  [ "$out" = dependent ] || fail "a blocker closed outside teardown did not surface its dependent: '$out'"
  out=$(surface "$home")
  [ -z "$out" ] || fail "an unchanged ready item surfaced twice: $out"

  axi "$home" hold dependent --reason "wait"
  out=$(surface "$home")
  [ -z "$out" ] || fail "re-holding surfaced work: $out"
  axi "$home" unhold dependent
  out=$(surface "$home")
  [ "$out" = dependent ] || fail "released work did not surface as a new transition: '$out'"

  axi "$home" start dependent
  out=$(surface "$home")
  [ -z "$out" ] || fail "dispatched work surfaced: $out"
  grep -qx dependent "$home/state/.ready-work-surfaced" \
    && fail "dispatched work kept its surfaced marker"
  pass "ready work is surfaced once per readiness transition and its marker retires on dispatch"
}

test_date_gate_surfaces_when_due() {
  local home out
  home=$(make_home date-gate)
  axi "$home" add dated "deferred by the captain"
  axi "$home" hold dated --reason "revisit later" --kind captain --until "$EAST_TODAY"
  out=$(surface "$home" TZ=$WEST)
  [ -z "$out" ] || fail "seeding surfaced work: $out"
  [ "$(live_gates "$home" TZ=$WEST)" = 1 ] || fail "a future-dated captain hold is not a live gate"
  out=$(surface "$home" TZ=$WEST)
  [ -z "$out" ] || fail "a hold not yet due surfaced: $out"
  out=$(surface "$home" TZ=$EAST)
  [ "$out" = dated ] || fail "a captain hold whose date passed did not surface: '$out'"
  [ "$(live_gates "$home" TZ=$EAST)" = 0 ] || fail "a due hold still counts as a live gate"
  pass "a dated captain hold surfaces once its date arrives and stops needing a watcher"
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
    if fm_supervision_needed "$home/state" 300; then
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
    TZ=$WEST fm_supervision_needed "$home/state" 300 \
      || fail "live-gated queued work did not need supervision"
    [ "$FM_SUP_GATED" = 3 ] || fail "FM_SUP_GATED reported $FM_SUP_GATED"
  ) || exit 1

  printf 'manual\n' > "$home/config/backlog-backend"
  [ "$(live_gates "$home" TZ=$WEST)" = 0 ] || fail "a manual-backend home read its backlog"
  pass "only gates that can clear on their own count as supervision need"
}

test_watcher_wakes_once_for_a_cleared_blocker() {
  local dir state fakebin out pid
  dir=$(make_case watcher-ready)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  mkdir -p "$dir/data"
  cp "$ROOT/.tasks.toml" "$dir/.tasks.toml"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$dir/data/backlog.md"
  axi "$dir" add blocker "the blocker"
  axi "$dir" add dependent "the dependent"
  axi "$dir" block dependent --by blocker
  axi "$dir" start blocker
  [ -z "$(surface "$dir")" ] || fail "seeding surfaced work"
  axi "$dir" "done" blocker

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_READY_SCAN=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "the watcher did not wake for newly ready work"; }
  grep -Fx 'check: ready-work: dependent' "$out" >/dev/null \
    || fail "the watcher wake did not name the ready work: $(cat "$out")"
  grep -F "$(printf '\tcheck\tready-work\tcheck: ready-work: dependent')" "$state/.wake-queue" >/dev/null \
    || fail "the ready-work wake was not queued durably"

  ack_handled_wakes "$state" || fail "the ready-work wake could not be drained and acknowledged"
  : > "$out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_READY_SCAN=1 "$WATCH" > "$out" &
  pid=$!
  rm -f "$state/.last-ready-scan"
  wait_live "$pid" 40 || fail "the watcher woke again for already surfaced work: $(cat "$out")"
  [ -e "$state/.last-ready-scan" ] || { reap "$pid"; fail "the second watcher never ran a ready-work scan"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "the second watcher printed a wake: $(cat "$out")"
  pass "a real watcher wakes once for work a blocker closed outside teardown made ready"
}

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
test_live_gates_are_bounded
test_watcher_wakes_once_for_a_cleared_blocker
