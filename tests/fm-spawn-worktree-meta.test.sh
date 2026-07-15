#!/usr/bin/env bash
# Regression test for an aliased treehouse pool slot being recorded in task meta.
#
# The stale slot's .git points at the admin directory that Git registered for the
# live slot. Treehouse can offer that stale path when its phantom status is clean.
# fm-spawn must lease the offered path, reject the mismatched registration, and
# return the rejected lease instead of writing it to task metadata.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(mktemp -d "$ROOT/.fm-spawn-worktree-meta.XXXXXX")
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fm_git_identity fmtest fmtest@example.invalid

make_aliased_pool() {  # <root> -> prints orphan<TAB>live
  local root=$1 src orphan live
  src="$root/src"
  orphan="$root/pool/5/src"
  live="$root/pool/8/src"

  mkdir -p "$src" "$(dirname "$orphan")" "$(dirname "$live")"
  git -C "$src" init -q -b main
  git -C "$src" commit -q --allow-empty -m initial
  git -C "$src" worktree add -q --detach "$orphan"

  # Leave the slot directory behind while pruning its admin registration, then
  # reuse the basename for a new worktree. This is the live alias shape.
  mv "$orphan" "$root/orphan-stash"
  git -C "$src" worktree prune
  mv "$root/orphan-stash" "$orphan"
  git -C "$src" worktree add -q --detach "$live"

  printf '%s\t%s\n' "$orphan" "$live"
}

make_concurrent_pool() {  # <root> -> prints orphan<TAB>first-live<TAB>second-live
  local root=$1 orphan first_live second_live
  IFS=$'\t' read -r orphan first_live < <(make_aliased_pool "$root")
  second_live="$root/pool/9/src"
  mkdir -p "$(dirname "$second_live")"
  git -C "$root/src" worktree add -q --detach "$second_live"
  printf '%s\t%s\t%s\n' "$orphan" "$first_live" "$second_live"
}

make_foreign_pool_slot() {  # <root> -> prints pool-clone<TAB>foreign-slot
  local root=$1 pool_clone foreign_clone foreign_slot
  pool_clone="$root/src"
  foreign_clone="$root/foreign"
  foreign_slot="$root/pool/7/src"

  mkdir -p "$pool_clone" "$foreign_clone" "$(dirname "$foreign_slot")"
  git -C "$pool_clone" init -q -b main
  git -C "$pool_clone" commit -q --allow-empty -m pool-initial
  git -C "$foreign_clone" init -q -b main
  git -C "$foreign_clone" commit -q --allow-empty -m foreign-initial
  git -C "$foreign_clone" worktree add -q --detach "$foreign_slot"

  printf '%s\t%s\n' "$pool_clone" "$foreign_slot"
}

make_fakebin() {  # <dir> -> prints fakebin
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *'#{pane_current_path}'*) printf '%s\n' "${FM_FAKE_PANE_PATH:?}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window) printf '@aliaswid\n'; exit 0 ;;
  list-windows|send-keys|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TREEHOUSE_LOG:?}"
case "${1:-}" in
  get)
    [ "${2:-}" = --lease ] || exit 2
    [ "${3:-}" = --lease-holder ] || exit 2
    case "${4:-}" in
      "${FM_LEASE_HOLDER_A:-}") printf '%s\n' "${FM_LEASE_PATH_A:?}" ;;
      "${FM_LEASE_HOLDER_B:-}") printf '%s\n' "${FM_LEASE_PATH_B:?}" ;;
      *) printf '%s\n' "${FM_LEASE_PATH:?}" ;;
    esac
    ;;
  return) exit 0 ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

test_aliased_slot_is_never_recorded() {
  local pool orphan live registration home state data config id fakebin log out status
  pool="$TMP_ROOT/pool-fixture"
  IFS=$'\t' read -r orphan live < <(make_aliased_pool "$pool")
  registration=$(sed 's#/\.git$##' "$(git -C "$orphan" rev-parse --git-dir)/gitdir")
  [ "$registration" = "$live" ] || fail "fixture did not create an aliased orphan registration"
  [ "$(git -C "$orphan" rev-parse --show-toplevel)" = "$orphan" ] \
    || fail "fixture orphan did not look like an isolated worktree"

  id=fm-spawn-lease-fix
  home="$TMP_ROOT/home"
  state="$home/state"
  data="$home/data"
  config="$home/config"
  mkdir -p "$state" "$data/$id" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  fakebin=$(make_fakebin "$TMP_ROOT/fakebin")
  log="$TMP_ROOT/treehouse.log"
  : > "$log"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$orphan" FM_LEASE_PATH="$orphan" \
    FM_TREEHOUSE_LOG="$log" TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$pool/src" codex 2>&1)
  status=$?

  if [ "$status" -eq 0 ]; then
    assert_grep "worktree=$orphan" "$state/$id.meta" \
      "old cwd polling did not expose the aliased worktree meta drift"
    fail "fm-spawn recorded the aliased orphan instead of refusing it"
  fi
  assert_absent "$state/$id.meta" "aliased lease refusal must not write metadata"
  assert_contains "$out" "does not match git's registered worktree path" \
    "aliased lease refusal did not explain the registration mismatch"
  assert_grep "get --lease --lease-holder fm-$id" "$log" \
    "crew spawn did not durably lease its worktree"
  assert_grep "return --force $orphan" "$log" \
    "aliased lease refusal did not return its durable lease"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn: aliased pool orphan is refused, never recorded in metadata, and returned"
}

test_leased_path_is_recorded_instead_of_pane_cwd() {
  local pool orphan live home state data config id fakebin log out status
  pool="$TMP_ROOT/authoritative-pool-fixture"
  IFS=$'\t' read -r orphan live < <(make_aliased_pool "$pool")

  id=fm-spawn-lease-fix
  home="$TMP_ROOT/authoritative-home"
  state="$home/state"
  data="$home/data"
  config="$home/config"
  mkdir -p "$state" "$data/$id" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  fakebin=$(make_fakebin "$TMP_ROOT/authoritative-fakebin")
  log="$TMP_ROOT/authoritative-treehouse.log"
  : > "$log"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$orphan" FM_LEASE_PATH="$live" \
    FM_TREEHOUSE_LOG="$log" TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$pool/src" codex 2>&1)
  status=$?

  expect_code 0 "$status" "spawn must succeed when treehouse leases the registered path"$'\n'"$out"
  assert_grep "worktree=$live" "$state/$id.meta" \
    "metadata must record the authoritative leased worktree, not the pane cwd"
  assert_grep "get --lease --lease-holder fm-$id" "$log" \
    "successful crew spawn did not durably lease its worktree"
  assert_no_grep "return --force" "$log" \
    "successful spawn returned the lease before teardown owned it"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn: metadata records the durable lease path rather than pane cwd"
}

test_foreign_pool_slot_is_never_recorded() {
  local pool pool_clone foreign_slot home state data config id fakebin log out status
  pool="$TMP_ROOT/foreign-pool-fixture"
  IFS=$'\t' read -r pool_clone foreign_slot < <(make_foreign_pool_slot "$pool")
  [ "$(git -C "$foreign_slot" rev-parse --show-toplevel)" = "$foreign_slot" ] \
    || fail "fixture foreign slot did not look like an isolated worktree"
  [ "$(git -C "$foreign_slot" rev-parse --git-common-dir)" != "$(git -C "$pool_clone" rev-parse --git-common-dir)" ] \
    || fail "fixture foreign slot unexpectedly shared the pool clone"

  id=fm-spawn-lease-fix
  home="$TMP_ROOT/foreign-home"
  state="$home/state"
  data="$home/data"
  config="$home/config"
  mkdir -p "$state" "$data/$id" "$config"
  printf 'brief\n' > "$data/$id/brief.md"
  fakebin=$(make_fakebin "$TMP_ROOT/foreign-fakebin")
  log="$TMP_ROOT/foreign-treehouse.log"
  : > "$log"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$foreign_slot" FM_LEASE_PATH="$foreign_slot" \
    FM_TREEHOUSE_LOG="$log" TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$pool_clone" codex 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "fm-spawn recorded a foreign-repo pool slot"
  assert_absent "$state/$id.meta" "foreign-repo slot refusal must not write metadata"
  assert_contains "$out" "git-common-dir" \
    "foreign-repo slot refusal did not explain the pool-clone boundary"
  assert_grep "return --force $foreign_slot" "$log" \
    "foreign-repo slot refusal did not return its durable lease"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn: foreign-repo pool slot is refused and its lease is returned"
}

test_concurrent_spawns_record_distinct_leases() {
  local pool orphan first_live second_live home state data config first_id second_id fakebin log first_out second_out first_pid second_pid first_status second_status
  pool="$TMP_ROOT/concurrent-pool-fixture"
  IFS=$'\t' read -r orphan first_live second_live < <(make_concurrent_pool "$pool")

  first_id=fm-spawn-lease-fix-a
  second_id=fm-spawn-lease-fix-b
  home="$TMP_ROOT/concurrent-home"
  state="$home/state"
  data="$home/data"
  config="$home/config"
  mkdir -p "$state" "$data/$first_id" "$data/$second_id" "$config"
  printf 'brief\n' > "$data/$first_id/brief.md"
  printf 'brief\n' > "$data/$second_id/brief.md"
  fakebin=$(make_fakebin "$TMP_ROOT/concurrent-fakebin")
  log="$TMP_ROOT/concurrent-treehouse.log"
  first_out="$TMP_ROOT/concurrent-first.out"
  second_out="$TMP_ROOT/concurrent-second.out"
  : > "$log"

  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$orphan" \
    FM_LEASE_HOLDER_A="fm-$first_id" FM_LEASE_PATH_A="$first_live" \
    FM_LEASE_HOLDER_B="fm-$second_id" FM_LEASE_PATH_B="$second_live" \
    FM_TREEHOUSE_LOG="$log" TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$first_id" "$pool/src" codex >"$first_out" 2>&1 &
  first_pid=$!
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$orphan" \
    FM_LEASE_HOLDER_A="fm-$first_id" FM_LEASE_PATH_A="$first_live" \
    FM_LEASE_HOLDER_B="fm-$second_id" FM_LEASE_PATH_B="$second_live" \
    FM_TREEHOUSE_LOG="$log" TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$second_id" "$pool/src" codex >"$second_out" 2>&1 &
  second_pid=$!
  wait "$first_pid"; first_status=$?
  wait "$second_pid"; second_status=$?

  expect_code 0 "$first_status" "first concurrent spawn must succeed"$'\n'"$(cat "$first_out")"
  expect_code 0 "$second_status" "second concurrent spawn must succeed"$'\n'"$(cat "$second_out")"
  assert_grep "worktree=$first_live" "$state/$first_id.meta" \
    "first concurrent spawn did not record its authoritative lease"
  assert_grep "worktree=$second_live" "$state/$second_id.meta" \
    "second concurrent spawn did not record its authoritative lease"
  [ "$first_live" != "$second_live" ] || fail "fixture concurrent leases were not distinct"
  assert_no_grep "worktree=$orphan" "$state/$first_id.meta" \
    "first concurrent spawn recorded the shared aliased orphan"
  assert_no_grep "worktree=$orphan" "$state/$second_id.meta" \
    "second concurrent spawn recorded the shared aliased orphan"
  rm -rf "/tmp/fm-$first_id"
  rm -rf "/tmp/fm-$second_id"
  pass "fm-spawn: concurrent spawns record their distinct durable lease paths"
}

test_aliased_slot_is_never_recorded
test_leased_path_is_recorded_instead_of_pane_cwd
test_foreign_pool_slot_is_never_recorded
test_concurrent_spawns_record_distinct_leases
