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
* **Two complete recovery cycles, timed from the log.** 24 s and 22 s, both end to end:
  absence detected, starter triggered, host back, settle, raise written, receipt found. The
  second cycle also shows the process returning before the port does, so the `Yep` list is
  visibly `[Main]` for a second before it becomes `[Main,Port]`.
* **The `WaitSec` recompute fix.** Written, then exercised by a real absence. The same field
  read `1057` under the old code -- a stale timestamp borrowed from the previous phase -- and
  `0` under the new one, counting up from there.
* **The SYSTEM-context codex probe.** A SYSTEM-context process was shown to reach the
  second agent and its goal store once `USERPROFILE`/`CODEX_HOME` were pinned.

### Never fired

* **`FATAL` itself.** No observed run has ever produced one. Its sibling `Error` has now
  fired once, so the two are no longer the same story -- see below.
* **The BLOCKED / codex path.** The guard has never actually handed a real failure to the
  second agent; the status-mapping and level code has run only against injected state.
* **The tailpart guard that keeps the `[blocked]` bracket.** The fix that stops a Warm
  branch from wiping a bracket set by the codex-status branch has never been reached by a
  real `FATAL` line.

These unexercised paths are **designed and code-reviewed, but untested.** Treat a first
`FATAL` in the field as a code path meeting reality for the first time.

### And one line that has fired exactly once, kept because of how

```
[16:38:20] Error Yep:[Nope] Nope:[Main,Port] WaitSec=0/s Tryed=0t/min | TrackLost
```

`Error` was listed above as never having occurred. It occurred at 16:38:20, and what
produced it was not a broken host but a **double trigger**: two appliers started the host in
the same second, the second process lost the port race and exited on its own, and for a few
seconds the guard lost track of which process it was actually watching. It re-found the real
one, the host came back, and the raise landed 24 seconds after the trigger.

Two consequences, both measured:

* the `Error` line is no longer a virgin code path; and
* **the double trigger is no longer described as harmless.** The comment in `guard-loop.ps1`
  reads "a double trigger is harmless: the second dsh web cannot bind 3080 and exits on its
  own". The second half of that is true -- the losing process did exit -- but it cost a real
  process launch and an `Error`, and for a few seconds the guard was watching something that
  was not its target. Recoverable is not the same as harmless, and this file should say what
  it means. A start claim, in the same spirit as the pid claim that already protects the
  raise, would close it. That fix is not in this release.

### Measured limits, and what they cost

These were all observed directly tonight. They are written down because each one had
already caused a wrong conclusion, and a limit that is not written down gets rediscovered.

* **The wake has NO volume readback.** `guard/wake.ps1` injects volume-up key events and
  reports, in `wake.log`, how many it injected and by which method — never that the volume
  actually changed. Nothing in this tree reads the master level back from the context the
  wake runs in, so the script does not claim a level: the only instrument is the human's
  ears, and the only receipt that a human *saw* the box is the box being dismissed. A wake
  that returns success means "the keys were sent", not "he is awake".
* **SendKeys and `keybd_event` are the same keys through different doors.** Measured the
  same night: `WScript.Shell.SendKeys` did **nothing** when the script was launched by a
  scheduled task, and reported success while doing it — a task process has no foreground
  window, and SendKeys delivers to the *active application*. `keybd_event` injects into the
  system input stream instead, which needs no focus. Both send `VK_VOLUME_UP`; only one
  arrives. This is why `wake.ps1` calls `keybd_event` from an `Add-Type` block rather than
  reaching for the convenient one-liner.
* **A search that expects whitespace around the level word finds almost nothing.** The level
  word is glued to an ANSI escape: a line reads `[33mWarm`, with no whitespace between the
  escape and the word. Any test requiring a space on both sides therefore measures only the
  handful of lines that carry no colour at all. Measured on 2026-09-29: a spaced search for
  `Silly` returned **12** where a plain substring search returned **6148**. Two independent
  measurers, using two different instruments, both landed on that same 12 and both reported
  the coloured levels as never having fired, on a log where they fire constantly. Anyone who
  greps this log must search for the substring.
  (This paragraph first blamed a `\bWarm\b` word-boundary search. The auditor's instrument
  was a plain `' Warm '` SimpleMatch. A correction about someone else's method is a claim
  like any other, and that one was wrong -- which is itself the point.)
  A third demand this log makes: it grows once a second, so two honest counts taken minutes
  apart are counts of two different populations. Record the timestamp with the number, or the
  number means nothing.
* **The permission presets are not a dial.** `read-only` asks for every tool call;
  `danger-full-access` never asks. Measured side by side on the same host, and they are the
  two ends of one setting rather than two points on a scale: there is no preset that asks
  for the dangerous calls only. The choice is therefore a property of the whole session,
  made before the work starts, not a decision per action.
  Related, and measured on the human side: **the wake's own box was mistaken by the operator
  for a permission prompt.** He read a TopMost modal dialog with an `OK` button as something
  asking his approval and waited for it. It asks for nothing. The box now says so in as many
  words, but the misreading is the reason that sentence exists, and it is the reason the
  wake is documented here as a *notice* rather than a request.
* **A plugin render must not return an image.** Measured 2026-09-29 17:02-17:04: a
  `see_screen` tool result carrying an inline base64 PNG -- 114,782 characters -- was followed
  by every request from that session failing as `TRANSPORT` in about 35 ms, without ever
  leaving the machine. What was stored does **not** say why: no HTTP status, no cause. So the
  mechanism is not knowable from the record, and this file does not pretend otherwise. What
  changed is the shape: the tool now returns text plus a path, using the placeholder form the
  harness itself writes when it stores an image, and `read_image` does the seeing. Anyone
  writing a plugin tool that wants to hand back a picture should read this paragraph first --
  the built-in `read_image` can do it precisely because it is not a plugin.
  (That placeholder is *modelled on* the harness's, not byte-identical to it: the harness
  emits a JSON-escaped attachment-store path it can guarantee is readable, while this is a
  bare disk path -- fine under `danger-full-access`, possibly refused under a narrower
  sandbox.)

## 6. Install

```powershell
# From the repository root, in PowerShell:
.\install.ps1 -SessionId <SESSION-ID> -SessionDir <SESSION-DIR>
```

`install.ps1` prints every path it will use and the exact three scheduled tasks it will
register, then asks for `y/N` before it creates or registers anything. The printed plan and
the registration are built from the same variables, so the plan cannot describe a task the
script does not go on to register — a defect of exactly that kind (the starter's `RunLevel`
shown in the plan but not applied to the principal) lived in this file and was fixed. It
creates the state directory, writes a substituted copy of the rescue prompt into it, and
registers:

* **`DSH-guard`** — `NT AUTHORITY\SYSTEM`, **at startup and then every minute**, one guard
  step per run. Two triggers, deliberately: a reboot kills `guard-loop.ps1` and
  `lid-loop.ps1`, because they are plain processes with nothing to restart them, while the
  task itself survives the reboot. The startup trigger is what makes that recovery take
  seconds instead of up to a minute — one minute being the finest interval Task Scheduler
  offers for a repetition. The guard's first pass after boot is what brings both loops back.
* **`DSH-start-web`** — the interactive user, **on demand only**, no trigger; the guard
  starts it with `Start-ScheduledTask`.
* **`DSH-wake`** — the interactive user, **on demand only**, no trigger; the `wake_user`
  agent tool starts it with `Start-ScheduledTask`. It must run in the interactive session,
  because a session-0 process has no desktop and no audio session, and its `keybd_event`
  injection would then reach nobody. It is deliberately bound to no timer, no log level and
  no phase: a wake is destructive to a person wearing headphones, so the trigger is an
  agent's decision and nothing else.

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
  `-SessionDir` to the guard verbatim. Every 10 s it also checks the lid sampler is alive
  and revives it if it is not, using the same two tests the guard uses.
* The companion plugin under `lid-beacon/` turns the beacon state file into the delivered
  notice, and registers **four** agent tools: `lid_beacon_target` (subscribe or
  unsubscribe *this* conversation from lid notices; nothing else can subscribe it),
  `lid_closed` (read-only: is the panel off right now, how old is that reading, and is
  anything sampling — a `CLOSED` reading means **the human is absent**, so a question asked
  then waits forever and must not be asked), `wake_user` (loud, requires a `reason`,
  refuses without one, never automatic), and `see_screen` (capture the whole desktop and
  return it as an image; it captures **everything** currently on screen — including
  anything private that happens to be visible — so it is called for a reason and never on
  a timer, and it must run in the interactive session, because the same call from session
  0 comes back black). Its state directory defaults to the guard's state
  directory, or to `CODEX_SAVE_DSH_STATE_DIR` when that is set; `config.statePath` and
  `config.subscribersPath` override both. Registration failures are also appended to
  `lid-beacon.err` beside the state file, because a tool that silently fails to register is
  indistinguishable from a tool that was never needed.

## 7. The rest of the guard tree

Two scripts in `guard/` are for the operator rather than for the loop, and both were
previously undocumented:

* **`guard/kill-dsh-web.ps1` — the deliberately dangerous one.** It stops the watched host
  on purpose, so the whole self-heal chain has to bring it back and raise the session, which
  is how the rescue path gets tested end to end instead of being trusted. It matches its
  target by command line rather than by a pid remembered from an earlier turn, and it sleeps
  first (`-DelaySeconds`, 30 by default) so the message announcing the test is delivered
  before the harness dies — killing the host kills the tree the announcing turn runs in. It
  writes to `danger.log`. **Running it kills `dsh web`.** That is its entire purpose, and an
  operator has to be able to see that before running it, not after.
* **`guard/system-probe.ps1`** — proves a SYSTEM-context process can actually reach the
  second agent and its goal store once `USERPROFILE` and `CODEX_HOME` are pinned. It is the
  check that stands behind the "the codex path works under SYSTEM" claim, and it writes its
  result to `system-probe.log` because PsExec does not return stdout. The thread ids it
  re-reads are inputs (`-BlockedThreadId`, `-PausedThreadId`), never baked in.
* **`guard/see-screen.ps1`** — the one script in `guard/` that belongs to neither the loop
  nor the operator: the `see_screen` tool runs it. It captures the whole virtual desktop to
  a PNG and prints exactly one parseable line, `<width>x<height>:<bytes>`. **It must run in
  the interactive session** — the same code from session 0 (SYSTEM) comes back a black
  frame — and that is the whole reason `see_screen` lives in the plugin, which runs in the
  user's session, rather than in the guard. The PNG is written into the **state** directory,
  never beside the script: a picture of the desktop is precisely the kind of file the
  published tree must not be able to commit.

## 8. Limitations

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

## 9. Design rules the code obeys

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

## 10. License

MIT. See [LICENSE](LICENSE). Copyright (c) 2026 iamcuteclaw.

## 11. Main developer

**101.0000% DeepSeek.**

The extra 1.0000% is DeepSeek too. Every line in this repository -- including the two
failed publish attempts and the corrections that followed them -- was written by an agent.

