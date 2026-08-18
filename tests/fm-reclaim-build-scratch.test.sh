#!/usr/bin/env bash
# Behavior tests for fm-reclaim-build-scratch.
#
# Reclaiming a finished worktree's install trees is only safe if it can never
# reach anything a rebuild does not recreate. These cases pin both halves of
# that contract: regenerable git-ignored build scratch is removed, while tracked
# files, untracked-but-unignored files, ignored-but-precious files, escaping
# symlinks, and any worktree still carrying modified tracked work are left
# exactly as they were.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-reclaim-build-scratch)
RECLAIM="$ROOT/bin/fm-reclaim-build-scratch.sh"
fm_git_identity fmtest fmtest@example.invalid

# A committed worktree carrying one of everything the script must decide about:
# scratch to reclaim, and neighbours it must never touch.
make_worktree() {
  local name=$1 wt
  wt="$TMP_ROOT/$name"
  git init -q -b main "$wt"
  printf '%s\n' 'node_modules/' 'dist/' '.venv/' '.env' 'local-data/' > "$wt/.gitignore"

  mkdir -p "$wt/src" "$wt/node_modules/pkg" "$wt/frontend/node_modules" "$wt/dist" \
    "$wt/.venv" "$wt/local-data"
  printf 'source\n' > "$wt/src/app.js"
  printf 'installed\n' > "$wt/node_modules/pkg/index.js"
  printf 'installed\n' > "$wt/frontend/node_modules/dep.js"
  printf 'built\n' > "$wt/dist/bundle.js"
  printf 'venv\n' > "$wt/.venv/pyvenv.cfg"
  printf 'secret\n' > "$wt/.env"
  printf 'rows\n' > "$wt/local-data/db.sqlite"
  printf 'notes\n' > "$wt/scratch-notes.txt"

  git -C "$wt" add -A >/dev/null
  git -C "$wt" commit -qm init
  printf '%s\n' "$wt"
}

test_removes_regenerable_scratch_only() {
  local wt out code
  wt=$(make_worktree removes)

  out=$("$RECLAIM" "$wt") && code=0 || code=$?
  expect_code 0 "$code" "reclaiming a clean worktree must succeed"
  assert_contains "$out" "removed 3" "the summary must report the reclaimed paths"

  assert_absent "$wt/node_modules" "an ignored install tree must be reclaimed"
  assert_absent "$wt/frontend/node_modules" "a nested ignored install tree must be reclaimed"
  assert_absent "$wt/dist" "ignored build output must be reclaimed"

  assert_present "$wt/src/app.js" "tracked source must survive"
  assert_present "$wt/.env" "an ignored credential file is not regenerable and must survive"
  assert_present "$wt/local-data/db.sqlite" "an ignored local data directory must survive"
  assert_present "$wt/.venv/pyvenv.cfg" "an ignored directory outside the scratch list must survive"
  assert_present "$wt/scratch-notes.txt" "committed notes must survive"
  pass "reclaim: removes git-ignored regenerable build scratch and nothing else"
}

test_leaves_untracked_and_unignored_work_alone() {
  local wt
  wt=$(make_worktree untracked)
  # Untracked but NOT ignored: unfiled work in progress, never scratch. Both a
  # loose file and a directory whose name is on the scratch list.
  printf 'draft\n' > "$wt/src/wip.js"
  mkdir -p "$wt/build"
  printf 'hand written\n' > "$wt/build/notes.md"

  "$RECLAIM" "$wt" >/dev/null
  assert_present "$wt/src/wip.js" "untracked work in progress must survive"
  assert_present "$wt/build/notes.md" "an untracked directory git does not ignore must survive even when its name is scratch-shaped"
  assert_absent "$wt/node_modules" "reclaiming must still remove genuine ignored scratch"
  pass "reclaim: untracked-but-unignored files are never scratch"
}

test_refuses_a_worktree_with_modified_tracked_work() {
  local wt out code
  wt=$(make_worktree dirty)
  printf 'edited\n' >> "$wt/src/app.js"

  out=$("$RECLAIM" "$wt" 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "a worktree with modified tracked work must be refused"
  assert_contains "$out" "REFUSED" "the refusal must be explicit"
  assert_present "$wt/node_modules/pkg/index.js" "a refused worktree must keep every path, scratch included"
  assert_present "$wt/dist/bundle.js" "a refused worktree must keep its build output too"
  pass "reclaim: refuses a worktree still carrying modified tracked work"
}

test_refuses_a_non_worktree_target() {
  local out code plain
  plain="$TMP_ROOT/not-a-repo"
  mkdir -p "$plain/node_modules"
  printf 'x\n' > "$plain/node_modules/dep.js"

  out=$("$RECLAIM" "$plain" 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "a directory that is not a git worktree must be refused"
  assert_contains "$out" "REFUSED" "the refusal must be explicit"
  assert_present "$plain/node_modules/dep.js" "nothing outside a git worktree may be removed"

  out=$("$RECLAIM" "$TMP_ROOT/missing-entirely" 2>&1) && code=0 || code=$?
  expect_code 1 "$code" "a missing directory must be refused"

  out=$("$RECLAIM" 2>&1) && code=0 || code=$?
  expect_code 2 "$code" "a missing argument must be a usage error"
  pass "reclaim: refuses a non-worktree, a missing target, and a missing argument"
}

test_never_follows_scratch_out_of_the_worktree() {
  local wt outside
  wt=$(make_worktree symlink)
  outside="$TMP_ROOT/shared-store"
  mkdir -p "$outside"
  printf 'shared\n' > "$outside/dep.js"
  rm -rf "$wt/node_modules"
  ln -s "$outside" "$wt/node_modules"

  "$RECLAIM" "$wt" >/dev/null
  assert_present "$outside/dep.js" "a symlinked scratch path must never be followed out of the worktree"
  assert_present "$wt/node_modules" "the symlink itself must be left in place"
  assert_absent "$wt/dist" "genuine in-worktree scratch must still be reclaimed"
  pass "reclaim: scratch is reclaimed in place, never through a symlink out of the worktree"
}

test_is_idempotent() {
  local wt out
  wt=$(make_worktree idempotent)
  "$RECLAIM" "$wt" >/dev/null
  out=$("$RECLAIM" "$wt")
  assert_contains "$out" "no regenerable build scratch" "a second run must be a clean no-op"
  pass "reclaim: a repeat run is a clean no-op"
}

test_removes_regenerable_scratch_only
test_leaves_untracked_and_unignored_work_alone
test_refuses_a_worktree_with_modified_tracked_work
test_refuses_a_non_worktree_target
test_never_follows_scratch_out_of_the_worktree
test_is_idempotent
