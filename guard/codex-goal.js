// codex-goal.js -- read CODEX'S OWN goal state.
//
// The guard is not allowed to invent a status. "BLOCKED" has to be something codex
// itself reported, so we read its store instead of guessing: ~/.codex/goals_1.sqlite.
// Opened READ-ONLY, and only the schema plus the newest rows are printed, so this can
// never disturb a running codex.
//
// usage: node codex-goal.js
const path = require('node:path');
const os = require('node:os');

let DatabaseSync;
try { ({ DatabaseSync } = require('node:sqlite')); }
catch (e) { console.log('NO_NODE_SQLITE ' + e.message); process.exit(3); }

const file = path.join(os.homedir(), '.codex', 'goals_1.sqlite');
let db;
try { db = new DatabaseSync(file, { readOnly: true }); }
catch (e) { console.log('CANNOT_OPEN ' + e.message); process.exit(3); }

let tables;
try { tables = db.prepare("SELECT name, sql FROM sqlite_master WHERE type='table'").all(); }
catch (e) { console.log('CANNOT_READ_SCHEMA ' + e.message); process.exit(3); }

console.log('DB ' + file);
for (const t of tables) {
  console.log('\nTABLE ' + t.name);
  console.log('  ' + String(t.sql).replace(/\s+/g, ' ').slice(0, 400));
}

for (const t of tables) {
  try {
    const rows = db.prepare('SELECT * FROM "' + t.name + '" ORDER BY rowid DESC LIMIT 4').all();
    console.log('\n== ' + t.name + ' : newest ' + rows.length + ' ==');
    for (const r of rows) {
      const o = {};
      for (const k of Object.keys(r)) {
        let v = r[k];
        if (v === null || v === undefined) v = null;
        else if (v instanceof Uint8Array) v = '<blob ' + v.length + 'B>';
        else if (typeof v === 'string' && v.length > 100) v = v.slice(0, 100) + '...';
        o[k] = v;
      }
      console.log('  ' + JSON.stringify(o));
    }
  } catch (e) { console.log('  (cannot read rows: ' + e.message + ')'); }
}

// What vocabulary exists at all? This is the whole point: whatever words appear here
// are the only ones the guard may echo.
try {
  const cols = db.prepare("SELECT name FROM pragma_table_info('goals')").all();
  console.log('\nCOLUMNS: ' + cols.map((c) => c.name).join(', '));
  for (const c of cols) {
    try {
      const v = db.prepare('SELECT DISTINCT "' + c.name + '" AS v FROM goals LIMIT 12').all();
      const vals = v.map((x) => x.v).filter((x) => x !== null && x !== undefined);
      if (vals.length && vals.length <= 10) console.log('  ' + c.name + ' = ' + JSON.stringify(vals));
    } catch (e) { /* not a simple column */ }
  }
} catch (e) { console.log('(no goals table?) ' + e.message); }
