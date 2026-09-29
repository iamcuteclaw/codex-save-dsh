// codex-status.js -- ask CODEX what its own goal status is.
//
// The guard is not allowed to invent "blocked". Codex stores goals in
// ~/.codex/goals_1.sqlite, table thread_goals, with
//   CHECK(status IN ('active','paused','blocked','usage_limited','budget_limited','complete'))
// so the guard reads that word rather than making one up. The thread id comes from the
// `session id: <uuid>` line codex prints at the head of its own output.
//
// usage: node codex-status.js <thread-id>
// prints one of the status words, or NO_ROW / NO_THREAD / CANNOT_OPEN / NO_NODE_SQLITE
const path = require('node:path');
const os = require('node:os');

const threadId = process.argv[2];
if (!threadId) { console.log('NO_THREAD'); process.exit(0); }

let DatabaseSync;
try { ({ DatabaseSync } = require('node:sqlite')); }
catch (e) { console.log('NO_NODE_SQLITE'); process.exit(0); }

const file = path.join(os.homedir(), '.codex', 'goals_1.sqlite');
let db;
try { db = new DatabaseSync(file, { readOnly: true }); }
catch (e) { console.log('CANNOT_OPEN'); process.exit(0); }

try {
  const row = db.prepare('SELECT status FROM thread_goals WHERE thread_id = ?').get(threadId);
  if (!row) { console.log('NO_ROW'); process.exit(0); }
  console.log(String(row.status || 'EMPTY'));
} catch (e) {
  console.log('CANNOT_OPEN');
}
process.exit(0);
