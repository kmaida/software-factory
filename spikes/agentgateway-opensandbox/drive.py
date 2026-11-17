"""The worker step's sandbox on OpenSandbox: default-deny egress with the gateway as the only way to a model,
a per-run gateway key where the Anthropic token used to be, then the checks and one `claude -p` turn. Run by spike.sh."""
import json
import os
import shlex
import subprocess
import sys
from datetime import timedelta

from opensandbox import SandboxSync
from opensandbox.config import ConnectionConfigSync
from opensandbox.models.sandboxes import Host, NetworkPolicy, NetworkRule, Volume

GW = os.environ["GW_IP"]                 # agentgateway on the Docker bridge
UPSTREAM = os.environ.get("MOCK_IP")     # mock mode only: the stand-in for api.anthropic.com
MODEL = os.environ["FACTORY_MODEL"]
IMAGE = os.environ["IMAGE"]
RUN_KEY = os.environ["RUN_KEY"]          # the gateway accepts it for this run; it is nothing to Anthropic
CURL = "curl -s -m 8 -o /dev/null -w '%{http_code}' "
WORK = os.environ["WORK_DIR"]            # the host's clone of the target repo, as `factory` prepares it: origin/main is the base
TASK = "spike-task"
BRANCH = f"factory/{TASK}"
BOT = "spike-worker[bot]"
PROMPT = "Create spike.txt containing exactly the line 'made by the worker', commit it with git, then reply with only SPIKE_OK."

sandbox = SandboxSync.create(
    IMAGE,
    timeout=timedelta(minutes=10),
    ready_timeout=timedelta(seconds=90),
    resource={"cpu": "2", "memory": "4Gi"},
    env={
        "HOME": "/tmp",
        "ANTHROPIC_BASE_URL": f"http://{GW}:4000",
        "ANTHROPIC_AUTH_TOKEN": RUN_KEY,
        "NPM_CONFIG_IGNORE_SCRIPTS": "true",
        "GIT_AUTHOR_NAME": BOT, "GIT_AUTHOR_EMAIL": "spike@example.invalid",
        "GIT_COMMITTER_NAME": BOT, "GIT_COMMITTER_EMAIL": "spike@example.invalid",
    },
    volumes=[Volume(name="work", host=Host(path=WORK), mount_path="/work")],   # factory's `-v "$work":/work`
    network_policy=NetworkPolicy(
        defaultAction="deny",
        egress=[
            NetworkRule(action="allow", target=GW, ports=[4000]),
            NetworkRule(action="allow", target="registry.npmjs.org"),
        ],
    ),
    connection_config=ConnectionConfigSync(domain=os.environ["OSB_DOMAIN"], api_key=os.environ["OSB_API_KEY"], protocol="http"),
)

failed = []


def sh(cmd):   # exit status and stdout of a command in the sandbox
    r = sandbox.commands.run(cmd)
    return r.exit_code, "".join(m.text for m in r.logs.stdout).strip()


def status(out):   # curl's -w output: an HTTP status, 000 when no connection was made, ERR when curl itself did not answer
    return out if len(out) == 3 and out.isdigit() else "ERR"


def code(args):
    return status(sh(CURL + args)[1])


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail[:160]}]" if detail else ""))
    if not ok:
        failed.append(name)


def refused(name, url):   # no HTTP answer in the sandbox, and an answer to the same request from a container with no policy
    control = status(subprocess.run(["docker", "run", "--rm", "--entrypoint", "sh", IMAGE, "-c", CURL + url], capture_output=True, text=True).stdout.strip())
    got = code(url)
    check(name, got == "000" and control not in ("000", "ERR"), f"sandbox {got}, control {control}")


try:
    print("sandbox", sandbox.id)
    check("runs as the image's unprivileged user", sh("id -u")[1] == "1000")
    key = f"-H 'authorization: Bearer {RUN_KEY}' "
    check("gateway answers the run key", code(key + f"http://{GW}:4000/v1/models") == "200")
    post = f"-X POST -H 'content-type: application/json' -d '{{\"model\":\"{MODEL}\",\"max_tokens\":1,\"messages\":[]}}' http://{GW}:4000/v1/messages"
    # In mock mode a 401 can only be the gateway's (the mock never sends one). In real mode Anthropic could be its author.
    nokey = code(post)
    check("gateway refuses a model call with no key", nokey == "401", nokey)
    check("gateway refuses a model call with a wrong key", code("-H 'authorization: Bearer wrong' " + post) == "401")
    check("npm registry reachable", code("https://registry.npmjs.org/") == "200")
    refused("api.anthropic.com refused (direct, by name)", "https://api.anthropic.com/")
    refused("example.com refused", "https://example.com/")
    refused("unlisted IP refused (1.1.1.1)", "http://1.1.1.1/")
    refused("gateway refused on a port the rule does not name (15021)", f"http://{GW}:15021/")
    if UPSTREAM:
        refused("upstream refused when called directly, past the gateway", f"http://{UPSTREAM}:9000/")

    # The work step. OpenSandbox never runs the image's entrypoint (README.md), so its MODE=work steps (Dockerfile) are run here as commands:
    # the branch from the base, the agent, the safety-net commit, and the check that HEAD is still the task branch.
    rc, out = sh(
        f"umask 077 && git config --global --add safe.directory /work && cd /work && "
        f"(git checkout -q {BRANCH} 2>/dev/null || git checkout -qb {BRANCH} origin/main) && "
        f"claude -p {shlex.quote(PROMPT)} --output-format json --model {MODEL} "
        '--allowedTools "Bash,Read,Edit,MultiEdit,Write,Glob,Grep,NotebookEdit,TodoWrite,Agent" < /dev/null'
    )
    try:
        result = json.loads(out.splitlines()[-1])
    except (ValueError, IndexError):
        result = {"is_error": True, "result": out}
    said = str(result.get("result", ""))
    # In mock mode the reply has to be the mock's own text: a turn answered from anywhere else is not a turn through the gateway.
    # That a tool call ran is not claimed here: the commit check below and spike.sh's last check (the mock's replies) establish it.
    turn = rc == 0 and not result.get("is_error", True) and (not UPSTREAM or said == "SPIKE_OK")
    check("claude -p finished its turn through the gateway", turn, f"{result.get('num_turns')} turns: {said[-120:]}")
    # The entrypoint runs under `set -e`: after a failed agent it stops, and the safety net never touches the checkout.
    net = sh(f"cd /work && git add -A && (git diff --cached --quiet || git commit -qm 'factory: {TASK} (uncommitted changes)') && git symbolic-ref -q HEAD") if turn else (None, "skipped: the agent failed")
    check("safety-net step completed and HEAD is the task branch", net == (0, f"refs/heads/{BRANCH}"), str(net))

    def host_git(*args):   # read the host's clone: what the orchestrator would judge and push
        # Never with git on the host. The agent wrote this repo, and git runs what a repo's config names (gpg.program under
        # log.showSignature, for one). So: a throwaway container, the clone read-only, no network, as factory's push step does.
        return subprocess.run(["docker", "run", "--rm", "--network", "none", "-e", "HOME=/tmp", "-v", f"{WORK}:/src:ro", "--entrypoint", "sh", IMAGE,
                               "-c", 'git config --global --add safe.directory /src && git -C /src "$@"', "sh", *args], capture_output=True, text=True).stdout.strip()
    commits, body = host_git("rev-list", "--count", f"origin/main..{BRANCH}"), host_git("show", f"{BRANCH}:spike.txt")
    author, subject = host_git("log", "-1", "--format=%an", BRANCH), host_git("log", "-1", "--format=%s", BRANCH)
    # The agent's own commit, never the safety net's. In mock mode it has to be exactly the one the tool call made.
    check("the worker's commit is on the task branch in the host's clone",
          commits.isdigit() and int(commits) >= 1 and body == "made by the worker" and author == BOT
          and not subject.startswith("factory:") and (not UPSTREAM or subject == "spike: the worker commits"),
          f"{commits} commit(s) by {author}, '{subject}', spike.txt: {body!r}")
    # True by construction (nothing else is passed in); this only catches the driver being changed to pass more.
    check("the sandbox's Anthropic variables hold the run key and nothing else", sh("env | grep -i -E 'anthropic.*(token|key)'")[1] == f"ANTHROPIC_AUTH_TOKEN={RUN_KEY}")

    # Not checks: how the containers OpenSandbox built compare with the factory's fixed `docker run` line.
    def flags(name):
        h = json.loads(subprocess.run(["docker", "inspect", name], capture_output=True, text=True, check=True).stdout)[0]["HostConfig"]
        ports = sorted({b["HostIp"] for v in (h.get("PortBindings") or {}).values() for b in v})
        return {"read_only": h["ReadonlyRootfs"], "cap_drop": h["CapDrop"], "cap_add": h["CapAdd"], "security_opt": h["SecurityOpt"],
                "memory": h["Memory"], "nano_cpus": h["NanoCpus"], "pids_limit": h["PidsLimit"], "published_on": ports}
    print("INFO  sandbox", flags(f"sandbox-{sandbox.id}"))
    print("INFO  egress sidecar", flags(f"sandbox-egress-{sandbox.id}"))
finally:
    try:
        sandbox.destroy()   # the SDK's create-use-discard call: kill, then close, and it closes even when the kill fails
    finally:   # spike.sh stops the server right after this, so nothing else would remove what a failed kill left behind
        subprocess.run(["docker", "rm", "-f", f"sandbox-{sandbox.id}", f"sandbox-egress-{sandbox.id}"], capture_output=True)

sys.exit(1 if failed else 0)
