---
name: factory-dispatch
description: One sweep of the software factory queue. Reads registered Linear projects, claims dispatchable issues, starts one worker per repo, turns judge verdicts (posted by CI) into Linear transitions, and resets stale runs. Run by hand (`claude -p "/factory:factory-dispatch"`), from /loop, or from a LaunchAgent. Idempotent; safe to run twice.
---

# Factory dispatch

One sweep. Every state has an owner. Re-check state before every action; never act on memory from a previous sweep.

## Preconditions (exit immediately if any fails)

```bash
[[ -f ~/.factory/registry.json ]] || { echo "no registry; run /factory:factory-onboard first"; exit 1; }
mkdir -p ~/.factory/logs
```
Run one dispatcher at a time (by hand, or one LaunchAgent), with `--permission-mode bypassPermissions`: under `auto` the permission classifier refuses to spawn the worker subprocess and the sweep stops to ask, which defeats the point. Never stop to ask a question in this skill; if something cannot be done, say so in the report and move on. There is no lock; every action re-checks state first, so an accidental overlap wastes a sweep rather than corrupting anything.
For each repo in the registry: `gh variable get FACTORY_PAUSED -R <owner/repo>` equal to `true` → skip that repo entirely.

Launch wrapper (used for every subprocess below). `KEYCARD_ZONE` must be set. If `FACTORY_DRY_RUN=1` is set, print `WARNING: dry run, running under the operator's own credentials` once and run the bare command; this exists only until the Keycard GitHub resource is registered and must not be used after.
```bash
run_kc() { [[ ${FACTORY_DRY_RUN:-} == 1 ]] && { "$@"; return; }
  keycard agent exec --config "${CLAUDE_PLUGIN_ROOT}/keycard.toml" --zone "$KEYCARD_ZONE" -- "$@"; }
```

## Sweep

For every project id in `~/.factory/registry.json` (value = local repo path; `owner/repo` from `git -C <path> remote get-url origin`):

Load the project's issues with the Linear MCP (`list_issues` filtered by project and label `factory`, with `state`, `comments`, `attachments`, `relations`). Then apply the table top to bottom, one action per issue per sweep.

| Issue state | Condition | Action |
|---|---|---|
| `🍎 To do` | no unresolved "blocked by"; body has `## Done when`; this repo has no issue currently `In Progress` | **claim then start** (below) |
| `🍎 To do` | body lacks `## Done when` | `save_issue` state `👀 Needs Input`; `save_comment`: `factory: needs a "## Done when" section naming one of the checks in .factory/policy.json` |
| `👩🏻‍💻 In Progress` | newest `factory:` comment older than 2h | PR exists for branch `factory/<ID>` → state `👓 In Review`; else retry (below) |
| `👓 In Review` | both `factory/judge-*` statuses on the head SHA (`gh api repos/<r>/commits/<sha>/status`) and either description starts with `REFUTED` | retry (below); `save_comment`: `factory: refuted at <sha>: <both descriptions>` |
| `👓 In Review` | both judge statuses present, any `failure`, none `REFUTED` (i.e. `CAVEATS`) | `save_comment` once: `factory: caveats at <sha>, needs your review`. Kim's. |
| `👓 In Review` | PR red / conflicted / closed-unmerged for over 1h | retry (below) |
| `👓 In Review` | PR merged | state `✅ Done`; `save_comment`: `factory: merged <pr-url>` |
| `👀 Needs Input`, `⛔️ Blocked`, anything else | — | nothing. Kim's. |

Order `To do` candidates by priority, then oldest `createdAt`.

### Claim then start

1. `save_issue`: state `👩🏻‍💻 In Progress`, assignee me. `save_comment`: `factory: run <8-hex-id> <ISO timestamp>`. The claim is written **before** anything starts.
2. Start the worker, detached, logging to `~/.factory/logs/<ID>.log`:
```bash
repo=<local path>; id=<ISSUE-ID>; wt="$(dirname "$repo")/$(basename "$repo")-factory-$id"
git -C "$repo" fetch -q origin
if [[ -d $wt ]]; then git -C "$wt" pull -q --rebase origin "factory/$id" || true          # retry: reuse the worktree
elif git -C "$repo" ls-remote -q --exit-code origin "factory/$id" >/dev/null; then
  git -C "$repo" worktree add "$wt" "factory/$id"                                            # retry, worktree gone: track the branch
else git -C "$repo" worktree add -b "factory/$id" "$wt" origin/HEAD; fi                     # first run
( cd "$wt" && run_kc claude -p "/factory:factory-worker $id" --plugin-dir "${CLAUDE_PLUGIN_ROOT}" --permission-mode auto ) > ~/.factory/logs/$id.log 2>&1 &
```
3. Do not wait for it. Report `started <ID> in <wt>`.

### Retry

Count existing `factory: retry N` comments. Next N = count + 1. If N >= 2: state `⛔️ Blocked`, comment `factory: retry budget exhausted (<reason>)`. Else: state `🍎 To do`, comment `factory: retry N (<reason>)`. The next sweep re-dispatches it; the worker reads the retry comment and the judge's findings.

## Report

One line per action taken, then `sweep done`. If nothing was actionable, `sweep done: nothing to do`.
