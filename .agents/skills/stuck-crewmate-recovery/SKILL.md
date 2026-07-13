---
name: stuck-crewmate-recovery
description: Agent-only playbook for stuck firstmate direct reports. Use after a stale wake, looping pane, repeated confusion, an answered-by-brief question, an unresponsive crewmate, or a failed steer. Escalates from peek, to one-line steer, to harness-specific interrupt, to relaunch with progress, to failed status.
user-invocable: false
metadata:
  internal: true
---

# stuck-crewmate-recovery

Use this playbook when a direct report is stale, looping, repeatedly confused, asking a question its brief already answers, has answered an earlier supervisor question in-pane, is parked at an `awaiting_agent` gate, is unresponsive, or when a steer failed to land.

Load `harness-adapters` before sending an interrupt, exit command, resume command, or harness-specific skill invocation.
The target window's harness is recorded as `harness=` in `state/<id>.meta`.

An `awaiting_agent: parked` or `state: parked · source: run-step` read is an act-now signal, not a reason to wait for another stale poll.

Escalate in order:

1. Read `bin/fm-crew-state.sh <id>` and peek the pane.
2. If the pane contains an answer to your earlier question, consume it and continue the task.
3. If the run is parked, answer its gate when authorized or escalate the decision upward immediately.
4. If the crewmate is waiting on a question its brief already answers, answer in one line via `bin/fm-send.sh`.
5. If the crewmate is confused or looping, interrupt with the adapter's interrupt key, then redirect with one corrective line.
   For example, for a single-Escape adapter: `bin/fm-send.sh <window> --key Escape`.
6. If the crewmate is genuinely wedged after redirection, exit the agent with the adapter's exit command and relaunch with the same brief plus a `progress so far` note appended to it.
   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead.
   A low context reading is not wedging; modern harnesses auto-compact and keep going.
   The worktree and commits persist, so relaunch is cheap.
7. If a second relaunch fails too, write `failed` to the backlog and tell the captain with evidence.
