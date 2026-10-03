#!/usr/bin/env bash
# Runs the GitLab template's script the way a GitLab runner would, with fake
# models and a fake GitLab notes API: no keys, no cost, no GitLab.
#
# Checks: the review runs against the merge request's base, the note is
# posted, a second run updates that note instead of adding one, and the job
# exits with the CLI's code.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'kill "${server:-0}" 2>/dev/null || true; rm -rf "${tmp:?}"' EXIT

# The template's script, as GitLab would run it.
python3 - "$here/apex-review.yml" > "$tmp/job.sh" <<'PY'
import sys, yaml
print(yaml.safe_load(open(sys.argv[1]))['.apex-review']['script'][0])
PY
# And its variables, as GitLab would set them.
eval "$(python3 - "$here/apex-review.yml" <<'PY'
import sys, yaml, shlex
for k, v in yaml.safe_load(open(sys.argv[1]))['.apex-review']['variables'].items():
    print(f"export {k}={shlex.quote(str(v))}")
PY
)"

# A fake GitLab: the notes endpoints only, kept in memory.
cat > "$tmp/gitlab.mjs" <<'JS'
import { createServer } from 'node:http';
import { writeFileSync } from 'node:fs';
const notes = [];
const path = '/api/v4/projects/42/merge_requests/7/notes';
createServer((req, res) => {
  let data = '';
  req.on('data', (c) => (data += c));
  req.on('end', () => {
    if (req.headers['private-token'] !== 'test-token') { res.writeHead(401).end('{}'); return; }
    const url = new URL(req.url, 'http://x');
    const send = (code, body) => { res.writeHead(code, { 'content-type': 'application/json' }).end(JSON.stringify(body)); };
    if (req.method === 'GET' && url.pathname === path) return send(200, notes);
    if (req.method === 'POST' && url.pathname === path) {
      const n = { id: notes.length + 1, body: JSON.parse(data).body };
      notes.push(n);
      writeFileSync(process.env.NOTES_OUT, JSON.stringify(notes));
      return send(201, n);
    }
    const m = url.pathname.match(/\/notes\/(\d+)$/);
    if (req.method === 'PUT' && m) {
      const n = notes.find((x) => x.id === Number(m[1]));
      if (!n) return send(404, {});
      n.body = JSON.parse(data).body;
      writeFileSync(process.env.NOTES_OUT, JSON.stringify(notes));
      return send(200, n);
    }
    send(404, {});
  });
}).listen(0, '127.0.0.1', function () { console.log(this.address().port); });
JS
NOTES_OUT="$tmp/notes.json" node "$tmp/gitlab.mjs" > "$tmp/port" &
server=$!
for _ in $(seq 50); do [ -s "$tmp/port" ] && break; sleep 0.1; done
port="$(cat "$tmp/port")"

# A repository with a merge request: main, then one commit on a branch.
repo="$tmp/repo"
git init -q -b main "$repo"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
printf 'export function add(a, b) {\n  return a - b;\n}\n' > "$repo/math.js"
git -C "$repo" add math.js
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "feat: add"
base_sha="$(git -C "$repo" rev-parse HEAD~1)"

run_job() {
  (
    cd "$repo"
    export ROUNDTABLE_FAKE_PROVIDERS=1 ANTHROPIC_API_KEY=fake OPENAI_API_KEY=fake GOOGLE_API_KEY=fake
    export CI_MERGE_REQUEST_IID=7 CI_MERGE_REQUEST_PROJECT_ID=42 CI_MERGE_REQUEST_DIFF_BASE_SHA="$base_sha"
    export CI_API_V4_URL="http://127.0.0.1:$port/api/v4" APEX_GITLAB_TOKEN=test-token
    export APEX_FAIL_ON=none
    bash "$tmp/job.sh"
  )
}

fail() { echo "FAIL: $1" >&2; exit 1; }

run_job > "$tmp/run1.log" 2>&1 || { cat "$tmp/run1.log"; fail "first run exited non-zero"; }
grep -q 'posted the review' "$tmp/run1.log" || { cat "$tmp/run1.log"; fail "first run did not post a note"; }
grep -q "changes against $base_sha" "$tmp/run1.log" || { cat "$tmp/run1.log"; fail "the review did not measure against the merge request's base"; }
# math.js and its diff, and nothing the job wrote for itself.
grep -q 'reviewing 2 files' "$tmp/run1.log" || { cat "$tmp/run1.log"; fail "the review read files other than the change"; }
[ -f "$repo/apex-review.md" ] || fail "no apex-review.md artifact"
grep -q 'math.js\|Review' "$repo/apex-review.md" || fail "apex-review.md looks empty"

run_job > "$tmp/run2.log" 2>&1 || { cat "$tmp/run2.log"; fail "second run exited non-zero"; }
grep -q 'updated the review' "$tmp/run2.log" || { cat "$tmp/run2.log"; fail "second run did not update the note"; }
[ "$(node -p "require('$tmp/notes.json').length")" = 1 ] || fail "expected one note, got more"
node -e "const n=require('$tmp/notes.json')[0].body; if(!n.startsWith('<!-- apex-directive-review -->')) process.exit(1)" \
  || fail "the note is missing its marker"

# The gate: fail-on low must trip on the fake panel's findings (exit 2).
set +e
( cd "$repo"; rm -f apex-review.md
  export ROUNDTABLE_FAKE_PROVIDERS=1 ANTHROPIC_API_KEY=fake OPENAI_API_KEY=fake GOOGLE_API_KEY=fake
  export CI_MERGE_REQUEST_IID=7 CI_MERGE_REQUEST_PROJECT_ID=42 CI_MERGE_REQUEST_DIFF_BASE_SHA="$base_sha"
  export APEX_FAIL_ON=low APEX_COMMENT=false
  bash "$tmp/job.sh" ) > "$tmp/run3.log" 2>&1
code=$?
set -e
[ "$code" = 2 ] || { cat "$tmp/run3.log"; fail "fail-on low should exit 2, got $code"; }

# No merge request: a clear error, not a review of nothing.
set +e
( cd "$repo"; unset CI_MERGE_REQUEST_IID; bash "$tmp/job.sh" ) > "$tmp/run4.log" 2>&1
code=$?
set -e
[ "$code" = 1 ] && grep -q 'no merge request' "$tmp/run4.log" || fail "outside a merge request should exit 1 with a message"

echo "ok: posted, updated in place, gate exit 2, refused outside a merge request"
