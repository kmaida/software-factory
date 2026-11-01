// Egress proxy for the sandbox containers: CONNECT to an allowlisted host on port 443, nothing else.
// Runs in the pinned node image on both the internal network (where the sandbox lives) and the bridge (the way out),
// so the sandbox has no route to the internet except through here. The client is the adversary: assume crafted bytes.
// ALLOW: one regex of hostnames, anchored here (^(?:ALLOW)$) whatever the operator wrote; lowercase; dots escaped by
// the orchestrator. IP literals are refused even if ALLOW matches them. Every decision is one JSON line on stdout,
// which the orchestrator writes into the run's log; if the log can't keep up, the proxy exits and the run fails closed.
// ponytail: host allowlist only, no request inspection; that is the Keycard proxy's job.
"use strict";
const http = require("http");
const net = require("net");
const dns = require("dns");
const { pipeline } = require("stream");

if (!process.env.ALLOW) { process.stderr.write("proxy: ALLOW is empty; refusing to start\n"); process.exit(1); }
const allow = new RegExp("^(?:" + process.env.ALLOW + ")$");
const port = Number(process.env.PORT || 8888);
const IDLE_MS = 60000, CONNECT_MS = 10000, MAX_CONN = 64, MAX_LOG_QUEUE = 1 << 20;
process.stdout.on("error", () => process.exit(1));   // the collector went away: no record, no proxy
const log = (o) => {
  process.stdout.write(JSON.stringify({ ts: new Date().toISOString(), ...o }) + "\n");
  if (process.stdout.writableLength > MAX_LOG_QUEUE) { process.stderr.write("proxy: log backlog; exiting\n"); process.exit(1); }
};
const short = (s) => String(s).slice(0, 200);

// Defense in depth: an allowed name that resolves to loopback, private, link-local or the bridge is refused.
function isPrivate(a) {
  if (a.startsWith("::ffff:")) a = a.slice(7);
  if (net.isIPv4(a)) {
    const [x, y] = a.split(".").map(Number);
    return x === 10 || x === 127 || x === 0 || (x === 172 && y >= 16 && y <= 31) || (x === 192 && y === 168) || (x === 169 && y === 254) || (x === 100 && y >= 64 && y <= 127);
  }
  const h = a.toLowerCase();
  return h === "::1" || h === "::" || /^f[cd]/.test(h) || /^fe[89ab]/.test(h);
}
function lookup(host, opts, cb) {
  dns.lookup(host, opts, (err, res, fam) => {
    if (err) return cb(err);
    const list = Array.isArray(res) ? res : [{ address: res, family: fam }];
    const ok = list.filter((r) => !isPrivate(r.address));
    if (!ok.length) return cb(Object.assign(new Error("resolves to a private address"), { code: "EPRIVATE" }));
    return opts.all ? cb(null, ok) : cb(null, ok[0].address, ok[0].family);
  });
}

const server = http.createServer((req, res) => {   // plain HTTP (GET http://...) is never allowed
  log({ deny: "method", method: req.method, url: short(req.url), from: req.socket.remoteAddress });
  res.writeHead(403); res.end();
});
server.maxConnections = MAX_CONN;
server.on("clientError", (e, sock) => { log({ deny: "malformed", code: e.code, from: sock.remoteAddress }); sock.destroy(); });
server.on("drop", (d) => log({ deny: "overload", from: d && d.remoteAddress }));
server.on("connect", (req, clientSock, head) => {
  clientSock.on("error", () => {});   // a client that resets mid-handshake must not crash the proxy
  clientSock.setTimeout(IDLE_MS, () => clientSock.destroy());
  const from = clientSock.remoteAddress;
  const m = /^([a-z0-9.-]{1,253}):443$/.exec(String(req.url).toLowerCase());
  const host = m && m[1];
  if (!host || net.isIP(host) || !allow.test(host)) {   // net.connect skips lookup for IP literals, so refuse them here
    log({ deny: "host", target: short(req.url), from });
    clientSock.end("HTTP/1.1 403 Forbidden\r\n\r\n");
    return;
  }
  const up = net.connect({ port: 443, host, lookup });
  clientSock.on("close", () => up.destroy());   // a client that leaves during the upstream connect takes it down too
  const onConnectTimeout = () => { log({ deny: "timeout", target: host, from }); up.destroy(); clientSock.destroy(); };
  up.setTimeout(CONNECT_MS, onConnectTimeout);
  up.on("connect", () => {
    if (clientSock.destroyed) { up.destroy(); return; }
    up.removeListener("timeout", onConnectTimeout);
    up.setTimeout(IDLE_MS, () => up.destroy());
    log({ allow: host, from });
    clientSock.write("HTTP/1.1 200 Connection Established\r\n\r\n");
    if (head.length) up.write(head);
    pipeline(up, clientSock, () => {}); pipeline(clientSock, up, () => {});   // either side closing closes the other
  });
  up.on("error", (e) => {
    log(e.code === "EPRIVATE" ? { deny: "private", target: host, from } : { error: e.code || e.message, target: host, from });
    clientSock.destroy();
  });
});
server.listen(port, () => log({ listening: port, allow: allow.source }));
