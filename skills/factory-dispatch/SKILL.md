---
name: factory-dispatch
description: One sweep of the software factory queue. Reads registered Linear projects, claims dispatchable issues, starts one worker per repo, turns judge verdicts (posted by CI) into Linear transitions, and resets stale runs. Run by hand (`claude -p "/factory:factory-dispatch"`), from /loop, or from a LaunchAgent. Idempotent; safe to run twice, and a second dispatcher started while one is running exits on the lock.
---

# Factory dispatch

One sweep. Every state has an owner. Re-check state before every action; never act on memory from a previous sweep.

## Preconditions (exit immediately if any fails)

```bash
[[ -f ~/.factory/registry.json ]] || { echo "no registry; run /factory:factory-onboard first"; exit 1; }
[[ -n $LINEAR_TOKEN && -n $GH_TOKEN ]] || { echo "not under keycard agent exec; run scripts/dispatch.sh as documented"; exit 1; }
mkdir -p ~/.factory/logs
L="${CLAUDE_PLUGIN_ROOT}/scripts/linear.sh"   # the only way this skill talks to Linear
lock=~/.factory/dispatch.lock                  # one dispatcher at a time; mkdir is atomic and stock macOS has no flock
[[ -n $(find "$lock" -maxdepth 0 -mmin +60 2>/dev/null) ]] && { echo "removing stale lock ($(stat -f %Sm "$lock"))"; rmdir "$lock"; }
mkdir "$lock" 2>/dev/null || { echo "another dispatcher holds $lock; exiting"; exit 0; }
```
The lock is held from here to the end of the sweep. **Every exit after this line releases it** with `rmdir ~/.factory/dispatch.lock`: the Linear precondition failure below, and the report at the end. A lock older than 60 minutes is stale (a sweep takes minutes and never waits on workers; a dispatcher that died mid-sweep is the only way to get there) and is removed and retaken.
Run one dispatcher at a time (by hand, or one LaunchAgent), with `--permission-mode bypassPermissions`: under `auto` the permission classifier refuses to spawn the worker subprocess and the sweep stops to ask, which defeats the point. Never stop to ask a question in this skill; if something cannot be done, say so in the report and move on. Overlap is not harmless: two sweeps can both see the same unclaimed issue and start two workers in one worktree. The lock above is what prevents it; re-checking state before every action protects against stale memory within a sweep, not against a second dispatcher.
For each repo in the registry: `gh variable get FACTORY_PAUSED -R <owner/repo>` equal to `true` → skip that repo entirely.

`KEYCARD_ZONE` must be set. The sweep itself runs under `keycard agent exec --config keycard.toml` (`scripts/dispatch.sh` is the entrypoint; the LaunchAgent and the by-hand command both use it), which brokers `GH_TOKEN` and `LINEAR_TOKEN` in; every worker is launched the same way, so no process holds credentials of its own. All Linear reads and writes go through `$L` (`issues`, `issue`, `state`, `assign`, `comment`; `$L` with no arguments prints the contract). It exits 1 with the reason on stderr when the token is rejected or a call fails. There is no other path: dispatch and workers start with `--strict-mcp-config --mcp-config '{"mcpServers":{}}'`, so no MCP tool exists in these processes.

**A Linear failure is a precondition failure, never "nothing to do".** If `$L issues <project>` fails for any registered project, print its error, `rmdir ~/.factory/dispatch.lock`, and `exit 1` without touching anything.

## Sweep

For every project id in `~/.factory/registry.json` (value = local repo path; `owner/repo` from `git -C <path> remote get-url origin`):

Load the project's issues: `"$L" issues <project id>` prints `{project, issues}`; each issue carries `state`, `priority`, `createdAt`, `description`, `assignee`, `comments` (oldest first, with `createdAt`, `user`, `body`), and `blockedBy` (`[{identifier, state, resolved}]`; "no unresolved blocked-by" = every entry has `resolved: true`). Then apply the table top to bottom, one action per issue per sweep. Writes: `"$L" state <ID> "<state name>"`, `"$L" assign <ID> me`, `"$L" comment <ID> "<body>"` (or `-` with the body on stdin for multi-line comments).

| Issue state | Condition | Action |
|---|---|---|
| `🍎 To do` | no unresolved "blocked by"; body has `## Done when`; this repo has no issue currently `In Progress` | **claim then start** (below) |
| `🍎 To do` | body lacks `## Done when` | state `👀 Needs Input`; comment: `factory: needs a "## Done when" section naming one of the checks in .factory/policy.json` |
| `👩🏻‍💻 In Progress` | newest `factory:` comment older than 2h | PR exists for branch `factory/<ID>` → state `👓 In Review`; else retry (below) |
| `👓 In Review` | PR merged | state `✅ Done`; comment: `factory: merged <pr-url>` |
| `👓 In Review` | both `factory/judge-*` statuses on the head SHA (`gh api repos/<r>/commits/<sha>/status`) and either description starts with `REFUTED` | retry (below) with the judge findings |
| `👓 In Review` | both judge statuses present, any `failure`, none `REFUTED` (i.e. `CAVEATS`) | policy `on_caveats` is `review` → comment once `factory: caveats at <sha>, needs your review` followed by the judge findings (below), Kim's. Otherwise (default `retry`): no `factory: retry` comment yet for this issue → retry (below) with the judge findings; a retry already happened → comment once `factory: caveats again at <sha> after a retry, needs your review` followed by the judge findings (below), Kim's. |
| `👓 In Review` | PR red / conflicted / closed-unmerged for over 1h | retry (below) |
| `👀 Needs Input`, `⛔️ Blocked`, anything else | — | nothing. Kim's. |

Order `To do` candidates by priority, then oldest `createdAt`. Within `👓 In Review`, the merged check comes first on purpose: a PR Kim merged by hand after a failed verdict is done, not a retry.

### Claim then start

1. `run=$(openssl rand -hex 4)`; `"$L" state <ID> "👩🏻‍💻 In Progress"`, `"$L" assign <ID> me`, `"$L" comment <ID> "factory: run $run <ISO timestamp>"`. The claim is written **before** anything starts.
2. Prepare the worktree. A failure here stops this issue: no worker starts, the comment names the step that failed, and the issue goes through retry (below) with that reason, so a second failure lands in `⛔️ Blocked` for Kim instead of looping.
```bash
repo=<local path>; id=<ISSUE-ID>; run=<the 8-hex id from the claim>; wt="$(dirname "$repo")/$(basename "$repo")-factory-$id"
fail() { "$L" comment "$id" "factory: worktree preparation failed: $1; worker not started"; echo "prep failed $id: $1"; exit 1; }
git -C "$repo" fetch -q origin || fail "git fetch origin"
if [[ -d $wt ]]; then                                                                        # retry: reuse the worktree
  git -C "$wt" pull -q --rebase origin "factory/$id" || { git -C "$wt" rebase --abort 2>/dev/null; fail "git pull --rebase in $wt"; }
elif git -C "$repo" ls-remote -q --exit-code origin "factory/$id" >/dev/null; then           # retry, worktree gone: track the branch
  git -C "$repo" worktree add "$wt" "factory/$id" || fail "git worktree add $wt from factory/$id"
else                                                                                         # first run: the tree is origin/HEAD
  git -C "$repo" worktree add -b "factory/$id" "$wt" origin/HEAD || fail "git worktree add -b factory/$id"
  lock=$wt/npm-shrinkwrap.json; [[ -f $lock ]] || lock=$wt/package-lock.json
  if [[ ! -f $lock ]]; then echo "warm-up skipped: no npm lockfile"
  elif ! jq -e '(.lockfileVersion // 0) >= 2 and ([.packages | to_entries[] | select(.key | contains("node_modules/")) | .value | select(.link != true)
                 | select(if has("resolved") then (.resolved | startswith("https://registry.npmjs.org/") | not)
                          else ((.version // "") | test("^[0-9]+\\.[0-9]+\\.[0-9]+") | not) end)] == [])' "$lock" >/dev/null; then
    echo "warm-up skipped: ${lock##*/} is v1 or has a dependency that is not a registry.npmjs.org package; worker runs cold"
  else                                                                                       # warm node_modules here, never in the worker
    (cd "$wt" && env -u GH_TOKEN -u LINEAR_TOKEN perl -e '
        setpgrp; alarm 600;                                # own process group; 10 minutes, then the whole group dies
        $SIG{ALRM} = sub { $SIG{TERM} = "IGNORE"; kill TERM => -$$; sleep 5; kill KILL => -$$ };
        system @ARGV; exit($? ? 1 : 0)' -- npm ci --ignore-scripts --no-audit --no-fund \
          --registry=https://registry.npmjs.org/ --replace-registry-host=never --userconfig=/dev/null) \
      || { git -C "$repo" worktree remove --force "$wt"; git -C "$repo" branch -D "factory/$id"; fail "npm ci --ignore-scripts in $wt (10-minute limit); worktree removed so the retry starts fresh"; }
  fi
fi
# The install runs only on the first run, when the worktree is exactly origin/HEAD: the lockfile and any .npmrc are base's,
# which review already trusts. A retry worktree carries the worker's branch, so dispatch never installs from it; a worker
# that broke its node_modules fails its own checks and lands in Needs Input. worker-settings.json denies the registry to
# the worker, so this is the only install. Always --ignore-scripts, and the two brokered tokens are dropped from the
# install's environment so an .npmrc `${GH_TOKEN}` has nothing to expand; scripts/pr.sh shows a script could still get
# tokens back from keycard, which is why scripts stay off. --ignore-scripts does not cover git dependencies (a git
# dependency's own .npmrc can point npm at a different git binary), so the lockfile guard skips the install unless the
# lockfile is v2+ and every installed entry either resolves to a registry.npmjs.org tarball or, when npm left `resolved`
# out (it does, for entries it had cached), has a plain semver `version`, which npm can only fetch as name@version from
# the registry (v1 can hide a git dependency in `version`); such a project runs cold and lands in Needs Input. The CLI
# --registry and --replace-registry-host=never outrank any .npmrc or npm_config_* in this shell, and --userconfig=/dev/null
# drops the operator's ~/.npmrc, so the only config left is the command line and base's own .npmrc. Packages install
# without their lifecycle scripts, so a build that needs them fails and routes to Needs Input; install_scripts: true
# applies only in the CI judge. The 10-minute limit keeps claim-to-worker-start well inside the 2h stale threshold
# (the worker's own budget is 90 minutes), and the group kill takes npm's children (git, ssh) with it.
# ponytail: npm only; add pnpm/yarn when a registered project uses one.
```
3. Start the worker, detached, logging to `~/.factory/logs/<ID>-<run>.log` (one file per run; a retry does not overwrite the previous run's log):
```bash
( cd "$wt" && perl -e '
    setpgrp; alarm 5400;                                   # own process group; 90 minutes wall clock
    $SIG{ALRM} = sub { warn "factory: 90-minute timeout, killing process group $$\n";
                       $SIG{TERM} = "IGNORE"; kill TERM => -$$; sleep 10; kill KILL => -$$ };
    system @ARGV; exit($? >> 8)' -- \
    keycard agent exec --config "${CLAUDE_PLUGIN_ROOT}/keycard.toml" --zone "$KEYCARD_ZONE" -- \
      claude -p "/factory:factory-worker $id" --plugin-dir "${CLAUDE_PLUGIN_ROOT}" \
        --settings "${CLAUDE_PLUGIN_ROOT}/worker-settings.json" --permission-mode auto --max-turns 80 \
        --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  ) > ~/.factory/logs/$id-$run.log 2>&1 &
# budget: 80 turns and 90 minutes wall clock per run; worker-settings.json is the egress allowlist for the worker's shell commands.
# The timeout kills the whole process group (keycard, claude, and every shell command the worker spawned), not just the
# top process: `alarm; exec` would hand SIGALRM to keycard alone and leave its children running.
# No MCP servers in the worker (same flags as dispatch.sh): the claude.ai connectors that come with the Claude login, Linear
# included, are not available, so scripts/linear.sh with the brokered token is the only Linear path.
```
4. Do not wait for it. Report `started <ID> in <wt>`.

Verify on the mini, once, after a worker has started (macOS `ps` and `pgrep -g` take a process group id; the perl wrapper is the group leader, so its pid is the pgid):
```bash
pgid=$(ps -o pgid= -p "$(pgrep -f "factory-worker $id" | head -1)" | tr -d ' ')
ps -o pid,pgid,ppid,comm -p "$(pgrep -g "$pgid" | paste -sd, -)"   # perl, keycard, claude and its children, one PGID
kill -ALRM "$pgid"; sleep 15; pgrep -lg "$pgid" || echo "group $pgid is gone"   # must print the echo
tail -1 ~/.factory/logs/$id-$run.log                                             # "factory: 90-minute timeout, killing process group"
```

### Retry

Count existing `factory: retry N` comments. Next N = count + 1. If N >= 2: state `⛔️ Blocked`, comment `factory: retry budget exhausted (<reason>)`. Else: state `🍎 To do`, comment `factory: retry N (<reason>)` followed by the judge findings (below) when the reason is a verdict. The next sweep re-dispatches it; the worker reads the retry comment and acts on the findings.

### Judge findings (what the worker, or Kim, needs to act on a verdict)

The status descriptions are 140 characters; the findings live in the judge run's transcript artifacts, one per reviewer job. For the head SHA:
```bash
run=$(gh run list -R <r> --workflow factory-judge.yml --json databaseId,headSha --jq '[.[]|select(.headSha=="<sha>")][0].databaseId')
for m in claude codex; do gh run download "$run" -R <r> -n "judge-$m-<sha>" -D "$d/$m"; done
for m in claude codex; do echo "## $m"; grep -E '^(- |\* |[0-9]+\. |VERDICT)' "$d/$m/$m.txt" | tail -15; done
```
Append that output to the comment under `Judge findings at <sha>:`. On a retry comment, add: "Keep the existing PR and push to its branch. Out of scope is unchanged." (Pipe the whole comment to `"$L" comment <ID> -`.) A worker must never be sent back without the findings; an empty retry just repeats the same mistake. Kim must never be asked to review a CAVEATS without them either: the status description on the PR is 140 characters and the rest lives only in the Actions artifact.

## Report

One line per action taken, then `sweep done`. If nothing was actionable, `sweep done: nothing to do`. Then `rmdir ~/.factory/dispatch.lock`; the lock is released on every path out of the sweep, and this is the last one.
