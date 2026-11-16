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
from opensandbox.models.sandboxes import NetworkPolicy, NetworkRule

GW = os.environ["GW_IP"]                 # agentgateway on the Docker bridge
UPSTREAM = os.environ.get("MOCK_IP")     # mock mode only: the stand-in for api.anthropic.com
MODEL = os.environ["FACTORY_MODEL"]
IMAGE = os.environ["IMAGE"]
RUN_KEY = os.environ["RUN_KEY"]          # the gateway accepts it for this run; it is nothing to Anthropic
CURL = "curl -s -m 8 -o /dev/null -w '%{http_code}' "

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
    },
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

    rc, out = sh(
        f"mkdir -p /tmp/work && cd /tmp/work && claude -p {shlex.quote('Reply with the single word ok.')} --output-format json "
        f'--model {MODEL} --allowedTools "Bash,Read,Edit,Write,Glob,Grep" < /dev/null'
    )
    try:
        result = json.loads(out.splitlines()[-1])
    except (ValueError, IndexError):
        result = {"is_error": True, "result": out}
    said = str(result.get("result", ""))
    # In mock mode the reply has to be the mock's own text: a turn answered from anywhere else is not a turn through the gateway.
    check("claude -p completed a turn through the gateway", rc == 0 and not result.get("is_error", True) and (not UPSTREAM or said == "SPIKE_OK"), said[-160:])
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
        sandbox.kill()
    finally:   # the server may be gone; its containers must not outlive the run
        subprocess.run(["docker", "rm", "-f", f"sandbox-{sandbox.id}", f"sandbox-egress-{sandbox.id}"], capture_output=True)
        sandbox.close()

sys.exit(1 if failed else 0)
