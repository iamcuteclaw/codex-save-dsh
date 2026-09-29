# codex-save-dsh

## 1. What it is

codex-save-dsh is a watchdog for a long-running **local agent host** — in the deployment it was
built for, the DeepSeek Harness (`dsh web`) listening on `127.0.0.1:3080`. It watches the
host process; if the host dies it starts it again; once the host is back it raises the
**agent session** that was watching the problem, by writing a line to a small state file
that a companion plugin turns into a delivered message; and only when that whole path
fails does it hand the problem to a **second agent** (codex), whose own goal store is then
the only thing allowed to declare the situation blocked. It logs one line per second, in a
fixed shape, so the state of the rescue is readable at a glance instead of inferred from
scrollback.

Nothing in the published tree contains a local path, a username, a machine name, or a
session id. The session id and session directory are **inputs**, and the installer refuses
to run without them.

## 2. The three layers, and what each one owns

| Layer | Runs as | Cadence | Owns |
|---|---|---|---|
| **guard** (`guard/DSH-guard.ps1`, driven by `guard/guard-loop.ps1` or the `DSH-guard` task) | `NT AUTHORITY\SYSTEM` | 1 Hz in-process loop, plus a once-a-minute outer task | Detecting the host's absence, restarting it, raising the session, retrying the raise, and the entire log line |
| **starter** (`guard/start-dsh-web.ps1`, run by the `DSH-start-web` task) | the interactive user | on demand, started by the guard | Starting the host **in the user's context**, detached and hidden, then exiting immediately |
| **codex** (an external agent, invoked by the guard only as a last resort) | the interactive user's account | once per exhausted attempt | Actually repairing what the guard cannot; its own `thread_goals.status` is the only source of a blocked/limited verdict |

The guard deliberately does **not** start the host itself. Under SYSTEM the host would
resolve the wrong home directory, `dsh` would not be on PATH, and a SYSTEM-owned host would
then race the user's own next restart for the port. So the guard asks the interactive
user's task to do it, and the process lands in the right context.

## 3. The log language

One line per second, padded so it scans:

```
[HH:mm:ss] LEVEL Yep:[...] Nope:[...] WaitSec=n/s Tryed=nt/min | Event
```

A Warm line may carry one bracketed tail between `LEVEL` and `Yep:` — the last 20
characters of the second agent's live output, so a detached repair job is not a black box:

```
[15:21:07] Silly Yep:[Main,Port] Nope:[Nope] WaitSec=0/s Tryed=0t/min | NaN
[15:21:17] Warm  Yep:[Main,Port] Nope:[Nope] WaitSec=0/s Tryed=0t/min | ModelWait..
[15:22:21] Warm  [codex is editing b] Yep:[Nope] Nope:[Main,Port] WaitSec=63/s Tryed=1t/min | CodexWorking
[15:23:40] FATAL [blocked] Yep:[Nope] Nope:[Main,Port] WaitSec=142/s Tryed=3t/min | CodexplayMC
```

Note the shape: no separator between a bracketed list and the next field, and no colon after
`]`. The four fields are fixed-width so that a column of lines can be scanned vertically.

### Levels

There are exactly **four** level words, and the word *is* the whole status. Only `FATAL` is
all capitals; every other level is capitalised on its first letter only.

| Level | Colour | Means |
|---|---|---|
| `Silly` | blue | Normal: the heartbeat, detections, and every raise that **succeeded** |
| `Warm` | yellow | A raise is **in flight** — starting the host, raising the model, or the second agent working |
| `Error` | orange | That raise **failed**, a retry was spent, or the job had to be handed to the second agent |
| `FATAL` | red | BLOCKED — and this word is the **second agent's own**, read out of its goal store |

### Colour rules

* `Yep` is **always green**; `Nope` is **always dark red** (ANSI 32 and 31).
* The brackets and everything inside them are **never coloured** — the payload is not
  re-inked, so a terminal's own styling cannot be confused with the guard's verdict.
* `TrackLost` is the one event word that carries its own colour, and it is rendered red on
  purpose. It is deliberately not explained further.

### Every event word

| Event | Meaning |
|---|---|
| `NaN` | Idle. Nothing happened on this step. |
| `Node404` | The host process is gone. |
| `NodeBack` | The host came back on its own while the guard was waiting for it. |
| `NodeSwapped` | A restart was detected: the host's pid changed under the guard. |
| `NodeWait..` | Waiting — the port is still held, the host is settling, or the guard is waiting for it to come up. |
| `Paused` | A `MAINTENANCE` marker is present in the state directory. The guard stands down deliberately. |
| `NodeWakey` | The guard triggered the starter task. |
| `StarterBomb` | The starter task does not exist, so nothing can be started. |
| `NodeReborn` | The host came up and the guard is settling before it raises. |
| `TrackLost` | The host was lost again during settling. Rendered red on purpose. |
| `ModelWakey` | The raise line was written to the beacon state file. |
| `ModelWait..` | Awaiting a receipt for the raise. |
| `ModelReciped!` | The receipt was found in the session log — the raise landed. |
| `Modeldead/rty` | The raise did not land; a second marker was written and retried. |
| `Modelburned` | Both raise attempts failed; the pid claim is released. |
| `PhaseReset!` | The state file held an unknown phase; the guard reset itself to IDLE. |
| `Codexslp1` / `Codexslp2` / `Codexslp3` | The first / second / third attempt to hand the job to the second agent started. |
| `Codexfired` | Attempts are exhausted; the guard will not call the second agent again. |
| `CodexWorking` | The second agent reports `active`. |
| `CodexPaused!` | The second agent reports `paused` — level `Error`. |
| `CodexplayMC` | The second agent reports `blocked` — level `FATAL`. |
| `CodexUsed` | The second agent reports `usage_limited` — level `FATAL`. |
| `CodexStuffed` | The second agent reports `budget_limited` — level `FATAL`. |
| `CodexBurned` | The second agent reports `complete` while the host is still down — level `FATAL`. |

When the status reader cannot answer at all, the event renders as `Codex?` followed by the
reader's own word (`Codex?NO_THREAD`, `Codex?NO_ROW`, `Codex?NO_READER`), never as a status
the guard made up.

## 4. Why `FATAL` is trustworthy

`FATAL` is not the guard's opinion. The word in the brackets is read from the second
agent's **own** store — the `thread_goals.status` column of its goals database — through
`codex-status.js`, using the `session id` the agent prints in its own output. That column
is constrained to exactly six words:

```
active   paused   blocked   usage_limited   budget_limited   complete
```

The guard maps those words to levels; it never writes one. A status the guard invented
would be worth nothing, and this design rule exists precisely because a watchdog that
reports its own guesses is worse than one that reports nothing.

## 5. What has actually been observed, and what has not

This section is the honest one. It separates what was **read back from bytes** during
development from what has only ever been **designed and code-reviewed**.

### Proven from bytes

* **The guard survives the host's death as SYSTEM.** The loop kept running when the host it
  was watching did not.
* **The raise is written and lands.** The marker line was written to the beacon file and
  the receipt was then found by reading the session log itself — not by trusting that the
  write "should" have worked.
* **The state file's pid claim prevents a double raise.** The claim is written before the
  guard waits, so a second pass cannot raise the same session twice.
* **The settle-before-raise fix.** The guard waits for the host to settle before it raises,
  and the settle gate was observed holding the raise back during settling.
* **A real 24-second recovery cycle.** Absence detected, starter triggered, host back,
  settle, raise written, receipt found — end to end, in 24 seconds.
* **The SYSTEM-context codex probe.** A SYSTEM-context process was shown to reach the
  second agent and its goal store once `USERPROFILE`/`CODEX_HOME` were pinned.

### Never fired

* **The `Error` and `FATAL` lines themselves.** No observed run ever produced one.
* **The BLOCKED / codex path.** The guard has never actually handed a real failure to the
  second agent; the status-mapping and level code has run only against injected state.
* **The `WaitSec` recompute fix.** The correction that makes the wait come from the state
  just written has not been exercised by a real absence since it was made.
* **The tailpart guard that keeps the `[blocked]` bracket.** The fix that stops a Warm
  branch from wiping a bracket set by the codex-status branch has never been reached by a
  real `FATAL` line.

These unexercised paths are **designed and code-reviewed, but untested.** Treat a first
`Error` or `FATAL` in the field as a code path meeting reality for the first time.

## 6. Install

```powershell
# From the repository root, in PowerShell:
.\install.ps1 -SessionId <SESSION-ID> -SessionDir <SESSION-DIR>
```

`install.ps1` prints every path it will use and the exact two scheduled tasks it will
register, then asks for `y/N` before it creates or registers anything. It creates the state
directory, writes a substituted copy of the rescue prompt into it, and registers:

* **`DSH-guard`** — `NT AUTHORITY\SYSTEM`, every minute, one guard step per run.
* **`DSH-start-web`** — the interactive user, **on demand only**, no trigger; the guard
  starts it with `Start-ScheduledTask`.

**`-SessionId` must be supplied explicitly, every time.** There is no default, and there
will not be one. A watchdog that guessed someone's session id would raise the wrong
conversation at the worst possible moment; silently raising the wrong session is worse than
not raising one at all. `-SessionDir` is equally required — it is where the receipt is read
back from, and it cannot be inferred from the id alone.

* Running `install.ps1` as SYSTEM: pass `-UserHome` with the **interactive** user's profile
  path. The script refuses to proceed if `-UserHome` resolves to the SYSTEM profile, because
  the guard would then read the wrong codex config, auth and goal store.
* The optional 1 Hz loop (`guard/guard-loop.ps1`) is for tight watching and is meant to be
  launched as SYSTEM in the same way. It forwards `-StateDir`, `-UserHome`, `-SessionId` and
  `-SessionDir` to the guard verbatim.
* The companion plugin under `lid-beacon/` turns the beacon state file into the delivered
  notice. Its state directory defaults to the guard's state directory, or to
  `CODEX_SAVE_DSH_STATE_DIR` when that is set; `config.statePath` and `config.subscribersPath`
  override both.

## 7. Limitations

* **If the model-router proxy the second agent depends on is dead, there is no rescue.**
  The guard can start a host and raise a session; it cannot make the network or a proxy
  answer.
* **A host that cannot boot at all needs a human.** The guard will retry, spend its
  attempts, and then say so — it will not keep hammering forever.
* **The guard cannot draw any UI on the user's desktop.** This is deliberate: a watchdog
  that opens windows in the user's face, and can be closed by the user, is not a watchdog.
  Its whole visible surface is the log line and the raised session.
* The second agent's statuses are the only statuses it will report. If the second agent's
  store is unreadable, the guard says it cannot tell you (`Codex?CANNOT_OPEN`), not
  "blocked".

## 8. Design rules the code obeys

* **Prefer behavioural checks over textual ones.** "The port is listening and the process
  matches" is the event; "a command returned" or "a version printed" is only a symptom.
* **Ask for a receipt instead of believing yourself.** Writing a line and the line landing
  are different events, so the guard writes a per-raise marker and then reads the session
  log back to confirm it arrived.
* **Claim before you wait.** The pid claim is written before the guard settles, so a second
  pass cannot raise the same session a second time.
* **Never invent a status a tool did not report.** A blocked/limited verdict is echoed from
  the second agent's own goal store, word for word.
* **If a mechanism can fail silently at the moment it is needed, it is not a mechanism.**

## 9. License

MIT. See [LICENSE](LICENSE). The copyright holder is a placeholder to be filled in.
