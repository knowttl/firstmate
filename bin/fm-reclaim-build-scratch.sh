#!/usr/bin/env bash
# Reclaim regenerable build scratch (node_modules, compiled output, tool caches)
# from a worktree that is finished with, so pooled worktrees do not accumulate
# gigabytes of install trees on the disk that holds the pool. `treehouse return`
# resets tracked content but leaves git-IGNORED trees in place, so a returned
# pool slot keeps every install tree its last task built.
#
# Usage: fm-reclaim-build-scratch.sh <worktree-dir>
#   Prints one summary line on stdout. Exit 0 = reclaimed (possibly nothing),
#   1 = refused (nothing was removed), 2 = usage error.
#
# Removal is gated on three independent conditions, all of which must hold:
#   1. <worktree-dir> is a git worktree whose TRACKED files are unmodified.
#      A tracked modification means live or unfinished work, so this refuses and
#      removes nothing. This is a second, independent check: whether the task's
#      work has LANDED is owned by bin/fm-teardown.sh, which runs its landed-work
#      test (and its process reap) before ever calling this.
#   2. The path is reported IGNORED by git itself, so no tracked file, no
#      untracked-but-unignored file, and nothing in the index can ever be a
#      candidate.
#   3. Its basename is in the regenerable-scratch list below. Being ignored is
#      not sufficient: an ignored `.env`, credential, or local data directory is
#      precious, and only names whose contents a plain install or build step
#      recreates are removed.
# A symlink, or a directory whose resolved path escapes the worktree, is skipped:
# scratch is reclaimed in place or not at all.
set -eu

# Regenerable when git-ignored: a package install tree, a build output tree, or a
# tool cache that the next install/build/test run recreates.
SCRATCH_NAMES="node_modules .next .nuxt .turbo dist build target __pycache__ .pytest_cache .mypy_cache .ruff_cache"

usage() {
  echo "usage: fm-reclaim-build-scratch.sh <worktree-dir>" >&2
  exit 2
}

refuse() {
  echo "reclaim: REFUSED: $1" >&2
  exit 1
}

[ "$#" -eq 1 ] || usage
[ -n "$1" ] || usage
[ -d "$1" ] || refuse "no worktree directory at $1"

ROOT_DIR=$(cd "$1" && pwd -P)
git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || refuse "$ROOT_DIR is not a git worktree"
STATUS=$(git -C "$ROOT_DIR" status --porcelain --untracked-files=no 2>/dev/null) \
  || refuse "cannot inspect $ROOT_DIR for tracked modifications"
[ -z "$STATUS" ] || refuse "$ROOT_DIR has modified tracked files; leaving all scratch in place"

removed=0
while IFS= read -r -d '' rel; do
  rel=${rel%/}
  [ -n "$rel" ] || continue
  case " $SCRATCH_NAMES " in
    *" ${rel##*/} "*) ;;
    *) continue ;;
  esac
  path="$ROOT_DIR/$rel"
  if [ -L "$path" ] || [ ! -d "$path" ]; then
    continue
  fi
  real=$(cd "$path" && pwd -P) || continue
  case "$real" in
    "$ROOT_DIR"/*) ;;
    *) continue ;;
  esac
  rm -rf "$real"
  removed=$((removed + 1))
done < <(git -C "$ROOT_DIR" ls-files --ignored --exclude-standard --others --directory -z)

if [ "$removed" -eq 0 ]; then
  echo "reclaim: no regenerable build scratch under $ROOT_DIR"
else
  echo "reclaim: removed $removed regenerable build-scratch path(s) under $ROOT_DIR"
fi
