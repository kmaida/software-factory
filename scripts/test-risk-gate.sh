#!/usr/bin/env bash
# Self-check for risk-gate.sh: builds a throwaway repo and asserts each rule.
set -euo pipefail
gate=$(cd "$(dirname "$0")" && pwd)/risk-gate.sh
t=$(mktemp -d "${TMPDIR:-/tmp}/rg.XXXXXX"); cd "$t"; git init -q; git config user.email f@x; git config user.name f; git config commit.gpgsign false
mkdir -p .factory src/auth tests
cat > .factory/policy.json <<'P'
{"auto_merge":true,"allow":["src/*","tests/*"],"deny":["src/auth/*",".factory/*","package-lock.json"],"tests":["tests/*"],"max_lines":10}
P
echo a > src/a.ts; echo t > tests/a.test.ts; echo x > src/auth/x.ts; echo lock > package-lock.json
git add -A; git commit -qm base; base=$(git rev-parse HEAD)
try() { git checkout -q -b "$1" "$base"; eval "$2"; git add -A; git commit -qm "$1"; out=$("$gate" . "$base" HEAD 2>/dev/null || true); git checkout -q "$base"; [[ $out == $3* ]] || { echo "FAIL $1: got '$out' want '$3'"; exit 1; }; echo "ok $1: $out"; }
try low        'echo b >> src/a.ts'                       low
try deny-auth  'echo b >> src/auth/x.ts'                  'review: src/auth/x.ts matches deny'
try policy     'echo "{}" > .factory/policy.json'         'review: .factory/policy.json matches deny'
try outside    'echo r > README.md'                       'review: README.md outside allow'
try test-del   'git rm -q tests/a.test.ts'                'review: test deleted'
try too-big    'seq 1 20 >> src/a.ts'                     'review: 20 changed lines'
try rename-out 'git mv src/a.ts docs.md'                  'review: docs.md outside allow'
try symlink    'ln -s a.ts src/l.ts'                      'review: symlink'
# KIM-579 false-lows: rename out of tests, symlink at a path with a space, binary under src
try test-rename 'git mv tests/a.test.ts src/disabled.ts'  'review: test deleted: tests/a.test.ts'
try symlink-sp  'ln -s a.ts "src/link file"'              'review: symlink: src/link file'
try binary      'head -c 102400 /dev/zero > src/blob.bin' 'review: binary: src/blob.bin'
# auto_merge:false at base must force review even for a clean diff
git checkout -q -b off "$base"; jq '.auto_merge=false' .factory/policy.json > p && mv p .factory/policy.json; git add -A; git commit -qm off; b2=$(git rev-parse HEAD)
echo b >> src/a.ts; git add -A; git commit -qm change; out=$("$gate" . "$b2" HEAD 2>/dev/null || true); git checkout -q "$base"
[[ $out == "review: auto_merge is not true" ]] || { echo "FAIL automerge-off: got '$out'"; exit 1; }; echo "ok automerge-off: $out"
echo "all risk-gate checks passed"; rm -rf "$t"
