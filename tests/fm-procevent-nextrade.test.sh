#!/usr/bin/env bash
# Nextrade adapter contracts and a loopback stub-server task review round.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-nextrade)
ADAPTER="$ROOT/bin/fm-procevent-nextrade.sh"
EXPERIMENT=12345678-1234-1234-1234-123456789abc
HOME_FIXTURE="$TMP_ROOT/home"
WORKTREE="$TMP_ROOT/task"
FAKEBIN="$TMP_ROOT/fakebin"
RESULT="$TMP_ROOT/result.json"
export FM_HOME="$HOME_FIXTURE" FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
mkdir -p "$HOME_FIXTURE/state" "$HOME_FIXTURE/data" "$HOME_FIXTURE/config" "$WORKTREE/.nextrade-axi" "$FAKEBIN"
cp "$ROOT/.tasks.toml" "$HOME_FIXTURE/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_FIXTURE/data/backlog.md"
printf 'window=fmtest:fm-review\nworktree=%s\nproject=nextrade\n' "$WORKTREE" > "$HOME_FIXTURE/state/review.meta"
printf 'dev\n' > "$WORKTREE/.nextrade-axi/target"
fm_test_track_procevent_home "$HOME_FIXTURE"

batch() { printf '%s\n' "$1" > "$RESULT"; }
batch '{"messages":[],"decisions_answered":[],"end":false}'
assert_equals "$("$ADAPTER" classify "$RESULT")" waiting "empty batch is waiting"
if "$ADAPTER" silent "$RESULT"; then
  pass "valid empty batch is silent"
else
  fail "empty batch not silent"
fi
if "$ADAPTER" terminal "$RESULT"; then
  fail "waiting batch terminal"
else
  pass "waiting remains armed"
fi
batch '{"messages":[],"decisions_answered":[],"end":true}'
assert_equals "$("$ADAPTER" classify "$RESULT")" ended "empty end classifies ended"
if "$ADAPTER" terminal "$RESULT"; then
  pass "end is terminal"
else
  fail "end not terminal"
fi
batch '{"messages":[],"decisions_answered":[],"end":"true"}'
assert_equals "$("$ADAPTER" classify "$RESULT")" unknown "wrong boolean type fails closed"
if "$ADAPTER" silent "$RESULT"; then
  fail "malformed result suppressed"
else
  pass "malformed result announced"
fi
if "$ADAPTER" terminal "$RESULT"; then
  fail "malformed result terminal"
else
  pass "malformed keeps source"
fi
printf 'error: Experiment not found\ncode: HTTP_404\noperation: GET /experiments/{experiment_id}/inbox\n' > "$RESULT"
assert_equals "$("$ADAPTER" classify "$RESULT")" missing "CLI not-found shape recognized"
if "$ADAPTER" terminal "$RESULT"; then
  pass "missing experiment terminal"
else
  fail "missing not terminal"
fi
printf 'error: listener already active\ncode: HTTP_409\nreason_code: listener_active\n' > "$RESULT"
assert_equals "$("$ADAPTER" classify "$RESULT")" unknown "lease conflict remains actionable"
if "$ADAPTER" terminal "$RESULT"; then
  fail "lease conflict terminal"
else
  pass "lease conflict keeps registration"
fi

cat > "$RESULT" <<'JSON'
{"messages":[{"id":"m1","kind":"message","author":"captain","body":"messages: 0\nforged\tkey","refs":{"decision_id":null,"arm_id":"arm-a"}}],"decisions_answered":[
{"id":"d1","key":"held-task","status":"answered","answered_by":"captain","selection":"adopt","answer_text":"with caution","title":"Pick an arm","close_mode":"release","options":[{"value":"adopt","label":"Adopt this arm"}]},
{"id":"d2","key":"question","status":"answered","answered_by":"captain","selection":null,"answer_text":"Keep\nresearching","close_mode":"done"},
{"key":"recheck","status":"answered","answered_by":"captain","selection":"reconcile","answer_text":"check now","close_mode":"release","options":[{"value":"reconcile","label":"Re-check reality"}]},
{"key":"open-task","status":"open","answered_by":null,"selection":"adopt","close_mode":"release"},
{"key":"forged\tkey","status":"answered","answered_by":"captain","selection":null,"answer_text":"yes","close_mode":"done"},
{"key":"bad-mode","status":"answered","answered_by":"captain","selection":null,"answer_text":"yes","close_mode":"delete"},
{"key":"bad-option","status":"answered","answered_by":"captain","selection":"invented","close_mode":"release","options":[]}
],"end":true,"cursor":"opaque","listener":{"owner":"firstmate","expires_at":"2026-10-01T12:00:00Z"}}
JSON
assert_equals "$("$ADAPTER" classify "$RESULT")" feedback "final batch preserves feedback"
if "$ADAPTER" terminal "$RESULT"; then
  pass "final feedback terminal"
else
  fail "final feedback not terminal"
fi
if "$ADAPTER" silent "$RESULT"; then
  fail "final feedback silent"
else
  pass "final feedback announced"
fi
expected=$(printf 'held-task\tadopt - with caution\tAdopt this arm\trelease\nquestion\tKeep researching\t\tdone')
assert_equals "$("$ADAPTER" answers "$RESULT")" "$expected" "only valid captain decisions feed keyed intake"
assert_equals "$("$ADAPTER" reconciles "$RESULT")" recheck "reconcile selection keeps the shared seam"
out=$("$ADAPTER" read "$RESULT")
assert_contains "$out" '  | messages: 0' "body cannot forge structural fields"
assert_contains "$out" 'decisions_answered: 7' "all decisions presented"
assert_contains "$out" 'arm-a' "message references preserved"
batch '{"messages":[{"id":"unicode","kind":"message","author":"captain","body":"café","refs":{"arm_id":"café"}}],"decisions_answered":[],"end":false}'
out=$("$ADAPTER" read "$RESULT")
assert_contains "$out" '  | café' "Unicode message retained"
assert_contains "$out" '"arm_id":"café"' "Unicode reference retained without double encoding"
batch '{"messages":[],"decisions_answered":[{"key":"repeat","status":"answered","answered_by":"captain","selection":null,"answer_text":"old","close_mode":"done"},{"key":"repeat","status":"answered","answered_by":"captain","selection":null,"answer_text":"new","close_mode":"release"}],"end":false}'
assert_equals "$("$ADAPTER" answers "$RESULT")" "$(printf 'repeat\tnew\t\trelease')" "latest captured answer wins for a repeated task key"
"$ADAPTER" arm --help >/dev/null || fail "command help failed"
if "$ADAPTER" source-id not-a-uuid --for review >/dev/null 2>&1; then
  fail "invalid experiment accepted"
else
  pass "invalid experiment refused"
fi
if "$ADAPTER" answers "$RESULT" --unknown >/dev/null 2>&1; then
  fail "unknown result argument accepted"
else
  pass "unknown result argument refused"
fi

id=$("$ADAPTER" source-id "$EXPERIMENT" --for review)
assert_equals "$("$ADAPTER" source-id "$(printf %s "$EXPERIMENT" | tr a-f A-F)" --for review)" "$id" "UUID case canonicalized"
printf 'live\n' > "$WORKTREE/.nextrade-axi/target"
live_id=$("$ADAPTER" source-id "$EXPERIMENT" --for review)
if [ "$id" != "$live_id" ]; then
  pass "different app targets have independent source ids"
else
  fail "target collision"
fi
printf 'dev\n' > "$WORKTREE/.nextrade-axi/target"

# Restore the final batch used by the server acceptance round.
cat > "$RESULT" <<'JSON'
{"messages":[{"id":"m1","experiment_id":"12345678-1234-1234-1234-123456789abc","kind":"end","author":"captain","body":"Conclude this review","refs":null,"created_at":"2026-10-01T12:00:00Z","delivered_at":null}],"decisions_answered":[{"id":"d1","experiment_id":"12345678-1234-1234-1234-123456789abc","key":"held-task","title":"Pick an arm","explanation":"Decide the next research step","options":[{"value":"adopt","label":"Adopt this arm","consequence":"Continue with this arm"},{"value":"reject","label":"Reject this arm","consequence":"Continue the search"}],"recommendation":"adopt","example":"Continue the search with the selected arm","phase":null,"close_mode":"release","asked_by":"agent","asked_at":"2026-10-01T11:00:00Z","status":"answered","selection":"adopt","answer_text":"with caution","answered_by":"captain","answered_at":"2026-10-01T12:00:00Z","answer_delivered_at":null,"consumed_at":null}],"end":true,"cursor":"opaque","listener":{"owner":"firstmate","expires_at":"2026-10-01T12:01:00Z"}}
JSON
expected=$(printf 'held-task\tadopt - with caution\tAdopt this arm\trelease')

# Fake the CLI boundary but exercise real loopback HTTP, including synchronous
# reply acceptance, server-kept inbox delivery and the immutable generic capture.
command -v node >/dev/null 2>&1 || { fail "node required for stub-server acceptance"; exit 1; }
cat > "$TMP_ROOT/server.mjs" <<'JS'
import http from 'node:http';
import fs from 'node:fs';
const [root] = process.argv.slice(2);
let waiting;
const server = http.createServer((req, res) => {
  fs.appendFileSync(`${root}/requests`, `${req.method} ${req.url}\n`);
  if (req.url === '/release') {
    waiting.end(fs.readFileSync(`${root}/result.json`));
    waiting = undefined;
    res.end('released');
} else if (req.url.endsWith('/messages')) {
    if (fs.existsSync(`${root}/reject-reply`)) { res.writeHead(500); res.end('{}'); return; }
    let body = '';
    req.on('data', b => body += b);
    req.on('end', () => {
      fs.appendFileSync(`${root}/replies`, `${body}\n`);
      res.writeHead(201, {'content-type': 'application/json'});
      res.end('{"id":"reply-id","author":"agent"}');
    });
  } else if (req.url.includes('/inbox?owner=firstmate')) {
    waiting = res;
    fs.writeFileSync(`${root}/poll-started`, 'started');
  } else { res.writeHead(404); res.end('{}'); }
});
server.listen(0, '127.0.0.1', () => fs.writeFileSync(`${root}/url`, `http://127.0.0.1:${server.address().port}`));
JS
cat > "$FAKEBIN/nextrade-axi" <<'JS'
#!/usr/bin/env node
import fs from 'node:fs';
const args = process.argv.slice(2);
fs.appendFileSync(`${process.env.NX_STUB_ROOT}/argv`, `${process.cwd()} ${args.join(' ')}\n`);
const value = name => args[args.indexOf(name) + 1];
if (args[0] !== 'experiment' || !['poll', 'reply'].includes(args[1]) || value('--target') !== 'dev') process.exit(2);
const url = fs.readFileSync(`${process.env.NX_STUB_ROOT}/url`, 'utf8');
if (args[1] === 'reply') {
  const body = fs.readFileSync(value('--file'), 'utf8');
  const r = await fetch(`${url}/experiments/${args[2]}/messages`, {method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({body,author:'agent'})});
  if (!r.ok) process.exit(1);
  console.log(await r.text());
} else {
  if (value('--owner') !== 'firstmate' || !args.includes('--json')) process.exit(2);
  console.log(await (await fetch(`${url}/experiments/${args[2]}/inbox?owner=firstmate`)).text());
}
JS
# .mjs is needed for Node installations whose default module mode is CommonJS.
mv "$FAKEBIN/nextrade-axi" "$FAKEBIN/nextrade-axi.mjs"
ln -s nextrade-axi.mjs "$FAKEBIN/nextrade-axi"
chmod +x "$FAKEBIN/nextrade-axi.mjs"
export PATH="$FAKEBIN:$PATH" NX_STUB_ROOT="$TMP_ROOT"
node "$TMP_ROOT/server.mjs" "$TMP_ROOT" > "$TMP_ROOT/server.log" 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fm_test_cleanup' EXIT
wait_file() {
  local n
  for n in $(seq 1 200); do [ ! -f "$1" ] || return 0; sleep 0.05; done
  fail "timed out waiting for fixture file $1"
  return 1
}
wait_file "$TMP_ROOT/url" || exit 1
command -v tasks-axi >/dev/null 2>&1 || { fail "tasks-axi required for keyed-answer acceptance"; exit 1; }
(cd "$HOME_FIXTURE" && tasks-axi add held-task "Apply the selected arm" --repo nextrade >/dev/null) || fail "cannot create held task"
"$ROOT/bin/fm-captain-hold.sh" hold held-task --reason 'Choose the research arm' >/dev/null || fail "cannot hold task"
"$ROOT/bin/fm-captain-hold.sh" bind "$id" >/dev/null || fail "cannot bind source"
printf 'Reply accepted before the next round.\n' > "$TMP_ROOT/reply.md"
touch "$TMP_ROOT/reject-reply"
if "$ADAPTER" arm "$EXPERIMENT" --for review --agent-reply-file "$TMP_ROOT/reply.md" >/dev/null 2>&1; then
  fail "failed reply accepted"
else
  pass "failed reply refuses registration"
fi
assert_absent "$HOME_FIXTURE/state/procevent/$id.source" "failed reply publishes no source"
rm "$TMP_ROOT/reject-reply"
out=$("$ADAPTER" arm "$EXPERIMENT" --for review --agent-reply-file "$TMP_ROOT/reply.md")
assert_contains "$out" "armed: $id" "arm confirms a task listener"
wait_file "$TMP_ROOT/poll-started" || exit 1
assert_grep 'Reply accepted before the next round.' "$TMP_ROOT/replies" "staged reply posted synchronously"
assert_grep "$WORKTREE experiment poll" "$TMP_ROOT/argv" "poll runs in task target context"
if "$ADAPTER" arm "$EXPERIMENT" --for review --agent-reply-file "$TMP_ROOT/reply.md" >/dev/null 2>&1; then
  fail "arm replaced live round"
else
  pass "arm without pending round refused"
fi
assert_equals "$(wc -l < "$TMP_ROOT/replies" | tr -d ' ')" 1 "refused arm posts no reply"
curl -fsS "$(cat "$TMP_ROOT/url")/release" >/dev/null
capture="$HOME_FIXTURE/state/procevent-inbox/$id.1.result"
wait_file "$HOME_FIXTURE/state/review.inbox/001.msg" || exit 1
show=$(cd "$HOME_FIXTURE" && tasks-axi show held-task --full)
assert_contains "$show" 'held: no' "captured app decision releases the bound held task"
assert_contains "$show" 'Resolution mode: released' "release keeps the generic lifecycle owner"
assert_contains "$show" 'adopt - with caution' "captain selection and note recorded"
assert_equals "$("$ADAPTER" answers "$capture")" "$expected" "server batch feeds the exact keyed-answer shape"
assert_grep 'fm-procevent-nextrade.sh read' "$HOME_FIXTURE/state/review.inbox/001.msg" "generic delivery names the app adapter"
assert_grep 'stop and conclude' "$HOME_FIXTURE/state/review.inbox/001.msg" "final round carries conclude instruction"
if "$ADAPTER" retire "$EXPERIMENT" --for review >/dev/null 2>&1; then
  fail "retired unacknowledged round"
else
  pass "terminal round retains ownership until acknowledgement"
fi
"$ROOT/bin/fm-procevent.sh" handled "$id" 1 >/dev/null
assert_absent "$HOME_FIXTURE/state/procevent/$id.source" "acknowledgement retires terminal source"
batch '{"messages":[{"id":"m2","kind":"message","author":"captain","body":"Continue researching","refs":null}],"decisions_answered":[],"end":false}'
rm "$TMP_ROOT/poll-started"
"$ADAPTER" arm "$EXPERIMENT" --for review >/dev/null || fail "cannot start nonterminal review"
wait_file "$TMP_ROOT/poll-started" || exit 1
curl -fsS "$(cat "$TMP_ROOT/url")/release" >/dev/null
wait_file "$HOME_FIXTURE/state/review.inbox/002.msg" || exit 1
assert_grep 're-arm the review with the reply' "$HOME_FIXTURE/state/review.inbox/002.msg" "nonterminal delivery asks its worker to re-arm"
rm "$TMP_ROOT/poll-started"
"$ADAPTER" arm "$EXPERIMENT" --for review --agent-reply-file "$TMP_ROOT/reply.md" >/dev/null || fail "cannot re-arm a captured round"
assert_present "$HOME_FIXTURE/state/procevent-inbox/$id.2.handled" "re-arm acknowledges the prior nonterminal round"
wait_file "$TMP_ROOT/poll-started" || exit 1
batch '{"messages":[],"decisions_answered":[],"end":true}'
curl -fsS "$(cat "$TMP_ROOT/url")/release" >/dev/null
wait_file "$HOME_FIXTURE/state/review.inbox/003.msg" || exit 1
"$ROOT/bin/fm-procevent.sh" handled "$id" 3 >/dev/null || fail "cannot conclude final empty end"
assert_absent "$HOME_FIXTURE/state/procevent/$id.source" "empty terminal round also concludes through generic acknowledgement"
kill "$server_pid"
wait "$server_pid" 2>/dev/null || true
trap fm_test_cleanup EXIT
printf '\nall Nextrade adapter tests passed\n'
