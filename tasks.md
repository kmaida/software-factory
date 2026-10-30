# Writing tasks

A task is one JSON file in `queue/`: `{repo, base_branch, task_id, instructions}`. The orchestrator checks the schema; `factory lint` checks the conventions below; `factory sweep` runs the queue in filename order. Nobody is awake while it runs, so a task has to stand on its own: the agent never gets to ask, and the judge has to be able to tell whether it is done.

## Files and ids

- Filename is `<task_id>.json`, and `task_id` starts with a number so the night runs in order: `010-scaffold`, `020-schema`, `030-auth-api`.
- `base_branch` is `main` for work that stands alone, or `factory/<earlier task_id>` for work that builds on an earlier task. GitHub stacks the pull requests and retargets each one to `main` as you merge in order. A refuted or failed task still pushes its branch as evidence, so `sweep` skips every task that depends on it, directly or through another skipped task, and moves them to `queue/failed/` unrun. A base that is not in tonight's queue is trusted to exist on the repo already.
- Independent tasks should all use `main`, so one refutation does not block them.

## Instructions

Five headings, always in this order. The judge receives this text verbatim, so "Done when" is also the judge's acceptance test and "Scope" / "Out of scope" are its refutation rules.

```
Goal: one sentence, what exists when this is done.

Context: read docs/PLAN.md section 3.2 first. Conventions: <framework, test runner, lint, folder layout, naming>. Decisions already made: <library, schema, API shape>.

Scope: files or directories this task may create or change. Everything else is off limits.

Done when: `npm test && npm run typecheck` passes, and <one observable behaviour, stated concretely>.

Out of scope: <what a helpful agent would be tempted to add>. Do not touch <paths>. Do not add dependencies.
```

## Sizing

- One task is one pull request you would want to review in ten minutes: one module or one vertical slice, under about 300 lines of diff. Where you know the shape, say it: "one file, one function, no new test file."
- Every task leaves the checks green on its own branch. The next task's judge runs them too.
- Nothing that needs a decision. No "choose a library", no "pick a schema". Decide in the plan and state it under Context.
- Nothing that needs a secret, an account, or a network service the repo's tests do not already have.
- Nothing that can only be done against an unmerged branch other than its own `base_branch`.
- Under "Out of scope" or "Done when", tell the worker: if the task cannot be completed, commit `docs/BLOCKED-<task_id>.md` with the reason. A branch with that file is refuted with the reason in the findings, so a `factory batch` chain stops with evidence instead of a silent exit 3.
- The first task in a new repository is scaffold, test runner and CI. Nothing stacks on it the same night until you have merged it once and seen the judge run its checks.

## Against over-engineering

Every worker round starts with `worker-prompt.md`: least code that satisfies "Done when", no speculative abstraction, no handling for states that cannot occur, one test per behaviour, no new dependencies. The judge treats the same things as findings and returns CAVEATS for them even when everything passes, which costs the worker a revision round. "Done when" is the ceiling: anything beyond it is out of scope by default, so write it tight.

## Before bed

```sh
./factory lint          # schema, <number>-<name> ids, filename = task_id, the five headings in order, base_branch order
./factory sweep         # runs lint first and refuses to start on any problem
```

In the morning, `./factory report` and the stacked pull requests, oldest first. A task in `queue/failed/` has its reason in `runs/<run_id>/manifest.json` and, if the judge got that far, `judge-<round>.md`.
