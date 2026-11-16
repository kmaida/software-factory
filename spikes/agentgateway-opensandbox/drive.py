"""The worker step's sandbox on OpenSandbox: default-deny egress with the gateway as the only way to a model,
a placeholder where the Anthropic token used to be, then the checks and one `claude -p` turn. Run by spike.sh."""
import json
import os
import subprocess
import sys
from datetime import timedelta

from opensandbox import SandboxSync
from opensandbox.config import ConnectionConfigSync
from opensandbox.models.sandboxes import NetworkPolicy, NetworkRule

GW = os.environ["GW_IP"]                 # agentgateway on the Docker bridge
UPSTREAM = os.environ.get("MOCK_IP")     # mock mode only: the stand-in for api.anthropic.com
MODEL = os.environ["FACTORY_MODEL"]
PLACEHOLDER = "placeholder-not-a-credential"
PROMPT = os.environ.get("PROMPT", "Reply with the single word ok.")

sandbox = SandboxSync.create(
    os.environ["IMAGE"],
    timeout=timedelta(minutes=10),
    ready_timeout=timedelta(seconds=90),
    resource={"cpu": "2", "memory": "4Gi"},
    env={
        "HOME": "/tmp",
        "ANTHROPIC_BASE_URL": f"http://{GW}:4000",
        "ANTHROPIC_AUTH_TOKEN": PLACEHOLDER,   # Claude Code refuses to start without one; the gateway replaces it
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


def sh(cmd):
    r = sandbox.commands.run(cmd)
    out = "".join(m.text for m in r.logs.stdout) + "".join(m.text for m in r.logs.stderr)
    return r.exit_code, out.strip()


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail[:160]}]" if detail else ""))
    if not ok:
        failed.append(name)


def code(url):   # the HTTP status curl got, or 000 when the connection never happened
    return sh(f"curl -s -m 8 -o /dev/null -w '%{{http_code}}' {url}")[1][-3:]


try:
    print("sandbox", sandbox.id)
    check("runs as the image's unprivileged user", sh("id -u")[1] == "1000", sh("id")[1])
    check("gateway reachable", code(f"http://{GW}:4000/v1/models") != "000")
    check("npm registry reachable", code("https://registry.npmjs.org/") == "200")
    check("api.anthropic.com refused (direct, by name)", code("https://api.anthropic.com/") == "000")
    check("example.com refused", code("https://example.com/") == "000")
    check("unlisted IP refused (1.1.1.1)", code("http://1.1.1.1/") == "000")
    check("gateway's other ports refused (15000 admin)", code(f"http://{GW}:15000/") == "000")
    if UPSTREAM:
        check("upstream refused when called directly, past the gateway", code(f"http://{UPSTREAM}:9000/") == "000")

    sh("mkdir -p /tmp/work && cd /tmp/work && git init -q . && git commit -q --allow-empty -m base")
    rc, out = sh(
        f"cd /tmp/work && claude -p {json.dumps(PROMPT)} --output-format json --model {MODEL} "
        '--allowedTools "Bash,Read,Edit,Write,Glob,Grep" < /dev/null'
    )
    result = {}
    try:
        result = json.loads(out.splitlines()[-1])
    except (ValueError, IndexError):
        pass
    check("claude -p completed a turn through the gateway", rc == 0 and not result.get("is_error", True), str(result.get("result", out))[-160:])
    check("the sandbox's only Anthropic credential is the placeholder", sh("env | grep -i -E 'anthropic.*(token|key)'")[1] == f"ANTHROPIC_AUTH_TOKEN={PLACEHOLDER}")

    # Not checks: how the container OpenSandbox built compares with the factory's fixed `docker run` line.
    def flags(name):
        h = json.loads(subprocess.run(["docker", "inspect", name], capture_output=True, text=True, check=True).stdout)[0]["HostConfig"]
        ports = sorted({b["HostIp"] for v in (h.get("PortBindings") or {}).values() for b in v})
        return {"read_only": h["ReadonlyRootfs"], "cap_drop": h["CapDrop"], "cap_add": h["CapAdd"], "security_opt": h["SecurityOpt"], "published_on": ports}
    print("INFO  sandbox", flags(f"sandbox-{sandbox.id}"))
    print("INFO  egress sidecar", flags(f"sandbox-egress-{sandbox.id}"))
finally:
    sandbox.kill()
    sandbox.close()

sys.exit(1 if failed else 0)
