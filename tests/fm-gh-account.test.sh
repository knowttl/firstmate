#!/usr/bin/env bash
# Behavior tests for per-project GitHub account selection (fm-gh-account-lib.sh).
#
# fm-spawn.sh sources this library and, for a ship/scout worker, exports
# GH_CONFIG_DIR at the account config resolved from the project's origin remote,
# so every gh call the worker makes authenticates against the right account.
#
# These tests drive the library's public functions directly - the same functions
# fm-spawn calls - against real origin URLs, real temporary git repos, and real
# fake home directories. They never assert the library's source bytes.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-gh-account-lib.sh
. "$ROOT/bin/fm-gh-account-lib.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

TMP_ROOT=
cleanup() {
  if [ -n "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-gh-account-tests.XXXXXX")

# --- fm_gh_account_for_origin: the pure origin -> account mapping ---

assert_account() {  # <origin> <expected-account>
  local origin=$1 want=$2 got
  got=$(fm_gh_account_for_origin "$origin") \
    || fail "origin '$origin' did not map (expected '$want')"
  [ "$got" = "$want" ] \
    || fail "origin '$origin' mapped to '$got', expected '$want'"
}

assert_no_account() {  # <origin>
  local origin=$1 got
  if got=$(fm_gh_account_for_origin "$origin"); then
    fail "origin '$origin' mapped to '$got' but should map to no account"
  fi
  [ -z "$got" ] || fail "origin '$origin' printed '$got' on no-account result"
}

test_account_mapping() {
  # knowttl: ssh-alias host and github.com namespace, across origin forms.
  assert_account 'git@github.com-knowttl:knowttl/awx-axi.git' knowttl
  assert_account 'github.com-knowttl:knowttl/awx-axi.git' knowttl
  assert_account 'https://github.com/knowttl/awx-axi.git' knowttl
  assert_account 'git@github.com:knowttl/awx-axi.git' knowttl
  assert_account 'ssh://git@github.com/knowttl/awx-axi.git' knowttl

  # pwxgh: ssh-alias host and powerex-development namespace, across origin forms.
  assert_account 'git@github.com-pwxgh:powerex-development/ops.cs.azure-epac.git' pwxgh
  assert_account 'github.com-pwxgh:powerex-development/ops.cs.azure-epac.git' pwxgh
  assert_account 'https://github.com/powerex-development/ops.cs.azure-epac.git' pwxgh
  assert_account 'git@github.com:powerex-development/ops.cs.azure-epac.git' pwxgh

  # Unrelated origins map to no account (never guess).
  assert_no_account 'git@github.com:someorg/repo.git'
  assert_no_account 'https://github.com/other-user/thing.git'
  assert_no_account 'git@gitlab.com:knowttl/repo.git'
  assert_no_account 'git@github.com-unknown:foo/repo.git'
  assert_no_account ''

  pass "fm_gh_account_for_origin maps both account forms and rejects unrelated origins"
}

# --- fm_gh_config_base_for_home: primary-home gh-config base resolution ---

test_config_base_main_home() {
  local home="$TMP_ROOT/main-home"
  mkdir -p "$home/data/gh-config"
  local got
  got=$(fm_gh_config_base_for_home "$home") \
    || fail "main home base did not resolve"
  [ "$got" = "$home/data/gh-config" ] \
    || fail "main home base resolved to '$got'"
  pass "fm_gh_config_base_for_home resolves a main home's own data/gh-config"
}

test_config_base_secondmate_local_parent() {
  # A secondmate home's own gh-config is absent; it must resolve the local-route
  # parent (primary) home's data/gh-config instead.
  local primary="$TMP_ROOT/primary"
  local sm="$TMP_ROOT/sm-local"
  mkdir -p "$primary/data/gh-config"
  mkdir -p "$sm"
  printf 'seed-id\n' > "$sm/.fm-secondmate-home"
  cat > "$sm/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$primary
EOF
  local got
  got=$(fm_gh_config_base_for_home "$sm") \
    || fail "secondmate home did not resolve its parent's base"
  [ "$got" = "$primary/data/gh-config" ] \
    || fail "secondmate home base resolved to '$got', expected '$primary/data/gh-config'"
  pass "fm_gh_config_base_for_home resolves a secondmate home to its local parent's data/gh-config"
}

test_config_base_secondmate_remote_parent() {
  # A remote-route parent shares no filesystem, so no gh-config base resolves.
  local sm="$TMP_ROOT/sm-remote"
  mkdir -p "$sm"
  printf 'seed-id\n' > "$sm/.fm-secondmate-home"
  cat > "$sm/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=remote
parent_host=github.com-example
EOF
  if fm_gh_config_base_for_home "$sm" >/dev/null; then
    fail "remote-route secondmate home resolved a base but should not"
  fi
  pass "fm_gh_config_base_for_home refuses a remote-route secondmate home"
}

test_config_base_missing_dir() {
  # A home whose data/gh-config does not exist resolves nothing.
  local home="$TMP_ROOT/no-config-home"
  mkdir -p "$home/data"
  if fm_gh_config_base_for_home "$home" >/dev/null; then
    fail "home without data/gh-config resolved a base but should not"
  fi
  pass "fm_gh_config_base_for_home refuses a home with no data/gh-config"
}

# --- fm_gh_config_dir_for_spawn: end-to-end from a repo's origin to GH_CONFIG_DIR ---

make_repo_with_origin() {  # <name> <origin-url> -> prints repo path
  local name=$1 origin=$2 repo
  repo="$TMP_ROOT/$name"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" remote add origin "$origin"
  printf '%s' "$repo"
}

test_spawn_dir_mapped_project() {
  # A main home with both account configs present.
  local home="$TMP_ROOT/spawn-main"
  mkdir -p "$home/data/gh-config/knowttl" "$home/data/gh-config/pwxgh"

  local repo got
  # knowttl via ssh-alias origin.
  repo=$(make_repo_with_origin knowttl-repo 'git@github.com-knowttl:knowttl/awx-axi.git')
  got=$(fm_gh_config_dir_for_spawn "$home" "$repo") \
    || fail "knowttl repo did not resolve a spawn config dir"
  [ "$got" = "$home/data/gh-config/knowttl" ] \
    || fail "knowttl spawn dir resolved to '$got'"

  # pwxgh via https origin.
  repo=$(make_repo_with_origin pwxgh-repo 'https://github.com/powerex-development/ops.cs.azure-epac.git')
  got=$(fm_gh_config_dir_for_spawn "$home" "$repo") \
    || fail "pwxgh repo did not resolve a spawn config dir"
  [ "$got" = "$home/data/gh-config/pwxgh" ] \
    || fail "pwxgh spawn dir resolved to '$got'"

  pass "fm_gh_config_dir_for_spawn carries the expected GH_CONFIG_DIR for a mapped project"
}

test_spawn_dir_secondmate_reaches_primary() {
  # A secondmate-home worker reaches the primary home's account configs.
  local primary="$TMP_ROOT/spawn-primary"
  local sm="$TMP_ROOT/spawn-sm"
  mkdir -p "$primary/data/gh-config/pwxgh"
  mkdir -p "$sm"
  printf 'seed-id\n' > "$sm/.fm-secondmate-home"
  cat > "$sm/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$primary
EOF
  local repo got
  repo=$(make_repo_with_origin sm-repo 'git@github.com-pwxgh:powerex-development/ops.cs.azure-epac.git')
  got=$(fm_gh_config_dir_for_spawn "$sm" "$repo") \
    || fail "secondmate-home worker did not resolve the primary's config dir"
  [ "$got" = "$primary/data/gh-config/pwxgh" ] \
    || fail "secondmate-home spawn dir resolved to '$got', expected '$primary/data/gh-config/pwxgh'"
  pass "fm_gh_config_dir_for_spawn lets a secondmate-home worker reach the primary's account config"
}

test_spawn_dir_unmapped_project() {
  # An unrelated origin forces no GH_CONFIG_DIR even with configs present.
  local home="$TMP_ROOT/spawn-unmapped"
  mkdir -p "$home/data/gh-config/knowttl" "$home/data/gh-config/pwxgh"
  local repo got
  repo=$(make_repo_with_origin unrelated-repo 'git@github.com:someorg/repo.git')
  if got=$(fm_gh_config_dir_for_spawn "$home" "$repo"); then
    fail "unrelated origin resolved '$got' but should force no GH_CONFIG_DIR"
  fi
  [ -z "$got" ] || fail "unrelated origin printed '$got'"
  pass "fm_gh_config_dir_for_spawn forces no GH_CONFIG_DIR for an unmapped project"
}

test_spawn_dir_missing_account_config() {
  # A mapped origin whose account config subdir is absent resolves nothing,
  # rather than pointing gh at a nonexistent store.
  local home="$TMP_ROOT/spawn-partial"
  mkdir -p "$home/data/gh-config/knowttl"  # pwxgh deliberately absent
  local repo got
  repo=$(make_repo_with_origin partial-repo 'git@github.com-pwxgh:powerex-development/ops.cs.azure-epac.git')
  if got=$(fm_gh_config_dir_for_spawn "$home" "$repo"); then
    fail "mapped origin with absent account config resolved '$got' but should not"
  fi
  pass "fm_gh_config_dir_for_spawn resolves nothing when the mapped account config is absent"
}

test_spawn_dir_no_origin() {
  # A repo with no origin remote resolves nothing.
  local home="$TMP_ROOT/spawn-noorigin"
  mkdir -p "$home/data/gh-config/knowttl"
  local repo="$TMP_ROOT/noorigin-repo" got
  mkdir -p "$repo"
  git -C "$repo" init -q
  if got=$(fm_gh_config_dir_for_spawn "$home" "$repo"); then
    fail "repo with no origin resolved '$got' but should not"
  fi
  pass "fm_gh_config_dir_for_spawn resolves nothing when the repo has no origin"
}

test_account_mapping
test_config_base_main_home
test_config_base_secondmate_local_parent
test_config_base_secondmate_remote_parent
test_config_base_missing_dir
test_spawn_dir_mapped_project
test_spawn_dir_secondmate_reaches_primary
test_spawn_dir_unmapped_project
test_spawn_dir_missing_account_config
test_spawn_dir_no_origin
