// verify.js: the verification gate's verifier (factory.md, loop 0). Runs in the sandbox image with no model, no credential and egress to
// the npm registry only. Clones /src into /work, installs once per checkout (npm ci, when there is a package.json), runs every BLOCK's
// repro from /in/findings.json at the head and at the base under a 300 s timeout, and runs the two differential test checks (the base's
// test files against the head's code; the head's new or changed test files against the base's code). It records exit codes only; the
// host classifies them. Every repro and check starts from a pristine checkout (a repro that writes files must not change the next one's
// answer). Paths and the timeout come from the environment so the stub suite can run this file against host directories.
'use strict';
const { spawnSync } = require('child_process'); const fs = require('fs'); const path = require('path');
const SRC = process.env.SRC || '/src', IN = process.env.IN || '/in', WORK = process.env.WORK || '/work', OUT = process.env.OUT || '/out';
const HEAD = process.env.HEAD_SHA, BASE = process.env.BASE_SHA, TIMEOUT = Number(process.env.VERIFY_TIMEOUT_MS) || 300000;
if (!HEAD || !BASE) { console.error('verify: HEAD_SHA and BASE_SHA are required'); process.exit(2); }
const blocks = (() => { const f = JSON.parse(fs.readFileSync(path.join(IN, 'findings.json'), 'utf8')); return Array.isArray(f.blocks) ? f.blocks : []; })();
const TEST_RE = /(^|\/)(tests?|__tests__|spec)\/|\.(test|spec)\.[cm]?[jt]sx?$/;
const out = { install: { head: null, base: null }, blocks: blocks.map(() => ({ head_exit: null, base_exit: null })), checks: { test_files: [], base_tests_at_head: null, head_tests_at_base: null } };
const log = (s) => process.stdout.write(`verify: ${s}\n`);
const write = () => fs.writeFileSync(path.join(OUT, 'verify.json'), JSON.stringify(out));
function sh(cmd, show) {  // exit code of `bash -o pipefail -c cmd` at the clone root: 124 on timeout (as timeout(1)), 127 when bash cannot start, 137 when killed.
  // Its own process group, killed whole on a timeout, so a child a repro left behind cannot hold the pipes or outlive it into the next block;
  // a repro's output is discarded (only exit codes are evidence), an install's or test run's goes to the container log. The status, when
  // bash produced one, wins over a late error (a lingering child makes spawnSync report ETIMEDOUT beside a real status).
  const r = spawnSync('bash', ['-o', 'pipefail', '-c', cmd], { cwd: WORK, stdio: show ? ['ignore', 'inherit', 'inherit'] : 'ignore', detached: true, timeout: TIMEOUT, killSignal: 'SIGKILL', env: { ...process.env, HOME: '/tmp' } });
  if (r.pid) { try { process.kill(-r.pid, 'SIGKILL'); } catch {} }
  if (typeof r.status === 'number') return r.status;
  if (r.error) return r.error.code === 'ETIMEDOUT' ? 124 : 127;
  return 137;
}
function git(...a) { const r = spawnSync('git', a, { cwd: WORK, stdio: ['ignore', 'pipe', 'pipe'], encoding: 'utf8' }); if (r.status !== 0) throw new Error(`git ${a.join(' ')}: ${r.stderr.trim()}`); return r.stdout; }
function checkout(sha) { git('checkout', '-q', '-f', '--detach', sha); git('clean', '-fdxq', '-e', 'node_modules'); }   // ponytail: node_modules survives between repros (npm ci per repro otherwise); a repro that writes there can colour the next one
function install(label) {  // null when there is nothing to install; a failed install ends the gate (the host reads install.*)
  if (!fs.existsSync(path.join(WORK, 'package.json'))) return true;
  const rc = sh('npm ci', true); out.install[label] = rc; log(`npm ci at ${label}: exit ${rc}`); return rc === 0;
}
function hasTest() { try { const p = JSON.parse(fs.readFileSync(path.join(WORK, 'package.json'), 'utf8')); return !!(p.scripts && p.scripts.test); } catch { return false; } }
// Put the other side's version of the changed test files into this checkout: files it has are checked out, files it lacks are removed.
function swapTests(sha, has, files) { files.filter((f) => !has.has(f)).forEach((f) => fs.rmSync(path.join(WORK, f), { force: true })); const c = files.filter((f) => has.has(f)); if (c.length) git('checkout', sha, '--', ...c); }
try {
  const c = spawnSync('git', ['clone', '-q', '--no-local', SRC, WORK], { stdio: ['ignore', 'inherit', 'inherit'] }); if (c.status !== 0) throw new Error('clone failed');
  checkout(HEAD); if (git('rev-parse', 'HEAD').trim() !== HEAD) throw new Error(`checkout is not ${HEAD}`);
  // NUL-separated, no rename detection: a quoted non-ASCII path would not check out, and a renamed test file must restore under its old name too.
  const tests = git('diff', '--name-only', '-z', '--no-renames', BASE, HEAD).split('\0').filter((f) => f && TEST_RE.test(f)); out.checks.test_files = tests;
  const inBase = new Set(git('ls-tree', '-r', '-z', '--name-only', BASE).split('\0')), inHead = new Set(git('ls-tree', '-r', '-z', '--name-only', HEAD).split('\0'));
  if (!install('head')) { write(); process.exit(0); }
  blocks.forEach((b, i) => { checkout(HEAD); out.blocks[i].head_exit = sh(String(b.repro)); log(`block ${i} at head: exit ${out.blocks[i].head_exit}`); });
  if (tests.length && hasTest()) { checkout(HEAD); swapTests(BASE, inBase, tests); out.checks.base_tests_at_head = sh('npm test', true); log(`base tests at head: exit ${out.checks.base_tests_at_head}`); }
  checkout(BASE); if (!install('base')) { write(); process.exit(0); }
  blocks.forEach((b, i) => { checkout(BASE); out.blocks[i].base_exit = sh(String(b.repro)); log(`block ${i} at base: exit ${out.blocks[i].base_exit}`); });
  if (tests.length && hasTest()) { checkout(BASE); swapTests(HEAD, inHead, tests); out.checks.head_tests_at_base = sh('npm test', true); log(`head tests at base: exit ${out.checks.head_tests_at_base}`); }
  write();
} catch (e) { log(`error: ${e.message}`); try { write(); } catch {} process.exit(2); }
