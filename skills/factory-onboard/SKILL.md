---
name: factory-onboard
description: Onboard an existing repo (and its existing Linear project, if any) into the software factory. Read-only preflight, then one setup PR (policy, CLAUDE snippet, merge workflow, gate script), then a registry row. Run once per repo as `/factory:factory-onboard <repo path> [--linear-project <project id>]`.
---

# Factory onboard

Arguments: local repo path; optional Linear project id (e.g. `P-KIM-206`).

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

Open the PR with `gh pr create --title "factory: onboard" --body` listing the preflight report. Kim merges it.

Then tell Kim the three things only she can do, with exact commands: (a) branch protection on the default branch requiring the CI check names from the preflight, "require branches to be up to date", and restricting who can push; (b) a GitHub App for merging with `contents: write` + `pull_requests: write`, installed on the repo, with `FACTORY_APP_ID` as a repo variable and `FACTORY_APP_PRIVATE_KEY` as a repo secret; (c) `gh variable set FACTORY_PAUSED -b false -R <r>`; (d) repo secrets `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` for the judge job.

## 3. Registry

Linear project: given id → verify with `get_project`; none given → `list_projects` for team KIM and ask which, or `save_project` named after the repo. Then:
```bash
mkdir -p ~/.factory && touch ~/.factory/registry.json
jq --arg p "<project id>" --arg r "<abs repo path>" '. + {($p): $r}' ~/.factory/registry.json > ~/.factory/registry.tmp && mv ~/.factory/registry.tmp ~/.factory/registry.json
```
(Initialize the file to `{}` first if empty.) Many projects may map to one repo. One project to many repos is not supported yet.

## 4. Report

Preflight summary, PR URL, the three Kim-only steps, and the registry row.
