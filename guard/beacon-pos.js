// beacon-pos.js -- read MY OWN bytes to answer the P2b question:
//   does the [lid-beacon] message sit BEFORE the turn/end of the turn that was
//   in progress (=> steer), or does it open a new turn (=> queue)?
//
// Decisive, not impressionistic: we print the event neighbourhood around the
// beacon message so the enclosing turn boundaries are visible in the same view.
//
// usage: node beacon-pos.js <session-dir>
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const dir = process.argv[2];
if (!dir) { console.error('usage: node beacon-pos.js <session-dir>'); process.exit(1); }
const file = path.join(dir, 'session.v4.jsonl.zstd');
const buf = fs.readFileSync(file);

// The log is a concatenation of independent zstd frames; each frame starts with
// the 4-byte magic. Decompress frame by frame (a truncated tail must not kill us).
const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);
const offs = [];
let i = 0;
for (;;) {
  const k = buf.indexOf(MAGIC, i);
  if (k < 0) break;
  offs.push(k);
  i = k + 4;
}
offs.push(buf.length);

let text = '';
let frames = 0, badFrames = 0;
for (let j = 0; j < offs.length - 1; j++) {
  const frame = buf.subarray(offs[j], offs[j + 1]);
  try { text += zlib.zstdDecompressSync(frame).toString('utf8'); frames++; }
  catch (e) { badFrames++; }
}

const raw = text.split('\n').filter((l) => l.trim().length);
console.log(`file      : ${file}`);
console.log(`frames    : ${frames} ok, ${badFrames} unreadable`);
console.log(`events    : ${raw.length}`);

const evs = [];
for (const ln of raw) {
  try { evs.push(JSON.parse(ln)); } catch (e) { /* skip */ }
}

const kindOf = (e) => e.type || e.kind || e.event || '?';
const timeOf = (e) => (e.t ? new Date(e.t).toISOString().substr(11, 12) : '');

// every event that mentions the beacon
const hits = [];
evs.forEach((e, idx) => { if (JSON.stringify(e).includes('lid-beacon')) hits.push(idx); });
console.log(`lid-beacon occurrences: ${hits.length}`);

const show = (from, to, title) => {
  console.log(`\n=== ${title} ===`);
  for (let k = Math.max(0, from); k < Math.min(evs.length, to); k++) {
    const e = evs[k];
    const s = JSON.stringify(e);
    let extra = '';
    if (s.includes('lid-beacon')) {
      const m = s.match(/\[lid-beacon\][^"\\]*/);
      extra = '   <<< BEACON ' + (m ? m[0] : '');
    }
    if (e.source && e.source.kind) extra += `   [source=${e.source.kind}]`;
    console.log(`${String(e.seq ?? k).padStart(6)}  ${timeOf(e)}  ${kindOf(e)}${extra}`);
  }
};

if (hits.length) {
  const last = hits[hits.length - 1];
  show(last - 14, last + 8, `neighbourhood of the LAST beacon event (index ${last})`);
} else {
  console.log('\n(no beacon event found -- the notice has not been persisted yet)');
}

show(evs.length - 12, evs.length, 'tail of the log');
