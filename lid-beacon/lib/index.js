// dsh-lid-beacon — when the laptop lid closes (internal panel powers off),
// deliver one notice line to every conversation that ASKED to be told.
//
// SELF-REQUESTED ONLY. There is deliberately NO config key that can subscribe a
// conversation: config is deployment, and deployment must not be able to turn
// someone's conversation into plumbing. The only way in is the tool, called by
// that conversation itself — and the set is persisted so the opt-in survives a
// restart.
//
// Every primitive below is copied from code already proven on this machine:
//   live agent      ctx.agents.get(id)                              (dsh-bridge)
//   resume offline  ctx.typert.lookups.get('agent').resolve(id)     (dsh-bridge)
//   delivery        agent.followup(createUserMessage({...}))        (dsh-bridge)
//   source kind     producer-owned "plugin:<name>" — NOT "plugin", which
//                   format v4 explicitly rejects                    (v3-to-v4 rule)
import { existsSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { execFile } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createUserMessage } from '@deepseek-ai/dsh-llm';
import { defineTool } from '@deepseek-ai/dsh-tools';

export const name = 'lid-beacon';
export const inject = ['agents', 'typert', 'tools'];

// Every path is derived, never hardcoded. The published tree must contain no local path,
// no username and no machine name, so the guard's own defaults are built from this file's
// location and a deployment that keeps state elsewhere says so with one variable.
//
//   <repo>/lid-beacon/lib/index.js  ->  <repo>/guard          the guard scripts
//                                   ->  <repo>/guard/state    the state they share
//
// CODEX_SAVE_DSH_STATE_DIR wins when a deployment keeps state outside the tree.
const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPTS_DIR = join(HERE, '..', '..', 'guard');
const REPO_STATE = join(SCRIPTS_DIR, 'state');
const STATE_DIR = process.env.CODEX_SAVE_DSH_STATE_DIR || REPO_STATE;
const DEFAULT_STATE = join(STATE_DIR, 'lid.state');
const DEFAULT_SUBS = join(STATE_DIR, 'lid.subscribers.json');

export function apply(ctx, config = {}) {
  const statePath = typeof config.statePath === 'string' ? config.statePath : DEFAULT_STATE;
  const pollMs = Number.isFinite(config.pollMs) ? Number(config.pollMs) : 2000;
  const subsPath = typeof config.subscribersPath === 'string' ? config.subscribersPath : DEFAULT_SUBS;
  // Delivery boundary. 'auto' = steer when the target is mid-turn, queue when idle.
  const mode = typeof config.mode === 'string' ? config.mode : 'auto';

  // Warnings go to a FILE as well as to the host logger. Measured: a failed tool
  // registration logged through ctx.logger left no trace anyone could find, and the only
  // symptom was a tool missing from the tool list at the moment it was needed -- a wake
  // tool that could never have fired, with nothing anywhere saying why. A warning that
  // cannot be found later is not a warning.
  const errFile = (() => { try { return join(dirname(statePath), 'lid-beacon.err'); } catch { return null; } })();
  const log = (level, message) => {
    try { ctx.logger?.[level]?.(`lid-beacon: ${message}`); } catch {}
    if (level === 'warn' && errFile) {
      // append via flag, so no extra import is needed and a failure here cannot throw
      try { writeFileSync(errFile, `[${new Date().toISOString()}] ${message}\n`, { flag: 'a' }); } catch {}
    }
  };
  const readState = () => {
    try { return existsSync(statePath) ? readFileSync(statePath, 'utf8').trim() : null; }
    catch { return null; }
  };

  // ---- self-requested subscriber set, persisted across restarts ----
  const targets = new Set();
  try {
    if (existsSync(subsPath)) {
      const parsed = JSON.parse(readFileSync(subsPath, 'utf8'));
      if (Array.isArray(parsed)) for (const id of parsed) if (typeof id === 'string') targets.add(id);
    }
  } catch (error) {
    log('warn', `could not read subscribers: ${error?.message ?? error}`);
  }
  const persist = () => {
    try { writeFileSync(subsPath, JSON.stringify([...targets], null, 2)); }
    catch (error) { log('warn', `could not persist subscribers: ${error?.message ?? error}`); }
  };

  let last = readState();

  async function agentFor(id) {
    const live = ctx.agents.get(id);
    if (live) return live;
    const provider = ctx.typert?.lookups?.get?.('agent');
    if (!provider) throw new Error('DSH host agent resolver is unavailable');
    const resolved = await provider.resolve(id);
    if (!resolved) throw new Error(`session "${id}" could not be resumed`);
    return resolved;
  }

  async function broadcast(line) {
    if (targets.size === 0) { log('info', `state changed -> "${line}" but nobody asked to be told`); return; }
    for (const id of [...targets]) {
      try {
        const agent = await agentFor(id);
        const message = createUserMessage({
          content: [{ type: 'text', text: `[lid-beacon] ${line}` }],
          source: { kind: 'plugin:lid-beacon', form: 'notice' },
        });
        // A queued notice waits for the target's WHOLE turn to end — which is
        // exactly when a notice stops being useful. Steering reaches it at the
        // next step boundary instead, without cutting the running response. An
        // idle target is better served by a turn of its own: steering an idle
        // driver claims the message without opening a boundary, so idle keeps
        // queue. (Same rule the shipped peer plugin and the Harness's own
        // agent-team mailbox use.) 'inject' adds context without waking anything
        // at all — the zero-turn-cost option.
        const running = agent.status === 'running';
        const use = mode === 'auto' ? (running ? 'steer' : 'queue') : mode;
        if (use === 'steer') agent.steer(message);
        else if (use === 'inject') agent.inject(message);
        else agent.followup(message);
        log('info', `delivered to ${id} via ${use}`);
      } catch (error) {
        log('warn', `delivery to ${id} failed: ${error?.message ?? error}`);
      }
    }
  }

  function tick() {
    const now = readState();
    if (now === last) return;
    const previous = last;
    last = now;
    void broadcast(`${now}  (previous: ${previous ?? 'unknown'})`);
  }

  try {
    ctx.effect(() => {
      const timer = setInterval(tick, pollMs);
      log('info', `armed on ${statePath} every ${pollMs} ms; ${targets.size} self-requested subscriber(s)`);
      return () => clearInterval(timer);
    }, 'lid-beacon poll');
  } catch (error) {
    log('warn', `could not arm the poll: ${error?.message ?? error}`);
  }

  try {
    ctx.tools.register(defineTool({
      name: 'lid_beacon_target',
      description: 'Ask to be told, or stop being told, about lid/screen transitions. This subscribes THIS conversation only, and only because it asked; nothing and nobody else can subscribe it. The beacon fires when the internal panel powers off (a closed lid, or an idle screen blank — it cannot tell them apart) and delivers one notice line. Each notice costs a full turn of this conversation\'s context.',
      parameters: { action: { type: 'string', required: true, description: 'add | remove | list' } },
      output: {
        schema: { type: 'object', additionalProperties: false, properties: { targets: { type: 'array', items: { type: 'string' }, required: true } } },
        render: (_args, value) => [{ type: 'text', text: 'lid-beacon subscribers: ' + (value.targets.length ? value.targets.join(', ') : '(none)') }],
      },
      execute(args, exec) {
        const self = exec?.agent ? String(exec.agent.session.id) : undefined;
        if (args.action === 'add') {
          if (!self) throw new Error('lid_beacon_target requires a calling agent');
          targets.add(self);
        } else if (args.action === 'remove') {
          if (self) targets.delete(self);
        } else if (args.action !== 'list') {
          throw new Error(`unknown action "${args.action}"`);
        }
        if (args.action === 'add' || args.action === 'remove') persist();
        return Promise.resolve({ targets: [...targets] });
      },
    }));
  } catch (error) {
    log('warn', `could not register lid_beacon_target: ${error?.message ?? error}`);
  }

  // Read-only. It answers "is the panel off right now", and — just as important — "how
  // old is that answer" and "is anything even sampling". A stale reading presented as a
  // live one is worse than no reading: the whole point of this tool is to be trusted.
  try {
    ctx.tools.register(defineTool({
      name: 'lid_closed',
      description: 'Read whether the internal panel is currently powered off — a closed lid, or an idle screen blank; this signal cannot tell those apart. Read-only: it never triggers a sample and never writes the state file. It also reports the age of the reading and whether a sampler is running, so a stale reading cannot be mistaken for a live one. WHEN THIS READS CLOSED, TREAT THE HUMAN AS ABSENT: nobody is at the keyboard, so anything that waits for their confirmation waits forever — a question asked at a closed lid dies unanswered, and you will be talking to a blank B-side. Do not ask; decide, act, and record what you did. OPEN means he is here, and nothing more than that.',
      parameters: {},
      output: {
        schema: {
          type: 'object',
          additionalProperties: false,
          properties: {
            known: { type: 'boolean', required: true },
            closed: { type: 'boolean', required: true },
            state_word: { type: 'string', required: true },
            since: { type: 'string', required: true },
            age_seconds: { type: 'number', required: true },
            sampling: { type: 'boolean', required: true },
          },
        },
        render: (_args, value) => [{
          type: 'text',
          text: value.known
            ? `lid state: ${value.state_word} (closed=${value.closed}), since ${value.since}, reading age ${value.age_seconds}s, sampler running=${value.sampling}`
            : 'lid state: unknown — no state file, and nothing sampling',
        }],
      },
      async execute() {
        const raw = readState();
        if (!raw) {
          return { known: false, closed: false, state_word: 'unknown', since: '', age_seconds: -1, sampling: false };
        }
        const parts = raw.split(/\s+/);
        const word = (parts[0] || '').toUpperCase();
        const since = parts.slice(1, 3).join(' ');
        let age = -1;
        try { age = Math.round((Date.now() - statSync(statePath).mtimeMs) / 1000); } catch {}

        // TWO tests, because either one alone has a blind spot -- the same lesson the guard's
        // own loop check had to learn. A freshness window alone calls a sampler that was
        // killed five seconds ago "alive" for another fifteen. A process count alone cannot
        // see a loop that is still on the process list but no longer passing.
        let sampling = false;
        try { sampling = (Date.now() - statSync(join(dirname(statePath), 'lid-loop.log')).mtimeMs) < 20000; } catch {}
        if (sampling) {
          // Ask the process table only when freshness says alive: that is the answer capable
          // of lying. And the probe must exclude ITSELF -- its own command line contains the
          // string it searches for, so it counted one extra process and would have reported
          // ALIVE with no sampler running at all. Measured: 2 with one real loop, 1 with none.
          try {
            const probe = "(Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -like '*lid-loop.ps1*' -and $_.ProcessId -ne $PID }).Count";
            const out = await new Promise((resolve) => {
              execFile('powershell.exe', ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-Command', probe], { windowsHide: true }, (err, stdout) => resolve(String(stdout || '').trim()));
            });
            const n = Number(out);
            // An unreadable query must not turn "alive" into "dead": keep the freshness
            // answer rather than assert something the tool cannot see.
            if (Number.isFinite(n)) { sampling = n > 0; }
          } catch { /* keep the freshness answer */ }
        }

        return {
          known: true,
          closed: word === 'CLOSED',
          state_word: word || 'unknown',
          since,
          age_seconds: age,
          sampling,
        };
      },
    }));
  } catch (error) {
    log('warn', `could not register lid_closed: ${error?.message ?? error}`);
  }

  // The wake. LOUD on purpose, never automatic, and it must carry a reason.
  try {
    ctx.tools.register(defineTool({
      name: 'wake_user',
      description: 'Wake the human. LOUD by design: it takes the WINDOWS master volume to 100%, because he wears headphones and a quiet alarm does not wake him. It requires a reason, it never touches the media player, and it is never automatic — nothing in the host can fire it. Call it only when you have decided a human is genuinely needed and they will not notice any other way. It has no volume readback: it can only report which method injected how many key events, never that the volume changed, so the human\'s ears are the only instrument.',
      parameters: {
        reason: { type: 'string', required: true, description: 'Why the human is needed. Required: the wake is destructive to their ears, so it must carry a reason. This text is shown on the box they will see.' },
        context: { type: 'string', description: 'Optional extra detail for the box: which session, which file to read, what to do next.' },
      },
      output: {
        schema: {
          type: 'object',
          additionalProperties: false,
          properties: {
            triggered: { type: 'boolean', required: true },
            task_state: { type: 'string', required: true },
            last_wake_log: { type: 'string', required: true },
          },
        },
        render: (_args, value) => [{ type: 'text', text: `wake_user: triggered=${value.triggered}, task=${value.task_state}, wake.log last: ${value.last_wake_log || '(empty)'}` }],
      },
      async execute(args) {
        const reason = typeof args?.reason === 'string' ? args.reason.trim() : '';
        if (!reason) {
          throw new Error('wake_user requires a reason. It takes the master volume to 100% on someone wearing headphones, so a wake that cannot say why must not be sent.');
        }
        const run = (cmdArgs) => new Promise((resolve) => {
          execFile('powershell.exe', cmdArgs, { windowsHide: true }, (err, stdout, stderr) => {
            resolve({ err, stdout: String(stdout || ''), stderr: String(stderr || '') });
          });
        });
        const ps = (command) => run(['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-Command', command]);

        // A scheduled task cannot receive arguments, so the reason travels by file:
        // wake.ps1 reads wake.reason and puts it on the box the human actually sees.
        // It is written to BOTH candidate directories on purpose. wake.ps1 looks beside
        // itself (a scheduled task passes no state directory), while a deployment that
        // moved state with CODEX_SAVE_DSH_STATE_DIR keeps it under that directory; writing
        // once to each means the file is found whichever layout is in force, and wake.ps1
        // deletes the copy it consumed.
        const text = reason + (args.context ? '\n\n' + String(args.context) : '');
        let wrote = false;
        for (const dir of [dirname(statePath), SCRIPTS_DIR]) {
          try { writeFileSync(join(dir, 'wake.reason'), text, 'utf8'); wrote = true; } catch {}
        }
        if (!wrote) {
          throw new Error('could not write wake.reason: no writable directory for the wake task to read');
        }

        const start = await ps("Start-ScheduledTask -TaskName 'DSH-wake'");
        await new Promise((r) => setTimeout(r, 1500));
        const state = await ps("(Get-ScheduledTask -TaskName 'DSH-wake').State");
        let last = '';
        try {
          const lines = readFileSync(join(SCRIPTS_DIR, 'wake.log'), 'utf8').trim().split('\n');
          last = lines[lines.length - 1] || '';
        } catch {}
        log('info', `wake_user triggered (reason: ${reason}); task=${state.stdout.trim()}; start=${start.err ? 'error' : 'ok'}`);
        return { triggered: !start.err, task_state: state.stdout.trim() || 'unknown', last_wake_log: last };
      },
    }));
  } catch (error) {
    log('warn', `could not register wake_user: ${error?.message ?? error}`);
  }

  // Eyes. dsh runs in the user's interactive session, so a capture taken from here has
  // content; the identical call from the guard (session 0) comes back black -- which is
  // exactly why this belongs to the plugin and not to the guard.
  //
  // The script is looked for beside the guard scripts first (where this repo ships it) and
  // then beside the state file (where a deployment that copied it there keeps it). The PNG
  // goes to the STATE directory on purpose: it is a picture of whatever happened to be on
  // screen, and the state directory is the one place the published tree already ignores.
  //
  // DO NOT RETURN THE IMAGE FROM A PLUGIN RENDER. An earlier version of this tool built an
  // image block -- { type: 'image', source: { type: 'base64', data: '...', media_type:
  // 'image/png' } } -- and returned it from here. Measured 2026-09-29 17:02-17:04: after
  // such a result, EVERY request from that session failed instantly, code TRANSPORT, about
  // 35 ms, the request never left the machine, on a capture of 114,782 base64 characters.
  // The session was repaired out of band by removing the image from its context again, and
  // it was NOT the harness that did that. What the stored failure does not contain is any
  // HTTP status and any cause, so the mechanism is not knowable from what was kept -- this
  // records the shape that preceded the failure, and the shape used instead.
  try {
    ctx.tools.register(defineTool({
      name: 'see_screen',
      description: 'Look at the desktop: capture the whole screen to a PNG and return its PATH, not the picture. It does not hand you an image; read the file it names with the read_image tool. Use it when a picture is the only way to know what happened -- a dialog nobody clicked, a window something landed behind, a crash. It captures EVERYTHING currently on screen, including anything private that happens to be visible, so call it when you have a reason, not on a timer. It must run in the interactive session: from session 0 the frame comes back black.',
      parameters: {},
      output: {
        schema: {
          type: 'object',
          additionalProperties: false,
          properties: {
            captured: { type: 'boolean', required: true },
            width: { type: 'number', required: true },
            height: { type: 'number', required: true },
            bytes: { type: 'number', required: true },
            path: { type: 'string', required: true },
            error: { type: 'string', required: true },
          },
        },
        // Text and a path. The reason, and what is NOT known about it, are in the comment
        // above this registration.
        render: (_args, value) => {
          if (!value.captured) {
            return [{ type: 'text', text: `see_screen: capture failed (${value.error || 'no detail'})` }];
          }
          // MODELLED ON the placeholder the harness writes when it stores an image -- not
          // byte-identical to it. The harness emits JSON.stringify of an attachment-store
          // path, which escapes backslashes, and it can guarantee that path is readable. This
          // is a bare disk path: fine under danger-full-access, and possibly refused by
          // read_image under a narrower sandbox. Stated rather than promised away.
          return [{
            type: 'text',
            text: `[Image: "${value.path}"; image/png; ${value.width}x${value.height}. Use read_image to view it.]`
              + ` (see_screen; ${value.bytes} bytes)`,
          }];
        },
      },
      async execute() {
        const stateDir = dirname(statePath);
        const shot = join(stateDir, 'screen.png');
        const script = [
          join(SCRIPTS_DIR, 'see-screen.ps1'),
          join(stateDir, 'see-screen.ps1'),
        ].find((candidate) => existsSync(candidate));
        const empty = { captured: false, width: 0, height: 0, bytes: 0, path: '', error: '' };
        if (!script) {
          return { ...empty, error: 'see-screen.ps1 not found beside the guard scripts or the state file' };
        }
        const run = (cmdArgs) => new Promise((resolve) => {
          execFile('powershell.exe', cmdArgs, { windowsHide: true }, (err, stdout, stderr) => {
            resolve({ err, stdout: String(stdout || '').trim(), stderr: String(stderr || '').trim() });
          });
        });
        try {
          const r = await run(['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', script, '-Out', shot]);
          if (r.err) {
            log('warn', 'see_screen capture failed: ' + (r.stderr || r.err.message));
            return { ...empty, error: (r.stderr || r.err.message).slice(0, 300) };
          }
          const m = /(\d+)x(\d+):(\d+)/.exec(r.stdout);
          if (!m) { return { ...empty, error: 'unexpected capture output: ' + r.stdout.slice(0, 200) }; }
          log('info', `see_screen: ${m[1]}x${m[2]}, ${m[3]} bytes -> ${shot}`);
          return { captured: true, width: Number(m[1]), height: Number(m[2]), bytes: Number(m[3]), path: shot, error: '' };
        } catch (error) {
          return { ...empty, error: String(error?.message ?? error).slice(0, 300) };
        }
      },
    }));
  } catch (error) {
    log('warn', `could not register see_screen: ${error?.message ?? error}`);
  }
}
