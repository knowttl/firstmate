#!/usr/bin/env bash
# Behavior tests for fm-guard's low-disk alarm.
#
# The alarm is the early-detection half of the disk-hygiene safeguards: pooled
# build worktrees fill the filesystem they share, and a fill fails the next
# build or deploy with an error that names anything but the disk. These cases
# pin the threshold decision (alarms below the configured headroom, silent
# above it), the configuration contract in config/disk-guard, the rate limit and
# its re-arm on recovery, and the warning-only promise: the guard never removes
# anything and always exits 0.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-guard-disk-space)
ALARM_LINE='LOW DISK SPACE'
MARKER=.guard-disk-space-alarm

# A guard home with no in-flight work: the disk alarm is independent of the
# fleet, so every case below starts from an otherwise silent guard.
make_home() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/root"
  git init -q -b main "$dir/root"
  printf '%s\n' "$dir"
}

# Run the guard against that home; all guard output is on stderr.
run_guard() {
  local dir=$1
  shift
  ( cd "$dir" && env "$@" FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
      "$ROOT/bin/fm-guard.sh" 2>&1 )
}

# A threshold no real filesystem satisfies, so "below headroom" is deterministic
# wherever the suite runs.
IMPOSSIBLE_GIB=999999999

test_threshold_decides_the_alarm() {
  local dir out
  dir=$(make_home threshold)

  printf '%s\n' "$IMPOSSIBLE_GIB" > "$dir/home/config/disk-guard"
  out=$(run_guard "$dir")
  assert_contains "$out" "$ALARM_LINE" "free space below the threshold must alarm"

  rm -f "$dir/home/state/$MARKER"
  printf '%s\n' "1" > "$dir/home/config/disk-guard"
  out=$(run_guard "$dir")
  assert_not_contains "$out" "$ALARM_LINE" "free space above the threshold must stay silent"

  rm -f "$dir/home/state/$MARKER"
  printf '%s\n' "0" > "$dir/home/config/disk-guard"
  out=$(run_guard "$dir")
  assert_not_contains "$out" "$ALARM_LINE" "a zero threshold must disable the alarm"

  rm -f "$dir/home/config/disk-guard"
  out=$(run_guard "$dir")
  assert_not_contains "$out" "$ALARM_LINE" "an absent config must not alarm on a healthy filesystem"
  pass "disk guard: alarms below the configured headroom and stays silent above it"
}

test_config_selects_path_and_reports_invalid_threshold() {
  local dir out
  dir=$(make_home config)

  printf '%s\n' "5 /no/such/mount/point" > "$dir/home/config/disk-guard"
  out=$(run_guard "$dir")
  assert_contains "$out" "$ALARM_LINE" "an unreadable watched path must alarm, not go quietly unmonitored"
  assert_contains "$out" "/no/such/mount/point" "the alarm must name the watched path"

  rm -f "$dir/home/state/$MARKER"
  printf '%s\n%s\n' "# headroom in GiB" "plenty" > "$dir/home/config/disk-guard"
  out=$(run_guard "$dir")
  assert_contains "$out" "invalid free-space threshold" "an unusable threshold must be reported"
  assert_not_contains "$out" "$ALARM_LINE" "an unusable threshold must fall back to the default, not alarm falsely"
  pass "disk guard: config selects the watched path and an unusable threshold is reported"
}

test_alarm_is_rate_limited_and_rearms_on_recovery() {
  local dir out
  dir=$(make_home ratelimit)
  printf '%s\n' "$IMPOSSIBLE_GIB" > "$dir/home/config/disk-guard"

  out=$(run_guard "$dir")
  assert_contains "$out" "$ALARM_LINE" "the first low-disk alarm must print"
  out=$(run_guard "$dir")
  assert_not_contains "$out" "$ALARM_LINE" "a repeat inside the window must stay quiet"

  out=$(run_guard "$dir" FM_DISK_GUARD_REPEAT_SECS=0)
  assert_contains "$out" "$ALARM_LINE" "the alarm must repeat once its window elapses"

  # Recovery re-arms: a healthy filesystem must clear the record so the next
  # fill alarms immediately instead of waiting out the window.
  printf '%s\n' "1" > "$dir/home/config/disk-guard"
  out=$(run_guard "$dir")
  assert_absent "$dir/home/state/$MARKER" "recovery must clear the rate-limit record"
  printf '%s\n' "$IMPOSSIBLE_GIB" > "$dir/home/config/disk-guard"
  out=$(run_guard "$dir")
  assert_contains "$out" "$ALARM_LINE" "a fresh fill after recovery must alarm immediately"
  pass "disk guard: alarm is rate-limited per home and re-arms after recovery"
}

test_alarm_only_warns() {
  local dir out code
  dir=$(make_home warn-only)
  printf '%s\n' "$IMPOSSIBLE_GIB" > "$dir/home/config/disk-guard"
  mkdir -p "$dir/home/cache"
  printf 'x\n' > "$dir/home/cache/keep"

  out=$(run_guard "$dir") && code=0 || code=$?
  expect_code 0 "$code" "the guard must warn without failing the guarded operation"
  assert_contains "$out" "$ALARM_LINE" "the warn-only case must still alarm"
  assert_present "$dir/home/cache/keep" "the guard must never delete anything to free space"
  pass "disk guard: the alarm warns only - it exits 0 and deletes nothing"
}

test_read_only_session_does_not_write_state() {
  local dir out
  dir=$(make_home read-only)
  printf '%s\n' "$IMPOSSIBLE_GIB" > "$dir/home/config/disk-guard"

  out=$(run_guard "$dir" FM_GUARD_READ_ONLY=1)
  assert_contains "$out" "$ALARM_LINE" "a read-only session must still report a low disk"
  assert_absent "$dir/home/state/$MARKER" "a read-only session must not write the rate-limit record"
  pass "disk guard: a read-only session reports the alarm without mutating home state"
}

test_threshold_decides_the_alarm
test_config_selects_path_and_reports_invalid_threshold
test_alarm_is_rate_limited_and_rearms_on_recovery
test_alarm_only_warns
test_read_only_session_does_not_write_state
