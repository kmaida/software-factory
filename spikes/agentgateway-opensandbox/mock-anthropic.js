// Stand-in for api.anthropic.com in mock mode: answers every Messages call with one canned text block and
// prints the credential headers it received (hashed), one JSON line per request. No dependencies.
"use strict";
const http = require("http");
const crypto = require("crypto");
const sha = (s) => (s ? crypto.createHash("sha256").update(s).digest("hex").slice(0, 16) : null);
const TEXT = "SPIKE_OK";

http.createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    const auth = req.headers.authorization || "";
    console.log(JSON.stringify({ method: req.method, url: req.url, bearer_sha: sha(auth.replace(/^Bearer /, "")), x_api_key_sha: sha(req.headers["x-api-key"]) }));
    let j = {}; try { j = JSON.parse(body); } catch {}
    const model = j.model || "mock";
    if (req.url.includes("count_tokens")) { res.writeHead(200, { "content-type": "application/json" }); return res.end('{"input_tokens":1}'); }
    const msg = { id: "msg_spike", type: "message", role: "assistant", model, stop_reason: null, stop_sequence: null, usage: { input_tokens: 1, output_tokens: 1 } };
    if (!j.stream) {
      res.writeHead(200, { "content-type": "application/json" });
      return res.end(JSON.stringify({ ...msg, content: [{ type: "text", text: TEXT }], stop_reason: "end_turn" }));
    }
    res.writeHead(200, { "content-type": "text/event-stream" });
    const ev = (o) => res.write(`event: ${o.type}\ndata: ${JSON.stringify(o)}\n\n`);
    ev({ type: "message_start", message: { ...msg, content: [] } });
    ev({ type: "content_block_start", index: 0, content_block: { type: "text", text: "" } });
    ev({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: TEXT } });
    ev({ type: "content_block_stop", index: 0 });
    ev({ type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: null }, usage: { output_tokens: 1 } });
    ev({ type: "message_stop" });
    res.end();
  });
}).listen(9000, () => console.log('{"listening":9000}'));
