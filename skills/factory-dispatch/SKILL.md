---
name: factory-dispatch
description: One sweep of the software factory queue. Reads registered Linear projects, claims dispatchable issues, starts one worker per repo, turns judge verdicts (posted by CI) into Linear transitions, and resets stale runs. Run by hand (`claude -p "/factory:factory-dispatch"`), from /loop, or from a LaunchAgent. Idempotent; safe to run twice.
---

# Factory dispatch

One sweep. Every state has an owner. Re-check state before every action; never act on memory from a previous sweep.

## Preconditions (exit immediately if any fails)

```bash
[[ -f ~/.factory/registry.json ]] || { echo "no registry; run /factory:factory-onboard first"; exit 1; }
[[ -n $LINEAR_TOKEN && -n $GH_TOKEN ]] || { echo "not under keycard agent exec; run scripts/dispatch.sh as documented"; exit 1; }
mkdir -p ~/.factory/logs
L="${CLAUDE_PLUGIN_ROOT}/scripts/linear.sh"   # the only way this skill talks to Linear
```
Run one dispatcher at a time (by hand, or one LaunchAgent), with `--permission-mode bypassPermissions`: under `auto` the permission classifier refuses to spawn the worker subprocess and the sweep stops to ask, which defeats the point. Never stop to ask a question in this skill; if something cannot be done, say so in the report and move on. There is no lock; every action re-checks state first, so an accidental overlap wastes a sweep rather than corrupting anything.
For each repo in the registry: `gh variable get FACTORY_PAUSED -R <owner/repo>` equal to `true` → skip that repo entirely.

`KEYCARD_ZONE` must be set. The sweep itself runs under `keycard agent exec --config keycard.toml` (`scripts/dispatch.sh` is the entrypoint; the LaunchAgent and the by-hand command both use it), which brokers `GH_TOKEN` and `LINEAR_TOKEN` in; every worker is launched the same way, so no process holds credentials of its own. All Linear reads and writes go through `$L` (`issues`, `issue`, `state`, `assign`, `comment`; `$L` with no arguments prints the contract). It exits 1 with the reason on stderr when the token is rejected or a call fails. There is no other path: dispatch and workers start with `--strict-mcp-config --mcp-config '{"mcpServers":{}}'`, so no MCP tool exists in these processes.

**A Linear failure is a precondition failure, never "nothing to do".** If `$L issues <project>` fails for any registered project, print its error and `exit 1` without touching anything.

## Sweep

For every project id in `~/.factory/registry.json` (value = local repo path; `owner/repo` from `git -C <path> remote get-url origin`):

Load the project's issues: `"$L" issues <project id>` prints `{project, issues}`; each issue carries `state`, `priority`, `createdAt`, `description`, `assignee`, `comments` (oldest first, with `createdAt`, `user`, `body`), and `blockedBy` (`[{identifier, state, resolved}]`; "no unresolved blocked-by" = every entry has `resolved: true`). Then apply the table top to bottom, one action per issue per sweep. Writes: `"$L" state <ID> "<state name>"`, `"$L" assign <ID> me`, `"$L" comment <ID> "<body>"` (or `-` with the body on stdin for multi-line comments).

| Issue state | Condition | Action |
|---|---|---|
| `🍎 To do` | no unresolved "blocked by"; body has `## Done when`; this repo has no issue currently `In Progress` | **claim then start** (below) |
| `🍎 To do` | body lacks `## Done when` | state `👀 Needs Input`; comment: `factory: needs a "## Done when" section naming one of the checks in .factory/policy.json` |
| `👩🏻‍💻 In Progress` | newest `factory:` comment older than 2h | PR exists for branch `factory/<ID>` → state `👓 In Review`; else retry (below) |
| `👓 In Review` | both `factory/judge-*` statuses on the head SHA (`gh api repos/<r>/commits/<sha>/status`) and either description starts with `REFUTED` | retry (below) with the judge findings |
| `👓 In Review` | both judge statuses present, any `failure`, none `REFUTED` (i.e. `CAVEATS`) | policy `on_caveats` is `review` → comment once `factory: caveats at <sha>, needs your review`, Kim's. Otherwise (default `retry`): no `factory: retry` comment yet for this issue → retry (below) with the judge findings; a retry already happened → comment once `factory: caveats again at <sha> after a retry, needs your review`, Kim's. |
| `👓 In Review` | PR red / conflicted / closed-unmerged for over 1h | retry (below) |
| `👓 In Review` | PR merged | state `✅ Done`; comment: `factory: merged <pr-url>` |
| `👀 Needs Input`, `⛔️ Blocked`, anything else | — | nothing. Kim's. |

Order `To do` candidates by priority, then oldest `createdAt`.

### Claim then start

1. `"$L" state <ID> "👩🏻‍💻 In Progress"`, `"$L" assign <ID> me`, `"$L" comment <ID> "factory: run <8-hex-id> <ISO timestamp>"`. The claim is written **before** anything starts.
2. Start the worker, detached, logging to `~/.factory/logs/<ID>.log`:
```bash
repo=<local path>; id=<ISSUE-ID>; wt="$(dirname "$repo")/$(basename "$repo")-factory-$id"
git -C "$repo" fetch -q origin
if [[ -d $wt ]]; then git -C "$wt" pull -q --rebase origin "factory/$id" || true          # retry: reuse the worktree
elif git -C "$repo" ls-remote -q --exit-code origin "factory/$id" >/dev/null; then
  git -C "$repo" worktree add "$wt" "factory/$id"                                            # retry, worktree gone: track the branch
else git -C "$repo" worktree add -b "factory/$id" "$wt" origin/HEAD; fi                     # first run
( cd "$wt" && perl -e 'alarm 5400; exec @ARGV' -- \
    keycard agent exec --config "${CLAUDE_PLUGIN_ROOT}/keycard.toml" --zone "$KEYCARD_ZONE" -- \
      claude -p "/factory:factory-worker $id" --plugin-dir "${CLAUDE_PLUGIN_ROOT}" \
        --settings "${CLAUDE_PLUGIN_ROOT}/worker-settings.json" --permission-mode auto --max-turns 80 \
        --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  ) > ~/.factory/logs/$id.log 2>&1 &
# budget: 80 turns and 90 minutes wall clock per run; worker-settings.json is the egress allowlist for the worker's shell commands.
# No MCP servers in the worker (same flags as dispatch.sh): the claude.ai connectors that come with the Claude login, Linear
# included, are not available, so scripts/linear.sh with the brokered token is the only Linear path.
```
3. Do not wait for it. Report `started <ID> in <wt>`.

### Retry

Count existing `factory: retry N` comments. Next N = count + 1. If N >= 2: state `⛔️ Blocked`, comment `factory: retry budget exhausted (<reason>)`. Else: state `🍎 To do`, comment `factory: retry N (<reason>)` followed by the judge findings (below) when the reason is a verdict. The next sweep re-dispatches it; the worker reads the retry comment and acts on the findings.

### Judge findings (what the worker needs to act on a verdict)

The status descriptions are 140 characters; the findings live in the judge run's transcript artifact. For the head SHA:
```bash
run=$(gh run list -R <r> --workflow factory-judge.yml --json databaseId,headSha --jq '[.[]|select(.headSha=="<sha>")][0].databaseId')
gh run download "$run" -R <r> -n "judge-transcripts-<sha>" -D "$d"
for m in claude codex; do echo "## $m"; grep -E '^(- |\* |[0-9]+\. |VERDICT)' "$d/$m.txt" | tail -15; done
```
Append that output to the retry comment under `Judge findings at <sha>:`, with: "Keep the existing PR and push to its branch. Out of scope is unchanged." (Pipe the whole comment to `"$L" comment <ID> -`.) A worker must never be sent back without the findings; an empty retry just repeats the same mistake.

## Report

One line per action taken, then `sweep done`. If nothing was actionable, `sweep done: nothing to do`.
