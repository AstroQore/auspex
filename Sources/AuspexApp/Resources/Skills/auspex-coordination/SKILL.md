---
name: auspex-coordination
description: Coordinate Supervisor, Worker, and Reviewer work through Auspex when a brief names an Auspex task, when handing work to another agent, or when reviewing shared task progress. Auspex remains the task state source; this skill is only the operating playbook.
metadata:
  version: 1.0.0
---

# Auspex Coordination

Use this skill for explicit multi-agent work tracked by Auspex. It helps the
person understand many simultaneous sessions without turning coordination into
the work itself.

Auspex has two layers:

- Passive observation is the baseline. A session remains visible even if it
  never loads this skill or calls MCP.
- MCP adds explicit task identity, progress, decisions, evidence, risk, and
  requests for human attention. MCP is the state source and enforcement point;
  this file does not override its capabilities or responses.

## Invariants

1. The user's task comes first. Keep coordination updates short and material.
2. Discover the tools exposed by the connected Auspex server and follow their
   schemas. Never invent a call because this playbook mentions a newer tool.
3. If the brief includes an Auspex task id, use it. If it does not, keep the
   implicit session task: do not create or claim an explicit task merely to
   satisfy this protocol.
4. Never claim work already held by another live session. Inspect the task and
   peer context, then ask for a handoff or use `tasks.release` only when the
   owner is deliberately giving it up and the server permits the transition.
5. Agent completion means Review, not Closed. Only a person closes accepted
   work unless the server explicitly grants a reviewer that authority.
6. Do not put raw transcripts, prompts, credentials, full command output, or
   secrets in task notes. Record only a compact fact and a checkable reference.
7. If MCP is unavailable or `sessions.self` cannot resolve this process,
   continue the user's work. State the degraded coordination honestly; never
   report a claim, notification, or update that the server rejected.

## Start a tracked turn

When the brief names a task id:

1. Call `sessions.self` to confirm which observed session this connection owns.
2. Call `overview.get` for the current project to see active tasks, attention,
   roles, scopes, conflicts, and orphaned claims.
3. Call `tasks.get(task_id)` to read the objective, dependencies, acceptance
   conditions, notes, evidence, and current members.
4. If the task is ready and unclaimed, call
   `tasks.claim(task_id, role, scope)`. Keep `scope` concrete enough for another
   agent to detect overlap.
5. Call `auspex.report` with the immediate focus and progress only when those
   facts are useful to a person scanning the board.

When there is no task id, do the requested work normally. Use `auspex.notify`
when the person is needed, but do not search for or manufacture a task unless
the user explicitly asks for project coordination.

## Worker playbook

- Read before writing. If another session is related, use `sessions.get` for
  its safe context capsule: role, scope, focus, progress, material event,
  decisions, evidence, and risks. Do not request its raw transcript through
  task coordination.
- Call `auspex.report` at phase changes, not after every tool call. Good phases
  are investigating, planning, implementing, validating, and wrapping up.
- Use `tasks.log` sparingly:
  - `decision`: a choice a later worker must not silently reverse.
  - `evidence`: a checkable commit, URL, file path, test, or readback; include
    its `ref`.
  - `risk`: a concrete unresolved concern or caveat.
- If blocked, first record the blocker with `tasks.update`, then call
  `auspex.notify(kind="blocked")` with one sentence saying what human action or
  external change is required. Do not go quiet while waiting.
- If input is needed, call `auspex.notify(kind="needs_input")` with the exact
  decision needed. If work needs inspection, use `needs_review`.
- Before completion, add concise evidence, then call `tasks.complete` with what
  was finished. This moves the task to Review; it does not certify acceptance.
- If abandoning assigned work, record why and use `tasks.release` when the
  connected server provides it. Do not leave a knowingly stale claim behind.

## Supervisor playbook

1. Call `overview.get` before decomposing work. Reuse an existing matching plan
   or task instead of duplicating it.
2. Create a plan only for a real decomposition. Create one bounded task per
   worker with objective, scope, dependencies, acceptance criteria, and a task
   id in the worker brief.
3. Make scopes non-overlapping where possible: separate files, subsystems,
   worktrees, or read-only review. If overlap is intentional, name the owner of
   the shared boundary.
4. Use task and session capsules to follow progress. Do not interrupt workers
   merely because they have not emitted a recent report; observed activity and
   reported progress have different provenance.
5. Surface collisions, blocked dependencies, orphaned claims, and Review work
   to the person. Do not automatically kill, steal, or reassign a session.

## Reviewer playbook

1. Call `tasks.get(task_id)` and inspect the acceptance conditions, material
   notes, evidence, risks, and contributing sessions.
2. Use `sessions.get` when a contributor's safe capsule is needed. Treat
   self-reported progress as a claim, observed events as observation, and
   inferred health as inference.
3. Verify the artifact at the appropriate final boundary. A command exiting
   zero or an agent saying "done" is not sufficient evidence by itself.
4. Log new checkable evidence or a remaining risk. Ask for changes with
   `tasks.update` and `auspex.notify(kind="needs_review")` when a person must
   decide.
5. Do not close the task unless the connected server grants that action and the
   person explicitly delegated acceptance authority. Otherwise leave it in
   Review with a concise recommendation.

## Degraded mode

Auspex coordination must never become a prerequisite for useful work.

- MCP unavailable: continue, keep a local handoff summary, and say that board
  updates were not recorded.
- Identity unresolved: use read-only overview/task context if available;
  continue without claim/report/notify calls that require identity.
- A write is rejected: respect the server state, do not retry by impersonating
  another session or supplying a guessed session id.
- A tool from this playbook is absent: follow the server's advertised
  capabilities and use the nearest safe read-only alternative.

In every degraded case, finish the user's actual task if it remains safe and
possible.
