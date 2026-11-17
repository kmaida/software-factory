// Stand-in for api.anthropic.com in mock mode: a canned model that asks a worker for one Bash command and then answers
// in text. Prints the credential headers it received (hashed), one JSON line per request. No dependencies.
// For `spike.sh exchange` it also stands in for the two token endpoints on the way: Keycard's (RFC 8693) and
// Anthropic's federation endpoint (RFC 7523). Each accepts only what the real one requires and prints what it was sent.
"use strict";
const http = require("http");
const crypto = require("crypto");
const sha = (s) => (s ? crypto.createHash("sha256").update(s).digest("hex").slice(0, 16) : null);
const TEXT = "SPIKE_OK";
const COMMAND = "echo 'made by the worker' > spike.txt && git add spike.txt && git commit -qm 'spike: the worker commits'";

// What "Keycard" issues: a signed JWT for the worker, addressed to the gateway (the sandbox holds this), then an opaque
// token for Anthropic's audience in exchange for it. What "Anthropic" issues: an opaque API token in exchange for that.
const { publicKey, privateKey } = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const now = Math.floor(Date.now() / 1000);
// The header type and the last three claims are what Keycard's real token endpoint requires of a subject token (README.md).
const signed = b64({ alg: "RS256", typ: "at+jwt", kid: "k1" }) + "." + b64({ iss: "http://mock-keycard", sub: "urn:spike:worker", aud: "urn:spike:gateway", iat: now, exp: now + 900,
  client_id: "spike-worker-credential", keycard_app_id: "spike-worker", sub_profile: "app" });
const AGENT = signed + "." + crypto.sign("sha256", Buffer.from(signed), privateKey).toString("base64url");
const KC = "kc-" + crypto.randomBytes(16).toString("hex");
const AN = "an-" + crypto.randomBytes(16).toString("hex");
const GATEWAY_BASIC = "Basic " + Buffer.from(`spike-gateway:${process.env.GW_SECRET}`).toString("base64");
const FED = JSON.parse(process.env.FED || "{}");   // the four federation ids the gateway is configured to send
const X = "urn:ietf:params:oauth:";
const FORM = "application/x-www-form-urlencoded";

http.createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    const type = req.headers["content-type"] || "";
    const json = (code, o) => { res.writeHead(code, { "content-type": "application/json" }); res.end(JSON.stringify(o)); };
    const params = () => { try { return type.includes("json") ? JSON.parse(body) : Object.fromEntries(new URLSearchParams(body)); } catch { return {}; } };
    const auth = req.headers.authorization || "";
    if (req.url === "/jwks") return json(200, { keys: [{ ...publicKey.export({ format: "jwk" }), kid: "k1", alg: "RS256", use: "sig" }] });
    if (req.url === "/oauth/2/token") {   // Keycard: a confidential client, a subject access token Keycard minted, a resource
      const p = params();
      const ok = req.method === "POST" && type.startsWith(FORM) && auth === GATEWAY_BASIC && p.grant_type === X + "grant-type:token-exchange" && p.subject_token === AGENT
        && p.subject_token_type === X + "token-type:access_token" && p.resource === "https://api.anthropic.com";
      console.log(JSON.stringify({ token_endpoint: "keycard", ok, content_type: type, client_auth: auth.split(" ")[0] || null, params: Object.keys(p).sort() }));
      return ok ? json(200, { access_token: KC, token_type: "Bearer", issued_token_type: X + "token-type:access_token", expires_in: 3600 }) : json(400, { error: "invalid_request" });
    }
    if (req.url === "/v1/oauth/token") {   // Anthropic: the Keycard token as the assertion, and the four federation ids; a form or JSON
      const p = params();
      const ids = ["federation_rule_id", "organization_id", "service_account_id", "workspace_id"];
      const ok = req.method === "POST" && (type.startsWith(FORM) || type.includes("json")) && p.grant_type === X + "grant-type:jwt-bearer" && p.assertion === KC
        && ids.every((k) => typeof FED[k] === "string" && FED[k] !== "" && p[k] === FED[k]);
      console.log(JSON.stringify({ token_endpoint: "anthropic", ok, content_type: type, client_auth: auth.split(" ")[0] || null, params: Object.keys(p).sort() }));
      return ok ? json(200, { access_token: AN, token_type: "Bearer", expires_in: 3600 }) : json(401, { type: "error", error: { type: "authentication_error", message: "Authentication failed" } });
    }
    // The model: a worker that is offered Bash and has not yet seen a tool result is told to run COMMAND (one tool call);
    // every other call gets the text. So one worker turn is two model calls: the tool call, then the answer to its result.
    let j = {}; try { j = JSON.parse(body); } catch {}
    const has = (list, f) => Array.isArray(list) && list.some(f);
    const act = has(j.tools, (t) => t.name === "Bash") && !has(j.messages, (m) => has(m.content, (c) => c.type === "tool_result"));
    console.log(JSON.stringify({ method: req.method, url: req.url, bearer_sha: sha(auth.startsWith("Bearer ") ? auth.slice(7) : auth && "not a bearer: " + auth), x_api_key_sha: sha(req.headers["x-api-key"]), reply: act ? "tool_use" : "text" }));
    res.writeHead(200, { "content-type": "text/event-stream" });
    const ev = (o) => res.write(`event: ${o.type}\ndata: ${JSON.stringify(o)}\n\n`);
    ev({ type: "message_start", message: { id: "msg_spike", type: "message", role: "assistant", model: j.model || "mock", content: [], stop_reason: null, stop_sequence: null, usage: { input_tokens: 1, output_tokens: 1 } } });
    if (act) {
      ev({ type: "content_block_start", index: 0, content_block: { type: "tool_use", id: "toolu_spike", name: "Bash", input: {} } });
      ev({ type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: JSON.stringify({ command: COMMAND, description: "Write a file and commit it" }) } });
    } else {
      ev({ type: "content_block_start", index: 0, content_block: { type: "text", text: "" } });
      ev({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: TEXT } });
    }
    ev({ type: "content_block_stop", index: 0 });
    ev({ type: "message_delta", delta: { stop_reason: act ? "tool_use" : "end_turn", stop_sequence: null }, usage: { output_tokens: 1 } });
    ev({ type: "message_stop" });
    res.end();
  });
}).listen(9000, () => console.log(JSON.stringify({ listening: 9000, agent_jwt: AGENT, anthropic_token_sha: sha(AN) })));
