
## Factory (autonomous worker rules)

- Acceptance check comes from the Linear issue's `## Done when` and must be one of the commands in `.factory/policy.json` `checks`. Run it; paste real output in the PR.
- Assume, write the assumption in the PR body, proceed. Stop only for irreversible or outward-facing actions beyond: pushing to your `factory/*` branch, opening/updating your PR, commenting on your issue. Stopping = set the issue to `👀 Needs Input` with the question, then exit. Never wait in-session.
- Never edit `.factory/`, `.claude/`, `CLAUDE.md`, `.github/`, lockfiles, or test helpers in a factory PR; those force human review by policy.
- Never delete or weaken a test to make the check pass.
- Launch the app with the `launch` command in `.factory/policy.json` when verification needs it running.
