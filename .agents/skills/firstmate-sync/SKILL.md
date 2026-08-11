---
name: firstmate-sync
description: >-
  Sync this firstmate fork with the upstream parent it was forked from: review the commits the fork is behind, merge them, resolve conflicts from evidence, and land the result through a PR.
  Use when the captain invokes /firstmate-sync or asks to sync the fork with upstream, catch up on the commits the fork is behind, merge upstream into the fork, or pull changes from the parent repository.
user-invocable: true
metadata:
  internal: true
---

# firstmate-sync

Bring this firstmate fork up to date with the upstream parent it was forked from, absorbing the commits it is behind while preserving the fork's own work.
This operates on the firstmate home repo itself, which is shared tracked material, not on a project clone; syncing a project's own fork is a crewmate's job inside that project's worktree.
It is the opposite direction from `/updatefirstmate`: that skill fast-forwards this home from `origin` to pick up already-landed changes, while this skill merges new commits from the upstream parent into the fork.

The merge touches shared tracked material, so load `firstmate-coding-guidelines` and land the whole change through this repo's PR path with the captain's merge authority (`AGENTS.md` hard rule 2 and section 7).

## 1. Measure the gap

- The upstream parent is the fork's GitHub parent: `gh-axi api repos/<owner>/<repo> --jq '.parent.full_name'`.
- Add or repoint an `upstream` remote at it and fetch: `git remote add upstream https://github.com/<parent>.git` (or `git remote set-url upstream ...`), then `git fetch upstream`.
- Count the divergence: `git rev-list --count main..upstream/main` is how many commits the fork is behind, and the reverse range is how many it is ahead.
- Record the merge base: `git merge-base main upstream/main`.

If the fork is not behind, say so and stop.

## 2. Review what you are absorbing

- `git log --oneline main..upstream/main` lists the commits the fork is behind.
- `git diff --stat main...upstream/main` shows the surface; separate the behavioral and non-test files from tests to judge conflict risk.
- Check the fork's own sync convention before branching: `gh-axi pr list --repo <fork> --state all` shows prior sync PR titles and branch names, so name the branch consistently (for example `fm/fm-upstream-sync-<N>`).

## 3. Merge on a branch

Create the sync branch, then run `git merge --no-commit --no-ff upstream/main`.
List conflicts with `git diff --name-only --diff-filter=U`.
If there are none, skip to verification.

## 4. Resolve conflicts from evidence, never by guessing

For every conflict, understand both sides before touching it:

- What the fork contributed: `git log --oneline <merge-base>..main -- <file>` names the fork's own commits, and `git diff <merge-base> main -- <file>` shows exactly what they changed.
- What upstream changed: `git diff <merge-base> upstream/main -- <file>`.

A conflict where the fork and upstream took incompatible directions in the same subsystem is a captain decision, not a mechanical fix.
The sharpest case is feature loss: the fork built something upstream lacks, and adopting upstream would silently delete it.
Stop, present the divergence with concrete evidence, options, and a recommendation, and let the captain choose with `AskUserQuestion`; never pick a direction silently.

Once the captain sets the direction:

- To adopt upstream wholesale for a subsystem, take upstream's whole version with `git checkout upstream/main -- <file>` only for files whose sole fork divergence is the part being dropped; confirm that with the per-file log above first.
- For a file that also carries fork work you are keeping, resolve surgically: keep the upstream side of the conflict hunk, or reverse-apply just the dropped commit's hunk with `git show <sha> -- <file> | git apply --reverse -`, and leave the rest of the file intact.
- Hunt the leftovers: a dropped feature usually has call sites, dead branches, and tests in other files that auto-merged cleanly, so grep the whole tree for the dropped symbols and remove every orphan, or the merge lands with dangling references and failing tests.
- Confirm nothing is lost by accident: before declaring a fork fix dropped, check whether upstream already covers it, often more generally, and record what was superseded versus genuinely removed.

## 5. Verify before landing

- `bin/fm-lint.sh` is the shellcheck gate; install the pinned version with `bin/fm-install-shellcheck.sh <dir>` and put it on `PATH` if shellcheck is missing locally.
- Run the affected suites with `bin/fm-test-run.sh tests/<name>.test.sh ...`, covering at least the subsystems the conflicts touched plus any new upstream test files.
- Distinguish a real failure from an environmental one: a test that fails only because a local dependency is absent (for example `tasks-axi`) and is byte-identical in upstream will pass in CI, so note it rather than letting it block.

## 6. Commit, PR, and land

- Commit the merge with a message that lists the absorbed commits and documents every conflict-resolution decision, especially any dropped feature and the evidence that nothing else was lost.
- Open the PR following the fork's convention, with the same resolution summary in the body.
- If the fork runs CI, wait for green and never merge red.
  If the fork has no CI at all (no workflow run has ever executed), the local lint and tests stand in for it; say so plainly.
- Merge only on the captain's explicit word, using a merge commit rather than a squash so the upstream ancestry is preserved for the next sync.
  Then fast-forward local main with `git checkout main && git merge --ff-only origin/main` and delete the sync branch.

Keep the `upstream` remote in place; it makes the next sync a one-liner.
Report the outcome in the captain's terms with the full PR URL.
