---
name: codev-session
description: Run a collaborative co-development session where the captain and a dedicated worker iteratively engineer and refine an artifact - a rule, feature set, config, query, prompt, or similar - against a real project dataset, evidence-first each round. Use when the captain invokes /codev-session or asks for a collaborative co-development, joint feature-engineering, interactive exploration, or "develop and iterate together against the examples" session. Scout-shaped: it dispatches a read-only session worker, drives an evidence-then-artifact working loop on a review board, and converges to a design report; it never ships code, since implementation is a separate captain authorization.
user-invocable: true
metadata:
  internal: true
---

# codev-session

Start and run a joint human-plus-worker design session: the captain and a dedicated worker engineer an artifact together, round by round, against a real project dataset, until the design converges.
This is exploration and iteration, not an optimizer run.
The worker never searches or tunes automatically unless the captain explicitly asks for it; every choice is the captain's, made from evidence the worker puts in front of them.
The deliverable is a converged design report, never a code change: implementation is a separate, deliberate captain authorization.

This skill owns the full procedure.
Dispatch, supervision, the scout lifecycle, and the completion gate all follow the always-loaded contracts in `AGENTS.md`; this skill only fixes the session-specific intake, the dispatch contract, and the working loop the worker must run.

## 1. Intake

Resolve the project the normal way (`AGENTS.md` section 7 intake): an explicit project wins, a clear follow-up inherits its referent, otherwise match the request against the registry and the project's code.
Proceed on one confident match and name the project in plain language.

Collect three things from the captain before dispatch:

- The target dataset or example set to develop against - the labeled examples, ranges, records, or scenarios the artifact must fit.
- The artifact being co-developed - what kind of thing this session produces (a rule, a feature set, a config, a query, a prompt, a scoring function, and so on) and where in the project it will eventually live.
- Any per-task model or worker preference - a per-task captain override wins over the configured dispatch profiles, so capture it now and honor it at spawn.

Ask exactly one concise question only when the project, the dataset, or the artifact is genuinely ambiguous; otherwise proceed and state your read.
Do not gather the captain's design thesis here - that is the worker's first board round, so it lands with the first evidence in front of it.

## 2. Dispatch contract

Route by the nature of the work: send it to a registered secondmate whose scope fits, otherwise use the main home (`AGENTS.md` section 7).
Keep `local-only`-flavored work in the main home.

Spawn one dedicated session worker through the normal path (`bin/fm-spawn.sh` after the section 4 profile and backend checks) with these session-specific constraints, written into the brief from the `bin/fm-brief.sh` scout scaffold with every `{TASK}` placeholder replaced:

- **Session/exploration dispatch profile.**
  Select the session or atelier-style dispatch profile when one is configured, unless the captain gave a per-task override; a per-task captain override always wins, so pass the exact resolved profile the captain named and verify the spawned record matches it before reporting under way.
- **Isolated worktree, scout-shaped.**
  The worker runs in its own isolated task worktree and produces knowledge, not a PR - no code ships to the project from this task.
- **Hard behavioral read-only against live project data.**
  The session works against the project's real, live data directly, under a behavioral read-only contract the brief must state as an absolute rule: read-only queries only; no INSERT/UPDATE/DELETE/DDL and no writes through any project API; no restarts of any project service; and no creation of project-side records.
  Prefer a server-enforced read-only path (a read-only transaction mode or role) so a stray write fails at the source rather than relying on discipline alone.
- **No services, containers, or compose in the worktree.**
  Evaluation runs in-process by importing the project's own engine or evaluation code from the worktree and running it against the read-only data; the worker starts no dev stack, container, or compose command.
  This is both a live-safety rule and, on projects with a shared compose project name, a collision-avoidance rule.
- **Off-hours or throttled heavy scans.**
  Any expensive scan - features across a full history, all assets, or a large corpus - runs off-hours or throttled, because the live system is serving the captain's real workload.

Confirm the worker is processing the brief, then supervise it under `AGENTS.md` section 8 like any other live work.

## 3. The working loop (the brief must encode this)

The session runs in rounds, and each round puts evidence in front of the captain BEFORE any artifact exists.
The brief must instruct the worker to run exactly this loop and to refresh an atelier review board (the usual session board posture) each round; the captain reacts on the board and may also type directly into the session.

1. **Evidence first.**
   Compute the candidate engineered features, signals, or discriminators over the real dataset and show their per-example separation BEFORE proposing any artifact - "this signal separates the positives except examples X and Y", with the per-example numbers visible.
   The first round also asks the captain for their design thesis for the artifact, then brings that first evidence.
2. **Captain reacts; assemble a variant.**
   From the promising signals the captain favors, assemble one candidate variant of the artifact.
3. **Evaluate through the real engine, per example, by how much.**
   Run the variant through the project's REAL evaluation engine (in-process), and show exactly which examples pass and fail AND by how much - the distance to passing for each condition, not just a pass/fail bit.
   If the engine has no such instrumentation, the worker builds lightweight scratch-level distance-to-threshold instrumentation in the worktree; scratch is fine and stays in the worktree.
4. **Captain steers; repeat.**
   The captain adjusts thresholds, adds or drops conditions, or changes direction; assemble the next variant and go again.

No optimizer, search, or automated tuning enters this loop unless the captain explicitly asks for it.
Every threshold is hand-set from visible evidence with the captain steering.

## 4. Safeguards (the brief must carry these)

- **Held-out examples.**
  Hold out 2-3 examples the artifact is never adjusted against, confirmed with the captain early, and report their fit every single round so any memorization is visible as it happens.
- **Expressibility flags.**
  Any feature or signal that is not expressible in the project's real product vocabulary is fine to explore, but the worker flags each one explicitly - a winning design needs eventual translation, and an unexpressible feature becomes a separate product-feature decision for the captain, not a silent dependency.
- **All scratch stays local.**
  Every scratch artifact - feature extracts, draft variants, fit tables, instrumentation, the board generator - lives in the worktree or the task's data, never on the project or the live system.

## 5. Outcome

The session converges to a self-contained design report as the Done artifact: the converged design, the full evidence, the round history, the holdout-fit history, and any expressibility flags.
Read the report and relay its findings to the captain, not merely that it finished.

- **Implementation is a separate authorization.**
  A converged design report recommends implementation but does not authorize it; building the artifact for real in the project is a distinct captain-approved ship task.
  When the captain authorizes it, promote the existing scout with `bin/fm-promote.sh` rather than opening a duplicate task.
- **Board teardown waits for the captain's word.**
  The review board and any host-side forwarder stay up while the captain is still browsing; tear the session down only on the captain's explicit go-ahead, and end the board session cleanly then.
- **Completion gate applies.**
  Before treating the session as complete, load `decision-hold-lifecycle` and register any unresolved captain decision it exposed - including the "implement for real" decision - so nothing the session surfaced is lost at teardown.
