# syntax=docker/dockerfile:1
# Factory sandbox image. See factory.md. Rebuilt for loop 0 (2026-11-02): the review and verify arms; the worker's spend cap removed.
# Build:  docker build -t factory-sandbox .
# Run (orchestrator does this; shown for reference). One container per step, MODE selects the step, exactly one
# secret arrives on stdin:
#   work   ANTHROPIC token   -v "$REPO_DIR":/work                      "<instructions>"   Claude Code edits and commits on factory/<task_id>
#   judge  OPENAI key        -v "$REPO_DIR":/src:ro -v "$JUDGE_DIR":/work -v "$OUT_DIR":/out -e HEAD_SHA "<prompt>"
#                                                                                    Codex clones /src at HEAD_SHA, reviews, writes /out/verdict.md
#   push   GITHUB token      -v "$REPO_DIR":/src:ro -e REPO_URL -e HEAD_SHA              bare-clones /src, pushes HEAD_SHA to REPO_URL as factory/<task_id>
#   review ANTHROPIC token   -v "$REPO_DIR":/src:ro -v "$RW_DIR":/work -v "$OUT_DIR":/out -e HEAD_SHA -e REVIEW_MODEL -e FINDINGS_SCHEMA "<prompt>"
#                                                                                    Claude Code reviews a fresh clone at HEAD_SHA, writes /out/review.json
#   verify (empty line)      -v "$REPO_DIR":/src:ro -v "$IN_DIR":/in:ro -v "$V_DIR":/work -v "$OUT_DIR":/out -v verify.js:/verify.js:ro -e HEAD_SHA -e BASE_SHA
#                                                                                    no model, no credential: runs each BLOCK's repro at head and base, writes /out/verify.json
#   printf '%s\n' "$SECRET" | docker run -i --rm --read-only --tmpfs /tmp --tmpfs /run/secrets:size=64k \
#     --memory 4g --cpus 2 --pids-limit 512 --cap-drop ALL --security-opt no-new-privileges \
#     -e MODE=work -e TASK_ID -e BASE_BRANCH -e GIT_AUTHOR_NAME -e GIT_AUTHOR_EMAIL -e GIT_COMMITTER_NAME -e GIT_COMMITTER_EMAIL \
#     -v "$REPO_DIR":/work factory-sandbox@sha256:<digest> "<instructions>"
# The four GIT_* variables carry the App's bot identity (<slug>[bot], <id>+<slug>[bot]@users.noreply.github.com), resolved by the
# orchestrator per run; every commit here, the agent's and the safety net's, is attributed to the App. Nothing is hardcoded below:
# without them git refuses to commit, which is the right failure.

# Node 24 to match the target repos' CI (plan-my-today pins node-version: 24); the judge flagged the mismatch on the first run.
FROM node:24-bookworm-slim@sha256:c86ecead9e55a5210ac1727de38a4ca840bf03dcaf34dc9749addbf383b1920c

# No gh: the push token can only push (contents:write); the host opens the pull request with a separate token.
# Codex is the judge; pinned, bump deliberately.
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g @anthropic-ai/claude-code@2.1.316 @openai/codex@0.164.0 \
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
  # The model comes from the orchestrator (a full model id is the pin). No spend cap: thrash is bounded by rounds, not dollars (factory.md).
  claude -p "$*" --output-format stream-json --verbose --model "${FACTORY_MODEL:?}" \
    --allowedTools "Bash,Read,Edit,MultiEdit,Write,Glob,Grep,NotebookEdit,TodoWrite,Agent" < /dev/null
  # Safety net: commit anything the agent left uncommitted so the work reaches the judge and the PR. A commit that fails for a
  # real reason (index lock, hook) is a failed round (exit 2), never "no changes".
  git add -A
  git diff --cached --quiet || git commit -qm "factory: ${TASK_ID} (uncommitted changes)" || { echo "factory: committing the agent's uncommitted changes failed" >&2; exit 2; }
  # The host judges and pushes refs/heads/factory/<task_id>; work left on another branch or a detached HEAD would be judged stale.
  [ "$(git symbolic-ref -q HEAD)" = "refs/heads/factory/${TASK_ID}" ] || { echo "factory: worker left HEAD on $(git symbolic-ref -q HEAD || git rev-parse HEAD), not factory/${TASK_ID}" >&2; exit 2; }
  # No commits beyond the base: the agent declined or produced nothing. Exit 3 so the manifest says so. A count that cannot be
  # taken (the base ref is gone) is an error, not zero.
  n=$(git rev-list --count "origin/${BASE_BRANCH}..HEAD") || { echo "factory: cannot count commits against origin/${BASE_BRANCH}" >&2; exit 2; }
  if [ "$n" -eq 0 ]; then echo "factory: no changes on factory/${TASK_ID}" >&2; exit 3; fi
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
  codex exec --ephemeral --ignore-user-config --ignore-rules --skip-git-repo-check -c project_doc_max_bytes=0 -m "${JUDGE_MODEL:?}" \
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
review)
  # The verification gate's reviewer: a fresh Claude Code session with the break-it lens, the worker's kind of token, on a fresh clone at the
  # judged head. --safe-mode disables CLAUDE.md, hooks, MCP, plugins and commands and keeps auth (--bare would drop the ANTHROPIC_AUTH_TOKEN
  # path); the flags are the control and the strip below is the backstop, at every depth, since the worker could plant a config file anywhere.
  export ANTHROPIC_AUTH_TOKEN="$SECRET"; SECRET=; rm -f /run/secrets/token
  git clone -q --no-local /src /work
  cd /work
  git checkout -q --detach "$HEAD_SHA"
  [ "$(git rev-parse HEAD)" = "$HEAD_SHA" ] || { echo "factory: review checkout is not $HEAD_SHA" >&2; exit 2; }
  find . -path ./.git -prune -o \( -name CLAUDE.md -o -name CLAUDE.local.md -o -name AGENTS.md -o -name AGENTS.override.md -o -name .claude -o -name .codex -o -name .cursor -o -name .mcp.json \) -prune -exec rm -rf {} +
  rc=0; claude -p "$*" --output-format stream-json --verbose --model "${REVIEW_MODEL:?}" --safe-mode --setting-sources "" --strict-mcp-config \
    --disable-slash-commands --no-session-persistence --allowedTools "Bash,Read,Glob,Grep,Edit" --json-schema "${FINDINGS_SCHEMA:?}" < /dev/null > /tmp/review.jsonl || rc=$?
  cat /tmp/review.jsonl   # the stream reaches the run log like the worker's
  [ "$rc" -eq 0 ] || { echo "factory: claude exited $rc" >&2; exit "$rc"; }
  # The findings: the last result event's structured output (the image has no jq), written only when the CLI reported no error; anything
  # else leaves no file, which the host treats as a gate error, never as a pass. The host validates the shape.
  node -e '
    const fs = require("fs"); let r = null;
    for (const l of fs.readFileSync("/tmp/review.jsonl", "utf8").split("\n")) { try { const o = JSON.parse(l); if (o.type === "result") r = o; } catch {} }
    if (!r) { console.error("factory: no result event"); process.exit(3); }
    if (r.is_error) { console.error("factory: result is_error: " + String(r.result).slice(0, 500)); process.exit(3); }
    let f = r.structured_output; if (f === undefined) { try { f = JSON.parse(r.result); } catch { console.error("factory: result is not JSON"); process.exit(3); } }
    fs.writeFileSync("/out/review.json", JSON.stringify(f));'
  ;;
verify)
  # The verifier: no model, no credential (the line read above is empty). verify.js is mounted from the factory checkout, like proxy.js.
  SECRET=; rm -f /run/secrets/token
  exec node /verify.js
  ;;
*) echo "factory: MODE must be work, judge, push, review or verify" >&2; exit 2 ;;
esac
EOF

USER agent
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/entrypoint"]
