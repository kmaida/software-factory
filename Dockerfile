# syntax=docker/dockerfile:1
# Factory sandbox image. See factory.md.
# Build:  docker build -t factory-sandbox .
# Run (orchestrator does this; shown for reference):
#   printf '%s\n%s\n' "$GITHUB_TOKEN" "$ANTHROPIC_TOKEN" | \
#   docker run -i --rm --read-only --tmpfs /tmp --tmpfs /run/secrets:size=64k \
#     --memory 4g --cpus 2 --pids-limit 512 --cap-drop ALL --security-opt no-new-privileges \
#     -v "$REPO_DIR":/work \
#     -e TASK_ID -e BASE_BRANCH factory-sandbox@sha256:<digest> "<instructions>"

FROM node:22-bookworm-slim@sha256:4b150b48b4116e2a22f2c39cc27025fbf4f153e2078fd3b14d159fdb5c7279da

RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates curl \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g @anthropic-ai/claude-code \
 && userdel -r node && useradd -m -u 1000 agent

# Secrets arrive on stdin (one per line) and are written as 0400 files on the /run/secrets tmpfs,
# never as args, host files, or baked env. Git reads the token through a helper.
COPY --chmod=0755 <<'EOF' /usr/local/bin/entrypoint
#!/bin/sh
set -eu
# Root FS is read-only; /tmp is tmpfs. Point HOME there so git, gh and claude can write their config.
export HOME=/tmp
umask 077
IFS= read -r GH_TOKEN; IFS= read -r ANTHROPIC_AUTH_TOKEN
printf '%s\n' "$GH_TOKEN" > /run/secrets/github_token
printf '%s\n' "$ANTHROPIC_AUTH_TOKEN" > /run/secrets/anthropic_token
chmod 0400 /run/secrets/github_token /run/secrets/anthropic_token
# anthropic_token is a bearer token from Workload Identity Federation, so ANTHROPIC_AUTH_TOKEN, not ANTHROPIC_API_KEY.
export GH_TOKEN ANTHROPIC_AUTH_TOKEN
git config --global credential.helper '!f() { echo "username=x-access-token"; echo "password=$GH_TOKEN"; }; f'
git config --global user.name "factory[bot]"
git config --global user.email "factory@users.noreply.github.com"
git config --global --add safe.directory /work
cd /work
git checkout -b "factory/${TASK_ID}" "origin/${BASE_BRANCH}"
# Stream tool calls as JSON; the orchestrator on the host writes them to runs/<id>/log.jsonl.
# Capability profile: these tools run without prompts (there is nobody to answer one); everything else is denied.
claude -p "$*" --output-format stream-json --verbose \
  --allowedTools "Bash,Read,Edit,MultiEdit,Write,Glob,Grep,NotebookEdit,TodoWrite,Agent" < /dev/null
# Safety net: commit anything the agent left uncommitted so the work reaches the PR.
git add -A && git commit -qm "factory: ${TASK_ID} (uncommitted changes)" || true
# No commits beyond the base: the agent declined or produced nothing. Push nothing; exit 3 so the manifest says so.
if [ "$(git rev-list --count "origin/${BASE_BRANCH}..HEAD")" -eq 0 ]; then echo "factory: no changes on factory/${TASK_ID}; not pushing" >&2; exit 3; fi
git push -u origin "factory/${TASK_ID}"
gh pr create --fill --base "${BASE_BRANCH}" --head "factory/${TASK_ID}"
EOF

USER agent
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/entrypoint"]
