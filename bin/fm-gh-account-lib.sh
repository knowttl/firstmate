# shellcheck shell=bash
# Per-project GitHub account selection for spawned worker gh operations.
# Usage: . bin/fm-gh-account-lib.sh
#
# The captain runs two GitHub accounts isolated per project. Git transport is
# already routed durably (SSH host aliases + insteadOf + includeIf), but the gh
# CLI selects its token from GH_CONFIG_DIR (default ~/.config/gh), and that
# default account is not SSO-authorized for every org. When firstmate launches a
# ship/scout worker, fm-spawn.sh resolves the project's account from its origin
# remote and exports GH_CONFIG_DIR into the worker's pane so every gh call the
# worker (and the no-mistakes pipeline it drives) makes uses the right account.
#
# The gh account configs live only in the PRIMARY firstmate home's data/gh-config
# (one subdir per account, e.g. data/gh-config/pwxgh). A crewmate spawned from a
# secondmate home reaches the same primary-home configs via the local-route
# parent record (fm-secondmate-parent-lib.sh), so both a main-home and a
# secondmate-home crewmate authenticate against the same authorized store.
#
# When an origin does not map to a known account (an unrelated repo), or the
# resolved config dir is absent, these functions produce nothing and fm-spawn
# leaves the environment unchanged - never guessing an account.

# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-secondmate-parent-lib.sh"

# The account map. Each row: <account>|<ssh-alias-host>|<github.com-namespace>.
# <account> is also the data/gh-config subdir name. Add a row to extend; keep it
# the single home for the mapping rather than scattering org names elsewhere.
_fm_gh_account_table() {
  cat <<'TABLE'
knowttl|github.com-knowttl|knowttl
pwxgh|github.com-pwxgh|powerex-development
TABLE
}

# Map an origin URL to an account name. Prints the account and returns 0 on a
# match; prints nothing and returns 1 otherwise. Handles the https, ssh://,
# scp-like git@host:path, and bare ssh-alias host:path origin forms.
fm_gh_account_for_origin() {
  local origin=$1 rest host path ns
  [ -n "$origin" ] || return 1
  case "$origin" in
    *://*)
      # scheme://[user@]host/path
      rest=${origin#*://}
      rest=${rest#*@}
      host=${rest%%/*}
      path=${rest#*/}
      ;;
    *@*:*)
      # user@host:path (scp-like)
      rest=${origin#*@}
      host=${rest%%:*}
      path=${rest#*:}
      ;;
    *:*)
      # host:path (scp-like, no user - e.g. a bare ssh-alias origin)
      host=${origin%%:*}
      path=${origin#*:}
      ;;
    *)
      return 1
      ;;
  esac
  ns=${path%%/*}

  local account alias_host namespace
  while IFS='|' read -r account alias_host namespace; do
    [ -n "$account" ] || continue
    if [ "$host" = "$alias_host" ]; then
      printf '%s\n' "$account"
      return 0
    fi
    if [ "$host" = github.com ] && [ "$ns" = "$namespace" ]; then
      printf '%s\n' "$account"
      return 0
    fi
  done < <(_fm_gh_account_table)
  return 1
}

# Resolve the primary firstmate home's gh-config base for the given home. For a
# main home this is <home>/data/gh-config; for a secondmate home it is the
# local-route parent home's data/gh-config, so the authorized configs are reached
# from either. Prints the base dir and returns 0 only when it exists; returns 1
# for a remote or unresolvable parent, or a missing base.
fm_gh_config_base_for_home() {
  local home=$1 base
  [ -n "$home" ] || return 1
  if [ -f "$home/.fm-secondmate-home" ]; then
    fm_secondmate_parent_record_parse "$home/.fm-secondmate-parent" || return 1
    [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || return 1
    [ -n "$FM_SECONDMATE_PARENT_HOME" ] || return 1
    base="$FM_SECONDMATE_PARENT_HOME/data/gh-config"
  else
    base="$home/data/gh-config"
  fi
  [ -d "$base" ] || return 1
  printf '%s\n' "$base"
}

# Resolve the GH_CONFIG_DIR a worker launched for <git_dir> under <home> should
# use. Reads <git_dir>'s origin, maps it to an account, and composes the account
# subdir under the primary home's gh-config base. Prints the absolute dir and
# returns 0 only when the origin maps to a known account and that account's
# config dir exists; otherwise prints nothing and returns 1.
fm_gh_config_dir_for_spawn() {
  local home=$1 git_dir=$2 origin account base dir
  [ -n "$git_dir" ] || return 1
  origin=$(git -C "$git_dir" remote get-url origin 2>/dev/null) || return 1
  account=$(fm_gh_account_for_origin "$origin") || return 1
  base=$(fm_gh_config_base_for_home "$home") || return 1
  dir="$base/$account"
  [ -d "$dir" ] || return 1
  printf '%s\n' "$dir"
}
