# Factory hardening plan

Goal: never open an empty (BLOCKED-only) or conflicting PR, and recover from more failures without a human.

Evidence (batch of 2026-10-31, keycard-workshop-platform): 30 tasks reported "28 PRs, 2 failed". Real result: 13 PRs with
code, 15 PRs whose only own change was `docs/BLOCKED-<task_id>.md` (judge said VERIFIED/CAVEATS), 2 REFUTED after 3 rounds
(exit 5). 11 of the 15 blocked because, after a failure, `cmd_batch` sets `prev=` and the next task is cut from `main`,
which lacks every unmerged predecessor. 4 blocked on real spec gaps. 035 was REFUTED while still making progress each round.

## Changes

1. **Chain from the last good task.** `cmd_batch`: on a non-zero exit, leave `prev` alone instead of `prev=`. The
   `--continue` skip rule still skips tasks whose declared `base_branch` failed tonight.

2. **Gates before `open_pr`, recorded as a manifest `outcome`.** Raw exit codes cannot carry the meaning: container
   exits pass through unchanged (`run_container`, `status=${PIPESTATUS[1]}`), and the test stub's worker already exits 7.
   So each gate sets `outcome` in the manifest and a status (`10` blocked, `11` conflict, `12` gate error); the batch
   counts and reports by `outcome`, not by status.
   - **Blocked:** `git -C "$work" diff --name-only "$base_sha" "$head"` lists only `docs/BLOCKED-*` → `outcome:"blocked"`,
     no PR. `base_sha` is the chain base, so predecessors' notes are not counted. This gate runs right after the push,
     before the `case "$verdict"` dispatch, whatever the verdict: with change 8 a BLOCKED-only commit is REFUTED
     (its Done when clauses are MISSING), and the blocked outcome must win over exit 5.
   - **Conflict:** with the push token (the same fd-3 credential helper the clone uses), `git fetch origin "$base_branch"`
     right before the check, so the target is current, not as of the clone hours earlier. Then
     `git merge-tree --write-tree "origin/$base_branch" "$head"`: 0 clean; 1 → `outcome:"conflict"`, no PR; any other
     status (fetch failed, missing ref, git older than 2.38) → `outcome:"gate_error"`, no PR. Log the command output.
     A merge into the target after this check can still conflict; the PR shows that, and that is the human's merge.

3. **The reason reaches the phone.** The blocked gate saves the note's first non-blank, non-heading line (cut to 200
   chars) as manifest `reason`, since `$work` is deleted when the run ends. The batch's failure notification appends
   `reason` when present, and the summary adds `<b> blocked`. `notify` escapes `\` and `"` in its body before writing the
   curl config, so note text cannot break the `data = "..."` line. A single `factory run` still sends nothing.

4. **More rounds while progress continues.** `MAX_ROUNDS=${FACTORY_MAX_ROUNDS:-5}` (was 3). The existing "no new commits
   → stop" rule already ends a stalled loop. `jprompt` gains `Round <n> of <MAX_ROUNDS>`, and judge-prompt.md's "at most
   three rounds" becomes "a fixed number of rounds (see Round below)".

5. **Tests.** Update the existing `test-factory.sh` cases that assume 3 rounds (verdict sequences in `STUB_VERDICTS`,
   round counts) and the chain assertion that expects "resumes from the task's own base". Add one case each for:
   blocked-only diff → no PR and `outcome:"blocked"`; conflicting target → no PR and `outcome:"conflict"`; a task after
   a failed task is cut from the last good branch. Each fails on the old script.

6. **Worker pre-check (prompt only).** worker-prompt.md gains one paragraph: before writing code, confirm that every
   table, column, export, file and dependency the task's Context, Scope or Done when relies on exists on the branch
   you are on (things listed under Out of scope are not prerequisites); if one is missing and the
   task does not add it, write and commit `docs/BLOCKED-<task_id>.md` at once (what is missing, which task should add
   it) and stop. The judge round still runs (the factory does not look for the note before the gate in change 2), but
   the worker round shrinks from a long attempt to a short check, and the blocked gate then ends the run with no PR.

7. **`factory requeue <path-in-queue/failed>`.** Takes the archived task file as given. Executed runs are archived as
   `failed/<run_id>.json` (`run_id` = `<timestamp>-<task_id>`, so the run dir is `runs/<run_id>/`); skipped tasks are
   `failed/<batch_id>-<name>.json` and have no run. Writes `queue/<id>-r<N>.json` with `task_id` `<id>-r<N>` (N = 1 +
   highest existing `-r<N>` for that id in queue/, done/ and failed/; `-r<N>` matches `ID_RE`), copying every other
   field as is, and appends to `instructions` one paragraph only when the exact run has the evidence:
   `Previous attempt (<task_id>): judge <verdict> after <rounds> round(s). Findings:` plus that run's last
   `judge-<rounds>.md` (cut to 20000 chars) when `judge.rounds` > 0; `Previous attempt (<task_id>) was blocked: <reason>`
   when the manifest has `outcome:"blocked"`; nothing appended for a skipped task, a preflight failure (no manifest) or
   a round-1 worker failure (no judge file). Lint still has to pass. Never automatic: the batch does not call it, so a
   task that fails the same way twice is not run a third time on its own.

8. **Judge verdict must map Done when to evidence (prompt only).** judge-prompt.md: before the VERDICT line, one
   line per clause of the task's "Done when", each `DONE: <clause> -- <test file or command that proves it>` or
   `MISSING: <clause>`. Any MISSING line forbids VERIFIED and CAVEATS. The factory does not parse these lines; they
   make a VERIFIED that skipped a clause visible in the PR body and in `judge-<N>.md`.

## Outside the factory

- **Spec gaps** (4 of last night's 15 blocked) are task-file bugs. Authoring rule for the task generator, checked by
  nobody: a task that names a column, export or dependency must either list it under Scope or name the earlier task
  that adds it. Change 6 only makes a missing prerequisite fail fast; it does not check the rule.
- **Merge is the bottleneck.** The target ruleset needs one approval and the App cannot approve its own PR, so a
  night ends with a stack of PRs waiting for a human, and the next night's chain cannot start from merged work until
  then. That is the intended safety gate; keep it. With change 1, bottom-up merging makes each later PR's diff its own
  commits only.

## Skipped on purpose

- A factory-run check container (`npm test` outside the judge): the judge already runs and records checks, and the
  target repo's required CI blocks merge. Add when a VERIFIED PR is seen with red CI.
- An end-of-batch retry pass: with change 4 a REFUTED task already gets the extra rounds a retry would give, and retries
  need new task ids because `factory/<id>` exists. Add when tasks fail for transient reasons (rate limits, docker).
- Auto-amending specs for real spec gaps: widening scope is the human decision the judge enforces. The BLOCKED note
  already says how to unblock, and change 3 puts its first line on the phone.
- Dependency graph between tasks: the chain is linear; a dependent of a failed task now runs on the last good branch
  and blocks in a minute or two, which is the information we want.
