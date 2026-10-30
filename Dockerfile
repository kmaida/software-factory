# syntax=docker/dockerfile:1
# Factory sandbox image. See factory.md.
# Build:  docker build -t factory-sandbox .
# Run (orchestrator does this; shown for reference). One container per step, MODE selects the step, exactly one
# secret arrives on stdin:
#   work   ANTHROPIC token   -v "$REPO_DIR":/work                      "<instructions>"   Claude Code edits and commits on factory/<task_id>
#   judge  OPENAI key        -v "$REPO_DIR":/src:ro -v "$JUDGE_DIR":/work -v "$OUT_DIR":/out -e HEAD_SHA "<prompt>"
#                                                                                    Codex clones /src at HEAD_SHA, reviews, writes /out/verdict.md
#   push   GITHUB token      -v "$REPO_DIR":/src:ro -e REPO_URL -e HEAD_SHA              bare-clones /src, pushes HEAD_SHA to REPO_URL as factory/<task_id>
#   printf '%s\n' "$SECRET" | docker run -i --rm --read-only --tmpfs /tmp --tmpfs /run/secrets:size=64k \
#     --memory 4g --cpus 2 --pids-limit 512 --cap-drop ALL --security-opt no-new-privileges \
#     -e MODE=work -e TASK_ID -e BASE_BRANCH -v "$REPO_DIR":/work factory-sandbox@sha256:<digest> "<instructions>"

FROM node:22-bookworm-slim@sha256:4b150b48b4116e2a22f2c39cc27025fbf4f153e2078fd3b14d159fdb5c7279da

# No gh: the push token can only push (contents:write); the host opens the pull request with a separate token.
# Codex is the judge; pinned, bump deliberately.
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g @anthropic-ai/claude-code @openai/codex@0.164.0 \
 && userdel -r node && useradd -m -u 1000 agent

# The one secret arrives on stdin and is written as a 0400 file on the /run/secrets tmpfs,
# never as an arg, host file, or baked env.
COPY --chmod=0755 <<'EOF' /usr/local/bin/entrypoint
#!/bin/sh
set -eu
# Root FS is read-only; /tmp is tmpfs. Point HOME there so git, claude and codex can write their config.
export HOME=/tmp
umask 077
IFS= read -r SECRET
printf '%s\n' "$SECRET" > /run/secrets/token; chmod 0400 /run/secrets/token
git config --global user.name "factory[bot]"
git config --global user.email "factory@users.noreply.github.com"
git config --global --add safe.directory /work; git config --global --add safe.directory /src
case "${MODE:-}" in
work)
  # A bearer token from Workload Identity Federation, so ANTHROPIC_AUTH_TOKEN, not ANTHROPIC_API_KEY. No GitHub token here: the worker cannot push.
  export ANTHROPIC_AUTH_TOKEN="$SECRET"; SECRET=
  cd /work
  # Round 1 creates the branch from the base; a revision round continues it.
  git checkout -q "factory/${TASK_ID}" 2>/dev/null || git checkout -qb "factory/${TASK_ID}" "origin/${BASE_BRANCH}"
  # Stream tool calls as JSON; the orchestrator on the host writes them to runs/<id>/log.jsonl.
  # Capability profile: these tools run without prompts (there is nobody to answer one); everything else is denied.
  claude -p "$*" --output-format stream-json --verbose \
    --allowedTools "Bash,Read,Edit,MultiEdit,Write,Glob,Grep,NotebookEdit,TodoWrite,Agent" < /dev/null
  # Safety net: commit anything the agent left uncommitted so the work reaches the judge and the PR.
  git add -A && git commit -qm "factory: ${TASK_ID} (uncommitted changes)" || true
  # No commits beyond the base: the agent declined or produced nothing. Exit 3 so the manifest says so.
  if [ "$(git rev-list --count "origin/${BASE_BRANCH}..HEAD")" -eq 0 ]; then echo "factory: no changes on factory/${TASK_ID}" >&2; exit 3; fi
  ;;
judge)
  # Codex 0.164 does not read OPENAI_API_KEY; log in to a throwaway CODEX_HOME on the tmpfs.
  export CODEX_HOME=/tmp/codex; mkdir -p "$CODEX_HOME"
  printf '%s' "$SECRET" | codex login --with-api-key; SECRET=; rm -f /run/secrets/token
  # Fresh clone of the worker's checkout: no hooks, no index state, and nothing the judge runs can touch /src.
  # Checked out detached at the exact commit the host captured, so the judge reviews what will be pushed, not whatever
  # branch the worker left checked out.
  git clone -q --no-local /src /work
  cd /work
  git checkout -q --detach "$HEAD_SHA"
  [ "$(git rev-parse HEAD)" = "$HEAD_SHA" ] || { echo "factory: judge checkout is not $HEAD_SHA" >&2; exit 2; }
  # Strip agent config the worker could have planted, and turn off project-doc discovery; the judge takes instructions from the prompt only.
  rm -rf AGENTS.md AGENTS.override.md .codex .claude CLAUDE.md .cursor .mcp.json
  # Codex's own sandbox cannot start inside this capability-dropped container; the container is the sandbox.
  # The verdict goes to /out, a mount the repository content cannot reach (a committed symlink at the output path would otherwise be followed on the host).
  codex exec --ephemeral --ignore-user-config --ignore-rules --skip-git-repo-check -c project_doc_max_bytes=0 \
    --dangerously-bypass-approvals-and-sandbox -C /work -o /out/verdict.md "$*" < /dev/null
  ;;
push)
  export GH_TOKEN="$SECRET"; SECRET=
  # The helper answers for github.com only, so a push to any other host gets no credential.
  git config --global credential.helper '!f() { h=; while IFS= read -r l; do case "$l" in host=*) h=${l#host=};; esac; done; [ "$h" = github.com ] || exit 0; echo "username=x-access-token"; echo "password=$GH_TOKEN"; }; f'
  # Never run git with the token inside the worker's checkout: a hook or config it planted would run here. Clone the branch
  # from the read-only mount into a fresh repo (no hooks, no config), and push to the URL the orchestrator gave, not to origin.
  # Pushes the exact commit the judge reviewed, not whatever the branch points at now.
  git clone -q --no-local --bare /src /tmp/push.git
  git -C /tmp/push.git -c core.hooksPath=/dev/null push "$REPO_URL" "$HEAD_SHA:refs/heads/factory/${TASK_ID}"
  ;;
*) echo "factory: MODE must be work, judge or push" >&2; exit 2 ;;
esac
EOF

USER agent
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/entrypoint"]
