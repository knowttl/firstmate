---
name: firstmate-sync
description: >-
  Sync this firstmate fork with the upstream parent it was forked from: firstmate scopes the gap and a dedicated crewmate performs the merge, resolving conflicts from evidence and landing the result through a PR.
  Use when the captain invokes /firstmate-sync or asks to sync the fork with upstream, catch up on the commits the fork is behind, merge upstream into the fork, or pull changes from the parent repository.
user-invocable: true
metadata:
  internal: true
---

# firstmate-sync

Bring this firstmate fork up to date with the upstream parent it was forked from, absorbing the commits it is behind while preserving the fork's own work.
This operates on the firstmate home repo itself, which is shared tracked material, not on a project clone; syncing a project's own fork is a crewmate's job inside that project's worktree.
It is the opposite direction from `/updatefirstmate`: that skill fast-forwards this home from `origin` to pick up already-landed changes, while this skill merges new commits from the upstream parent into the fork.

Resolving merge conflicts on shared tracked material is substantial coding, so firstmate never performs the merge itself: firstmate scopes the sync and supervises, a dedicated crewmate carries out the merge, and the captain's explicit word lands the result through this repo's PR path (`AGENTS.md` hard rule 2 and section 7).

## 1. Firstmate scopes the gap (read-only)

Firstmate does this directly.
Firstmate does not create the sync branch, merge, resolve conflicts, or commit in the primary checkout.

- The upstream parent is the fork's GitHub parent: `gh-axi api repos/<owner>/<repo> --jq '.parent.full_name'`.
- Add or repoint an `upstream` remote at it and fetch: `git remote add upstream https://github.com/<parent>.git` (or `git remote set-url upstream ...`), then `git fetch upstream`.
- Count the divergence: `git rev-list --count main..upstream/main` is how many commits the fork is behind, and the reverse range is how many it is ahead.
- Record the merge base: `git merge-base main upstream/main`.
- `git log --oneline main..upstream/main` lists the commits the fork is behind, and `git diff --stat main...upstream/main` shows the surface, enough to eyeball conflict risk for the brief.
- Check the fork's own sync convention: `gh-axi pr list --repo <fork> --state all` shows prior sync PR titles and branch names, so the crewmate can name its branch consistently (for example `fm/fm-upstream-sync-<N>`).

If the fork is not behind, say so and stop.

## 2. Firstmate briefs and spawns the sync crewmate

Write a ship brief (`AGENTS.md` section 11, `bin/fm-brief.sh`) carrying the gap evidence from step 1: the upstream parent, the divergence counts, the merge base, the commit list, and the conflict-risk surface.
The brief requires `firstmate-coding-guidelines`, since the crewmate is changing firstmate's own shared tracked material.
Spawn the crewmate into its own isolated worktree of the firstmate home repo through `AGENTS.md` section 7's spawn path (`bin/fm-spawn.sh`), mode `direct-PR`: the crewmate raises the PR itself and stops there.

The sync crewmate runs on a pinned profile: `--harness claude --model claude-sonnet-5 --effort high`.
This is the captain's standing pin for firstmate-sync, set 2026-08-27, overridable only by an explicit per-run captain instruction; do not substitute a different harness, model, or effort from routine dispatch resolution.

## 3. The crewmate's contract: merge, resolve, verify, and open the PR

Everything below is what the brief asks the crewmate to do inside its own worktree, not a firstmate action.

### Merge on a branch

Create the sync branch, then run `git merge --no-commit --no-ff upstream/main`.
List conflicts with `git diff --name-only --diff-filter=U`.
If there are none, skip to verification.

### Resolve conflicts from evidence, never by guessing

For every conflict, understand both sides before touching it:

- What the fork contributed: `git log --oneline <merge-base>..main -- <file>` names the fork's own commits, and `git diff <merge-base> main -- <file>` shows exactly what they changed.
- What upstream changed: `git diff <merge-base> upstream/main -- <file>`.

A conflict where the fork and upstream took incompatible directions in the same subsystem is a captain decision, not a mechanical fix.
The sharpest case is feature loss: the fork built something upstream lacks, and adopting upstream would silently delete it.
The crewmate never addresses the captain directly (`AGENTS.md` hard rule 4): it stops and appends a `needs-decision:` status line naming the divergence, the concrete evidence, and the options (status protocol owned by `bin/fm-brief.sh`).
Firstmate then presents that divergence to the captain with evidence, options, and a recommendation, gets the captain's choice, and relays it back to the crewmate through `fm-send` with `--resolve-key` (`AGENTS.md` section 7's steering contract), which closes the crewmate's open decision record.

Once the direction is set:

- To adopt upstream wholesale for a subsystem, take upstream's whole version with `git checkout upstream/main -- <file>` only for files whose sole fork divergence is the part being dropped; confirm that with the per-file log above first.
- For a file that also carries fork work being kept, resolve surgically: keep the upstream side of the conflict hunk, or reverse-apply just the dropped commit's hunk with `git show <sha> -- <file> | git apply --reverse -`, and leave the rest of the file intact.
- Hunt the leftovers: a dropped feature usually has call sites, dead branches, and tests in other files that auto-merged cleanly, so grep the whole tree for the dropped symbols and remove every orphan, or the merge lands with dangling references and failing tests.
- Confirm nothing is lost by accident: before declaring a fork fix dropped, check whether upstream already covers it, often more generally, and record what was superseded versus genuinely removed.

### Verify before opening the PR

- `bin/fm-lint.sh` is the shellcheck gate; install the pinned version with `bin/fm-install-shellcheck.sh <dir>` and put it on `PATH` if shellcheck is missing locally.
- Run the affected suites with `bin/fm-test-run.sh tests/<name>.test.sh ...`, covering at least the subsystems the conflicts touched plus any new upstream test files.
- Distinguish a real failure from an environmental one: a test that fails only because a local dependency is absent (for example `tasks-axi`) and is byte-identical in upstream will pass in CI, so note it rather than letting it block.

### Commit and open the PR

- Commit the merge with a message that lists the absorbed commits and documents every conflict-resolution decision, especially any dropped feature and the evidence that nothing else was lost.
- Push the branch and open the PR following the fork's convention, with the same resolution summary in the body, then stop (`AGENTS.md` section 7's `direct-PR` contract).

## 4. Firstmate lands the PR on the captain's word

- If the fork runs CI, wait for green and never merge red.
  If the fork has no CI at all (no workflow run has ever executed), the local lint and tests from step 3 stand in for it; say so plainly.
- Merge only on the captain's explicit word, using a merge commit rather than a squash so the upstream ancestry is preserved for the next sync (`bin/fm-pr-merge.sh`, `AGENTS.md` hard rule 2).
- Fast-forward local main with `git checkout main && git merge --ff-only origin/main` and delete the sync branch.

Keep the `upstream` remote in place; it makes the next sync a one-liner.
Report the outcome in the captain's terms with the full PR URL.
