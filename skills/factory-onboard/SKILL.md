---
name: factory-onboard
description: Onboard an existing repo (and its existing Linear project, if any) into the software factory. Read-only preflight, then one setup PR (policy, CLAUDE snippet, merge workflow, gate script), then a registry row. Run once per repo as `/factory:factory-onboard <repo path> [--linear-project <project id>]`.
---

# Factory onboard

Arguments: local repo path; Linear project id (e.g. `P-KIM-206`, or the project's UUID). Run under `keycard agent exec --config "${CLAUDE_PLUGIN_ROOT}/keycard.toml" --zone <zone> -- claude ...` or let `scripts/linear.sh` re-exec itself under it; either way the Linear check below uses the brokered `LINEAR_TOKEN`, never a personal login.

## 1. Preflight (read-only, print a short report)

From the repo: default branch (`git symbolic-ref refs/remotes/origin/HEAD`), `owner/repo` from the remote, package manager (lockfile present), the test and build commands from the manifest, CI workflow files and their check names (`gh api repos/<r>/commits/<default>/check-runs --jq '.check_runs[].name' | sort -u`), whether `CLAUDE.md`, `.factory/`, `.github/workflows/factory-merge.yml`, branch protection (`gh api repos/<r>/branches/<default>/protection`, 404 = none) exist. Run the test command once; record pass/fail and any pre-existing failures as the baseline in the report.

If there is no test command or no CI: say so; the policy gets `auto_merge: false` and the first factory issue should be a smoke test.

## 2. Setup PR (the only writes to the repo)

On a branch `factory/onboard` from the default branch:
- `.factory/policy.json` from `${CLAUDE_PLUGIN_ROOT}/templates/policy.json`, edited from the preflight: `allow` = the repo's source and test dirs, `checks` = its real test/build commands, `launch` = its dev command, `auto_merge` false unless tests + CI exist (and even then leave false; Phase 2 flips it).
- `.factory/risk-gate.sh` = copy of `${CLAUDE_PLUGIN_ROOT}/scripts/risk-gate.sh` (the merge workflow reads it from the base commit).
- `.github/workflows/factory-merge.yml` and `.github/workflows/factory-judge.yml` from the templates; `.factory/refute-prompt.md` from `templates/refute-prompt.md` (the judge reads it from the base commit).
- Append `${CLAUDE_PLUGIN_ROOT}/templates/CLAUDE-factory.md` to `CLAUDE.md` (create if absent). Never replace existing content.
- Run `/fewer-permission-prompts` if `.claude/settings.json` has no allowlist yet.

Create the GitHub label the workflows key on (`gh pr create --label` silently drops a label that does not exist):
```bash
gh label create factory -R <owner/repo> --color F2C94C --description "Opened by the software factory worker"
```
Open the PR with `gh pr create --title "factory: onboard" --body` listing the preflight report. Kim merges it.

Then tell Kim the things only she can do, with exact commands:
- (a) branch protection on the default branch requiring the CI check names from the preflight, "require branches to be up to date", and restricting who can push;
- (b) a GitHub App for merging with `contents: write` + `pull_requests: write`, installed on the repo, with `FACTORY_APP_ID` as a repo variable;
- (c) `gh variable set FACTORY_PAUSED -b false -R <r>`;
- (d) the `factory` environment, which is the **only** place any factory secret may live. A same-repo PR can add a workflow that prints repository secrets; environment secrets are released only to runs whose `github.ref` matches the deployment branch policy, and for the judge and merge workflows (`pull_request_target`) that ref is the PR's base branch:
```bash
r=<owner/repo>; d=<default branch>
gh api -X PUT "repos/$r/environments/factory" --input - <<'J'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
J
gh api -X POST "repos/$r/environments/factory/deployment-branch-policies" -f name="$d" -f type=branch
gh secret set FACTORY_APP_PRIVATE_KEY --env factory -R "$r" < app.pem
gh secret set ANTHROPIC_API_KEY --env factory -R "$r"
gh secret set OPENAI_API_KEY --env factory -R "$r"
gh secret set FACTORY_JUDGE_KEY --env factory -R "$r" --body "$(openssl rand -hex 32)"   # signs judge verdicts; never read by anything else
for s in FACTORY_APP_PRIVATE_KEY ANTHROPIC_API_KEY OPENAI_API_KEY; do gh secret delete "$s" -R "$r" 2>/dev/null; done   # no repository-level copies
gh secret list -R "$r"   # must show no factory secret
gh api -X PUT "repos/$r/actions/permissions/workflow" -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
```
  On a repo that already had these as repository secrets, rotate all three after the move: they were readable by every worker PR until now.

## 3. Registry

Linear project: `"${CLAUDE_PLUGIN_ROOT}/scripts/linear.sh" issues <project id> | jq '.project'` must print the project (name, identifier, url); a failure means the id is wrong or the brokered token cannot see the project, and onboarding stops there. No project id given → ask Kim to create one in Linear (team KIM) and pass its identifier; the factory never creates or lists projects. Then:
```bash
mkdir -p ~/.factory && touch ~/.factory/registry.json
jq --arg p "<project id>" --arg r "<abs repo path>" '. + {($p): $r}' ~/.factory/registry.json > ~/.factory/registry.tmp && mv ~/.factory/registry.tmp ~/.factory/registry.json
```
(Initialize the file to `{}` first if empty.) Many projects may map to one repo. One project to many repos is not supported yet.

## 4. Report

Preflight summary, PR URL, the Kim-only steps, and the registry row.
