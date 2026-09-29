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
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createUserMessage } from '@deepseek-ai/dsh-llm';
import { defineTool } from '@deepseek-ai/dsh-tools';

export const name = 'lid-beacon';
export const inject = ['agents', 'typert', 'tools'];

// State paths are resolved, never hardcoded. CODEX_SAVE_DSH_STATE_DIR wins when a
// deployment keeps state elsewhere; otherwise this points at the guard's own
// default state directory inside the repo. A host that guessed a local path would
// be worse than useless, and config.statePath / config.subscribersPath still
// override both below.
const HERE = dirname(fileURLToPath(import.meta.url));
const STATE_DIR = process.env.CODEX_SAVE_DSH_STATE_DIR || join(HERE, '..', '..', 'guard', 'state');
const DEFAULT_STATE = join(STATE_DIR, 'lid.state');
const DEFAULT_SUBS = join(STATE_DIR, 'lid.subscribers.json');

export function apply(ctx, config = {}) {
  const statePath = typeof config.statePath === 'string' ? config.statePath : DEFAULT_STATE;
  const pollMs = Number.isFinite(config.pollMs) ? Number(config.pollMs) : 2000;
  const subsPath = typeof config.subscribersPath === 'string' ? config.subscribersPath : DEFAULT_SUBS;
  // Delivery boundary. 'auto' = steer when the target is mid-turn, queue when idle.
  const mode = typeof config.mode === 'string' ? config.mode : 'auto';

  const log = (level, message) => {
    try { ctx.logger?.[level]?.(`lid-beacon: ${message}`); } catch {}
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
}
