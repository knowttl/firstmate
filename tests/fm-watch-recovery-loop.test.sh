#!/usr/bin/env bash
# Pin the Pi/OpenCode recovery-loop fix: one announcement per generation, and a
# handling successor that keeps supervising instead of going blind.
# Also pin the close-time convergence boundary: a healthy home with nothing to
# resurface settles instead of re-announcing every cycle, while a close that
# leaves durable wakes or an open decision behind still recovers.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-recovery-loop)
export NODE_NO_WARNINGS=1

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox" \
    "$repo/bin"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent {
  render() { return []; }
  invalidate() {}
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box {
  addChild() {}
  clear() {}
  setBgFn() {}
}
export class Container {}
export class Text {}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) {
    return { type: "object", properties, additionalProperties: false };
  },
};
JS
}

# T1: a lost --handling-delivered handshake must not re-announce forever.
# The real Pi extension drives the real arm/watcher, with only the handshake
# RPC forced to fail. After the first recovery follow-up, wait past the old
# ~52s loop period so a regression would emit a second follow-up.
test_unacknowledged_recovery_is_announced_once_per_generation() {
  local repo home plugin fakebin out status lock_pid messages
  repo="$TMP_ROOT/t1-root"
  home="$TMP_ROOT/t1-home"
  fakebin="$TMP_ROOT/t1-fakebin"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$fakebin"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$repo/bin/fm-watch-arm.sh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --handling-delivered ]; then
  exit 1
fi
export FM_ROOT_OVERRIDE="$ROOT"
export PATH="$fakebin:\$PATH"
exec "$ROOT/bin/fm-watch-arm.sh" "\$@"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  : > "$home/state/seed.meta"
  printf 'pending:downtime:seed.1.aaa\n' > "$home/state/.watcher-down"
  chmod 600 "$home/state/.watcher-down"
  printf '%s\t1\tcheck\tseed\tcheck: seed recovery\n' "$(date +%s)" > "$home/state/.wake-queue"
  out=$(
    PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
      FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$PATH" \
      FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const prompts = [];
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompts.push(String(message));
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");
await tool.execute("tool-call-t1", {}, undefined, undefined, {});
const deadline = Date.now() + 75000;
let firstAt = 0;
while (Date.now() < deadline) {
  const rearm = prompts.filter((message) => message.includes("check: rearm-resurface"));
  if (rearm.length > 1) {
    throw new Error(`unbounded recovery loop: ${rearm.length} rearm-resurface follow-ups`);
  }
  if (rearm.length === 1 && firstAt === 0) firstAt = Date.now();
  if (firstAt && Date.now() - firstAt >= 55000) break;
  await new Promise((resolve) => setTimeout(resolve, 200));
}
const rearm = prompts.filter((message) => message.includes("check: rearm-resurface"));
if (rearm.length !== 1) {
  throw new Error(`expected exactly one recovery follow-up, got ${rearm.length}: ${prompts.join(" || ")}`);
}
const lockPid = existsSync(`${process.env.FM_HOME}/state/.watch.lock/pid`)
  ? readFileSync(`${process.env.FM_HOME}/state/.watch.lock/pid`, "utf8").trim()
  : "";
if (!/^[0-9]+$/.test(lockPid)) throw new Error("successor watcher lock pid missing");
try {
  process.kill(Number(lockPid), 0);
} catch {
  throw new Error(`successor watcher ${lockPid} is not alive`);
}
const marker = readFileSync(`${process.env.FM_HOME}/state/.watcher-down`, "utf8").trim();
if (!marker.startsWith("announced:") && !marker.startsWith("pending:")) {
  throw new Error(`successor did not keep a live recovery episode: ${marker}`);
}
console.log(`T1_MESSAGES=${rearm.length}`);
console.log(`T1_LOCK_PID=${lockPid}`);
console.log(`T1_MARKER=${marker}`);
process.exit(0);
EOF
  )
  status=$?
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '%s\n' "$out"
  fi
  lock_pid=$(sed -n 's/^T1_LOCK_PID=//p' <<<"$out" | tail -1)
  messages=$(sed -n 's/^T1_MESSAGES=//p' <<<"$out" | tail -1)
  if [ -n "$lock_pid" ]; then
    kill -TERM "$lock_pid" 2>/dev/null || true
  fi
  expect_code 0 "$status" "an unacknowledged recovery must be announced at most once per generation: $out"
  [ "$messages" = 1 ] || fail "T1 did not report a single recovery follow-up: $out"
  pass "unacknowledged recovery is announced at most once per generation and the successor stays alive"
}

# T2: a handling successor must enter its poll loop and surface a real crew
# event within a bounded startup-and-poll budget instead of sitting in a
# pre-loop wait that refreshes the liveness beacon and then exits with a
# synthetic rearm-resurface.
test_handling_successor_does_not_go_blind() {
  local dir home state fakebin child event_start now out
  dir=$(make_case recovery-gap-successor)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  : > "$state/crew.meta"
  printf 'pending:downtime:gap.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$out" 2>&1 &
  child=$!
  now=0
  while [ "$now" -lt 40 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] && break
    sleep 0.1
    now=$((now + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not take the watcher lock"; }
  sleep 0.4
  printf 'done: crew finished its task\n' >> "$state/crew.status"
  event_start=$(date +%s)
  now=0
  while [ "$now" -lt 20 ]; do
    if grep -q '^signal:' "$out" 2>/dev/null; then
      break
    fi
    sleep 0.5
    now=$((now + 1))
  done
  if ! grep -q '^signal:' "$out" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "handling successor did not surface the crew event within the bounded startup-and-poll budget (waited $(( $(date +%s) - event_start ))s): $(cat "$out")"
  fi
  grep -F 'crew.status' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not name the crew status file: $(cat "$out")"; }
  grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not enqueue a durable row for the crew event"; }
  ! grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor emitted synthetic recovery instead of supervising: $(cat "$out")"; }
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf 'T2_WATCH_OUTPUT=%s\n' "$(tr '\n' ' ' < "$out")"
    printf 'T2_QUEUE_ROW=%s\n' "$(grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" | tail -1)"
  fi
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  pass "a resurfacing handling successor stays alive and supervises instead of going blind"
}


# Run one real watcher against <state> until it closes on its own or the bound
# expires, then stop it. Echoes the watcher's stdout (its wake reason, if any).
run_watch_cycle() {  # <dir> <state> <home> <label>
  local dir=$1 state=$2 home=$3 label=$4 out child i
  out="$dir/watch-$label.out"
  PATH="$dir/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" 2>&1 &
  child=$!
  i=0
  while [ "$i" -lt 40 ] && is_live_non_zombie "$child"; do
    sleep 0.2
    i=$((i + 1))
  done
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  tr '\n' ' ' < "$out"
}

# T3: a provably healthy home with nothing to resurface must converge. Every
# one-shot watcher close used to open a fresh recovery generation, so the next
# drain demanded an acknowledgement turn for an empty queue on every cycle.
test_healthy_home_with_nothing_queued_converges() {
  local dir state home i err reason cycle_acks
  dir=$(make_case healthy-converges)
  state="$dir/state"
  home="$dir/home"
  mkdir -p "$home/data"
  : > "$state/crew.meta"
  : > "$state/.wake-queue"
  chmod 600 "$state/.wake-queue"
  cycle_acks=0
  i=0
  while [ "$i" -lt 3 ]; do
    reason=$(run_watch_cycle "$dir" "$state" "$home" "healthy-$i")
    case "$reason" in
      *rearm-resurface*) fail "healthy close $i emitted a synthetic recovery wake: $reason" ;;
    esac
    err="$dir/drain-$i.err"
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" \
      >/dev/null 2> "$err" || fail "drain after healthy close $i failed"
    if grep -q '^WAKE_ACK_REQUIRED:' "$err"; then
      cycle_acks=$((cycle_acks + 1))
      ack_drain_err "$state" "$err" || fail "acknowledgement after healthy close $i failed"
    fi
    i=$((i + 1))
  done
  [ "$cycle_acks" -eq 0 ] \
    || fail "a healthy home demanded $cycle_acks acknowledgement turns with nothing queued"
  [ ! -e "$state/.watcher-down" ] \
    || fail "healthy close left a recovery episode open: $(cat "$state/.watcher-down")"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf 'T3_ACK_DEMANDS=%s\n' "$cycle_acks"
  fi
  pass "a healthy home with nothing to resurface converges instead of re-announcing"
}

# T4: the same close must STILL open a recovery episode when the down interval
# would otherwise bury work - queued durable wakes, or an unchanged open
# captain decision the next arm has to re-present.
test_close_with_work_pending_still_recovers() {
  local dir state home reason err
  dir=$(make_case down-still-recovers)
  state="$dir/state"
  home="$dir/home"
  mkdir -p "$home/data"
  : > "$state/crew.meta"
  : > "$state/.wake-queue"
  chmod 600 "$state/.wake-queue"

  # A durable wake queued across the close must be recovered by the next arm.
  append_wake "$state" check stranded 'check: stranded across the gap'
  reason=$(run_watch_cycle "$dir" "$state" "$home" queued)
  grep -q '^pending:downtime:\|^announced:downtime:' "$state/.watcher-down" \
    || fail "a close with a queued wake did not leave an open recovery episode: $(cat "$state/.watcher-down" 2>/dev/null)"
  reason=$(run_watch_cycle "$dir" "$state" "$home" queued-rearm)
  case "$reason" in
    *rearm-resurface*) ;;
    *) fail "the arm after a queued-wake close did not recover it: $reason" ;;
  esac
  err="$dir/queued-drain.err"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" \
    >/dev/null 2> "$err" || fail "recovery drain failed"
  grep -q '^WAKE_ACK_REQUIRED:' "$err" \
    || fail "recovered episode did not require a generation-bound acknowledgement"
  ack_drain_err "$state" "$err" || fail "recovery acknowledgement failed"

  # An unchanged open captain decision is the no-new-rows down-window shape.
  printf 'needs-decision [key=signoff]: held for captain sign-off\n' >> "$state/crew.status"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" \
    >/dev/null 2> "$dir/decision-baseline.err" || fail "decision baseline drain failed"
  ack_drain_err "$state" "$dir/decision-baseline.err" >/dev/null 2>&1 || true
  : > "$state/.wake-queue"
  run_watch_cycle "$dir" "$state" "$home" decision >/dev/null
  grep -q '^pending:downtime:\|^announced:downtime:' "$state/.watcher-down" \
    || fail "a close with an open decision did not leave a recovery episode: $(cat "$state/.watcher-down" 2>/dev/null)"
  reason=$(run_watch_cycle "$dir" "$state" "$home" decision-rearm)
  case "$reason" in
    *rearm-resurface*) ;;
    *) fail "the arm after an open-decision close did not recover it: $reason" ;;
  esac
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf 'T4_MARKER=%s\n' "$(cat "$state/.watcher-down")"
  fi
  pass "a close that leaves work behind still opens and recovers its episode"
}

test_healthy_home_with_nothing_queued_converges
test_close_with_work_pending_still_recovers
test_handling_successor_does_not_go_blind
test_unacknowledged_recovery_is_announced_once_per_generation
