// check-raise.js -- did the beacon line we wrote actually produce a notice?
//
// The guard writes lid.state; the plugin turns that into a delivered message.
// "Wrote the line" and "the message landed" are DIFFERENT events, and tonight they
// diverged: the plugin seeds `last = readState()` at boot (index.js:56), so a line
// written before its first poll becomes its baseline and never fires.
//
// So the guard asks for a receipt instead of believing itself. The marker carries a
// per-raise token (guard-raised-<epoch>) so an earlier raise cannot fake this one.
//
// usage: node check-raise.js <session-dir> <needle>
// exit 0 = found, 1 = not found, 3 = could not read the log
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const dir = process.argv[2];
const needle = process.argv[3] || 'guard-raised';
if (!dir) { console.log('NO_DIR'); process.exit(3); }

const file = path.join(dir, 'session.v4.jsonl.zstd');
let buf;
try { buf = fs.readFileSync(file); } catch (e) { console.log('NO_LOG'); process.exit(3); }

// The log is a concatenation of independent zstd frames.
const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);
const offs = [];
let i = 0;
for (;;) { const k = buf.indexOf(MAGIC, i); if (k < 0) break; offs.push(k); i = k + 4; }
offs.push(buf.length);

let text = '';
for (let j = 0; j < offs.length - 1; j++) {
  try { text += zlib.zstdDecompressSync(buf.subarray(offs[j], offs[j + 1])).toString('utf8'); } catch (e) { /* skip */ }
}

const hits = text.split('\n').filter((l) => l.includes(needle)).length;
console.log(hits > 0 ? ('FOUND ' + hits) : 'NOT_FOUND');
process.exit(hits > 0 ? 0 : 1);
