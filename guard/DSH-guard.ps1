# DSH-guard.ps1 -- ONE STEP, then exit. guard-loop.ps1 calls it once per second.
#
# A STATE MACHINE, not a straight-through script, because the caller runs at 1 Hz and
# the phases have durations (settle ~10 s, receipt ~5 s). A blocking script would stop
# logging during exactly the window the operator wants to watch.
#
# Phases: IDLE -> ABSENT -> STARTING -> SETTLING -> RAISING -> IDLE
#                           \-> BLOCKED (codex owns it now)
#
# LEVELS -- exactly four words, and the word is the whole status. Only FATAL is all
# caps; every other level is capitalised on its first letter only.
#   Silly  blue    normal: the heartbeat, detections, and every raise that SUCCEEDED
#   Warm   yellow  a raise is IN FLIGHT, whichever raise it is -- starting dsh web,
#                  raising the model, or codex working. While codex is the one working,
#                  the token is followed by the last 20 characters of its live output,
#                  so a detached repair job is not a black box.
#   Error  orange  that raise FAILED, a retry was spent, or codex had to be handed the
#                  job -- including each of the three codex attempts
#   FATAL  red     BLOCKED -- and this word comes from CODEX, not from us: we read
#                  thread_goals.status out of ~/.codex/goals_1.sqlite via
#                  codex-status.js, using the `session id` codex prints in its own
#                  output. A status we invented would be worth nothing.
#
# One line per second, padded so it scans:
#   [15:21:07] Silly node=YES port=YES absent=0    tries=0 | model raise written
#   [15:21:17] Silly node=YES port=YES absent=0    tries=0 | receipt FOUND
#   [15:22:21] Warm  [codex is editing b] node=NO  port=NO  tries=1 | codex status=active
#   [15:23:40] FATAL [blocked] node=NO port=NO tries=3 | codex status=blocked
#
# Nothing here is hardcoded to one machine. There is NO default session id and NO
# default session directory: -SessionId and -SessionDir are REQUIRED. A tool that
# guessed someone's session id would be worse than useless.
#
# Non-ASCII is avoided: PS 5.1 mis-decodes non-BOM UTF-8 literals.
param(
  [int]$AbsenceSeconds  = 5,
  [int]$SettleSeconds   = 10,
  [int]$ReceiptWait     = 5,
  [int]$StartWait       = 60,
  [int]$MaxCodexTries   = 3,
  [int]$CodexTailChars  = 20,
  [string]$StateDir     = (Join-Path $PSScriptRoot 'state'),
  [string]$UserHome     = $env:USERPROFILE,
  [Parameter(Mandatory=$true)][string]$SessionId,
  [Parameter(Mandatory=$true)][string]$SessionDir
)
$ErrorActionPreference = 'SilentlyContinue'

$log        = Join-Path $StateDir 'guard.log'
$stateFile  = Join-Path $StateDir 'guard-state.txt'
$pidFile    = Join-Path $StateDir 'guard-last-web-pid.txt'
$triesFile  = Join-Path $StateDir 'guard-codex-tries.txt'
$lidState   = Join-Path $StateDir 'lid.state'
$startedOut = Join-Path $StateDir 'dshweb-started.log'
# --- keep our own runners alive ---------------------------------------------------------
# A reboot kills guard-loop.ps1 and lid-loop.ps1 -- they are plain processes and nothing
# brings them back on its own. The scheduled task DOES survive a reboot, so this is where
# they get resurrected: the first pass of every process runs the check, then it is
# throttled so the 1 Hz caller does not pay for it on every pass.
#
# The task stays at one minute (that is the finest Task Scheduler offers), so the boot
# trigger added to it (install.ps1) is what makes the post-reboot path fast instead of up
# to a minute.
#
# Liveness: lid-loop by its own log's freshness (it writes one line per 5 s pass);
# guard-loop by its process, because it logs only when it starts or relaunches something.
# Both relaunches go through PsExec with -s -realtime -d, the same way the loops were
# started by hand -- a child of a scheduled task gets reaped, a detached one does not.
# The throttle lives in a FILE, not in a variable: guard-loop calls this script with `&`
# once per second, and every call gets a fresh script scope -- so a variable would make the
# check run on all 3600 passes an hour, putting a CIM process scan inside the 1 Hz loop.
# The loop scripts sit beside this one; only their state and logs live in $StateDir.
$loopsCheckFile = Join-Path $StateDir 'guard-loops-checked.txt'
$loopsDir       = $PSScriptRoot
$psexecExe      = Join-Path $env:SystemRoot 'System32\PsExec.exe'
$loopsDue = $true
if (Test-Path -LiteralPath $loopsCheckFile) {
  try {
    $loopsDue = ((Get-Date) - [datetime]::Parse((Get-Content -LiteralPath $loopsCheckFile -Raw).Trim())).TotalSeconds -ge 15
  } catch { $loopsDue = $true }
}
if ($loopsDue) {
  Set-Content -LiteralPath $loopsCheckFile -Value ((Get-Date).ToString('o')) -Encoding ascii
  try {
    $psList = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)
    if (@($psList | Where-Object { $_.CommandLine -like '*guard-loop.ps1*' }).Count -eq 0) {
      Add-Content -Path $log -Value ('[{0}] guard-loop missing -> relaunching' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
      & $psexecExe -accepteula -nobanner -s -realtime -d powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $loopsDir 'guard-loop.ps1') -StateDir $StateDir 2>&1 | Out-Null
    }
    # Lid sampler: TWO tests, because either one alone has a blind spot.
    #   - no process at all  -> it was just killed; its log is still fresh, so freshness
    #     alone reads a freshly killed sampler as healthy. This test catches that.
    #   - log stopped moving -> it is on the process list but no longer passing. This test
    #     catches a hung loop, which the process test cannot see.
    $lidLogPath = Join-Path $StateDir 'lid-loop.log'
    $lidAge = 9999
    if (Test-Path $lidLogPath) { $lidAge = [math]::Round(((Get-Date) - (Get-Item $lidLogPath).LastWriteTime).TotalSeconds) }
    $lidProc = @($psList | Where-Object { $_.CommandLine -like '*lid-loop.ps1*' }).Count
    if ($lidProc -eq 0 -or $lidAge -gt 20) {
      Add-Content -Path $log -Value ('[{0}] lid-loop down (proc={1} log_age={2}s) -> relaunching' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $lidProc, $lidAge)
      & $psexecExe -accepteula -nobanner -s -realtime -d powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $loopsDir 'lid-loop.ps1') -StateDir $StateDir 2>&1 | Out-Null
    }
  } catch { }
}
$codexOut   = Join-Path $StateDir 'codex-rescue.out'
$maintFile  = Join-Path $StateDir 'MAINTENANCE'
# The prompt ships next to this script as a template carrying <SESSION-ID> and
# <STATE-DIR>; install.ps1 writes a substituted copy into the state directory. Prefer
# that live copy, fall back to the template. Both are derived, never literal.
$promptFile = Join-Path $PSScriptRoot 'rescue-prompt.txt'
$promptLive = Join-Path $StateDir 'rescue-prompt.txt'
if (Test-Path $promptLive) { $promptFile = $promptLive }
# node is not guaranteed on PATH for a SYSTEM task: ask the environment first, then fall
# back to the usual absolute install location.
$nodeExe    = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $nodeExe) { $nodeExe = 'C:\Program Files\nodejs\node.exe' }
# Helpers live beside this script, so the tree is relocatable.
$checker    = Join-Path $PSScriptRoot 'check-raise.js'
$statuser   = Join-Path $PSScriptRoot 'codex-status.js'

# This guard may run as SYSTEM (the per-minute task does), where %USERPROFILE% is the
# systemprofile. Everything codex-shaped then resolves to the wrong home: `codex` is not
# on PATH, and its config, auth, and goal store live under the interactive user. -UserHome
# names that user's profile (install.ps1 passes it). Pin both before anything runs, so the
# child processes and codex-status.js agree.
$env:USERPROFILE = $UserHome
$env:CODEX_HOME  = Join-Path $UserHome '.codex'

function W([string]$m) {
  # rotation: 1 Hz logging means ~86k lines/day, so cap the file.
  if ((Test-Path $log) -and ((Get-Item $log).Length -gt 4000000)) {
    Move-Item -LiteralPath $log -Destination ($log + '.1') -Force
  }
  Add-Content -Path $log -Value $m
}
function WebProc {
  # Cheap fast path first. Get-Process on ONE id costs microseconds; the WMI query
  # below costs ~0.5 s, and two such queries per pass held the log at ~1.5 s instead
  # of 1 s. The cached id is re-validated by name, and WMI runs again only when that
  # id is gone -- i.e. after a real restart.
  $cache = Join-Path $StateDir 'guard-web-pid.txt'
  if (Test-Path $cache) {
    $cp = (Get-Content $cache -Raw).Trim()
    if ($cp) {
      $proc = Get-Process -Id ([int]$cp) -ErrorAction SilentlyContinue
      if ($proc -and $proc.ProcessName -eq 'node') { return [pscustomobject]@{ ProcessId = $proc.Id } }
    }
  }
  $found = Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
    Where-Object {
      $_.CommandLine -like '*lib*bin.js*web*' -and
      $_.CommandLine -notlike '*runner.js*' -and
      $_.CommandLine -notlike '*subprocess-local*'
    } | Select-Object -First 1
  if ($found) { Set-Content -LiteralPath $cache -Value $found.ProcessId }
  elseif (Test-Path $cache) { Remove-Item -LiteralPath $cache -Force }
  return $found
}
function PortUp {
  # One non-blocking connect to 127.0.0.1:3080 is ~1 ms. Get-NetTCPConnection walks the
  # whole TCP table and cost ~0.5 s -- the other half of the slow cadence.
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $client.BeginConnect('127.0.0.1', 3080, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne(150)
    $client.Close()
    return $ok
  } catch { return $false }
}
function ReadState {
  $s = @{ phase = 'IDLE'; since = (Get-Date).ToString('o'); marker = ''; attempt = '0'; prevpid = ''; codextail = ''; threadid = ''; codexstatus = '' }
  if (Test-Path $stateFile) {
    foreach ($line in (Get-Content $stateFile)) {
      $kv = $line -split '=', 2
      if ($kv.Count -eq 2) { $s[$kv[0].Trim()] = $kv[1].Trim() }
    }
  }
  return $s
}
function WriteState($s) {
  $text = @()
  foreach ($k in @('phase', 'since', 'marker', 'attempt', 'prevpid', 'codextail', 'threadid', 'codexstatus')) { $text += ($k + '=' + $s[$k]) }
  Set-Content -LiteralPath $stateFile -Value $text
}
function CodexTail {
  # The last N characters of codex's live output, whitespace-collapsed so it fits on one
  # line. This is how a detached invocation stays watchable.
  if (-not (Test-Path $codexOut)) { return '' }
  $raw = Get-Content $codexOut -Raw -ErrorAction SilentlyContinue
  if (-not $raw) { return '' }
  $flat = ($raw -replace '\s+', ' ').Trim()
  if ($flat.Length -le $CodexTailChars) { return $flat }
  return $flat.Substring($flat.Length - $CodexTailChars)
}
function CodexThread {
  # codex prints `session id: <uuid>` in the header of its own output.
  if (-not (Test-Path $codexOut)) { return '' }
  $raw = Get-Content $codexOut -Raw -ErrorAction SilentlyContinue
  if (-not $raw) { return '' }
  $m = [regex]::Match($raw, 'session id:\s*([0-9a-fA-F\-]{36})')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}
function CodexStatus([string]$threadId) {
  # Ask codex, do not guess.
  if (-not $threadId) { return 'NO_THREAD' }
  if (-not (Test-Path $statuser)) { return 'NO_READER' }
  return ((& $nodeExe $statuser $threadId 2>&1) -join ' ').Trim()
}

$s = ReadState
$node = WebProc
$port = PortUp
$hasNode = [bool]$node
$now = Get-Date
$elapsed = 0
try { $elapsed = [int]($now - [datetime]$s.since).TotalSeconds } catch { $elapsed = 0 }
$phase = $s.phase
$action = 'none'

if ($phase -eq 'IDLE') {
  if ($hasNode) {
    $prev = (Get-Content $pidFile -Raw -ErrorAction SilentlyContinue)
    if ($prev) { $prev = $prev.Trim() }
    if ($prev -and $prev -ne $node.ProcessId.ToString()) {
      $s.prevpid = $prev; $s.phase = 'SETTLING'; $s.since = $now.ToString('o')
      $action = 'restart detected'
    }
    Set-Content -LiteralPath $pidFile -Value $node.ProcessId
  } else {
    $s.phase = 'ABSENT'; $s.since = $now.ToString('o'); $action = 'node gone'
  }
}
elseif ($phase -eq 'ABSENT') {
  if ($hasNode) { $s.phase = 'IDLE'; $action = 'node returned' }
  elseif ($port) { $action = 'port held, waiting' }
  elseif (Test-Path $maintFile) { $action = 'maintenance marker present' }
  elseif ($elapsed -ge $AbsenceSeconds) {
    if (Get-ScheduledTask -TaskName 'DSH-start-web' -ErrorAction SilentlyContinue) {
      Start-ScheduledTask -TaskName 'DSH-start-web'; $action = 'starting dsh web'
    } else { $action = 'no starter task' }
    $s.phase = 'STARTING'; $s.since = $now.ToString('o')
  }
}
elseif ($phase -eq 'STARTING') {
  if ($hasNode) {
    Set-Content -LiteralPath $pidFile -Value $node.ProcessId
    $s.prevpid = ''; $s.phase = 'SETTLING'; $s.since = $now.ToString('o'); $action = 'node up, settling'
  }
  elseif ($elapsed -ge $StartWait) {
    $tries = 0
    if (Test-Path $triesFile) { $tries = [int]((Get-Content $triesFile -Raw).Trim()) }
    if ($tries -lt $MaxCodexTries -and (Test-Path $promptFile)) {
      $tries++
      Set-Content -LiteralPath $triesFile -Value $tries
      Remove-Item -LiteralPath $codexOut -Force -ErrorAction SilentlyContinue
      # Absolute path: under SYSTEM, %APPDATA%\npm is not on PATH. The user env is pinned
      # near the top of this file, so codex resolves its own config and auth correctly.
      $codexExe = Join-Path $UserHome 'AppData\Roaming\npm\codex.cmd'
      if (-not (Test-Path $codexExe)) { $codexExe = 'codex' }
      $inner = '"' + $codexExe + '" exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check ' +
               '-C "' + $UserHome + '" -o "' + (Join-Path $StateDir 'codex-rescue-last.txt') + '" - ' +
               '< "' + $promptFile + '" >> "' + $codexOut + '" 2>&1'
      Start-Process -FilePath 'cmd.exe' -WindowStyle Hidden -ArgumentList '/c', $inner
      $action = 'codex attempt ' + $tries + ' of ' + $MaxCodexTries
    } else {
      $action = 'codex attempts exhausted'
    }
    $s.phase = 'BLOCKED'; $s.since = $now.ToString('o')
  } else { $action = 'waiting for node' }
}
elseif ($phase -eq 'BLOCKED') {
  # codex owns the problem. Read ITS status; never invent one.
  if ($hasNode) {
    Set-Content -LiteralPath $pidFile -Value $node.ProcessId
    $s.prevpid = ''; $s.phase = 'SETTLING'; $s.since = $now.ToString('o')
    $action = 'codex fixed it (status ' + $s.codexstatus + ')'
  } else {
    $s.threadid = CodexThread
    $s.codexstatus = CodexStatus $s.threadid
    $s.codextail = CodexTail
    $action = 'codex status=' + $s.codexstatus
  }
}
elseif ($phase -eq 'SETTLING') {
  if (-not $hasNode) { $s.phase = 'ABSENT'; $s.since = $now.ToString('o'); $action = 'node lost again' }
  elseif ($elapsed -ge $SettleSeconds) {
    $cur = 'OPEN'
    if (Test-Path $lidState) { $cur = (Get-Content $lidState -Raw).Trim() }
    $word = ($cur -split '\s+')[0]
    if ($word -notin @('OPEN', 'CLOSED')) { $word = 'OPEN' }
    $s.marker = 'guard-raised-' + ($now.ToString('yyyyMMdd-HHmmss')) + '-1'
    $s.attempt = '1'
    Set-Content -LiteralPath $lidState -Value ($word + ' ' + $now.ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $s.marker)
    $s.phase = 'RAISING'; $s.since = $now.ToString('o'); $action = 'model raise written'
  } else { $action = 'settling' }
}
elseif ($phase -eq 'RAISING') {
  if ($elapsed -ge $ReceiptWait) {
    $verdict = 'checker-missing'
    if (Test-Path $checker) { $verdict = (& $nodeExe $checker $SessionDir $s.marker 2>&1) -join ' ' }
    if ($verdict -like 'FOUND*') { $s.phase = 'IDLE'; $action = 'receipt FOUND' }
    elseif ($s.attempt -eq '1') {
      $cur = (Get-Content $lidState -Raw -ErrorAction SilentlyContinue); if (-not $cur) { $cur = 'OPEN' }
      $word = ($cur.Trim() -split '\s+')[0]
      if ($word -notin @('OPEN', 'CLOSED')) { $word = 'OPEN' }
      $s.marker = 'guard-raised-' + ($now.ToString('yyyyMMdd-HHmmss')) + '-2'
      $s.attempt = '2'
      Set-Content -LiteralPath $lidState -Value ($word + ' ' + $now.ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $s.marker)
      $s.since = $now.ToString('o'); $action = 'raise did not land, retrying'
    } else {
      if ($s.prevpid) { Set-Content -LiteralPath $pidFile -Value $s.prevpid }
      $s.phase = 'IDLE'; $s.since = $now.ToString('o'); $action = 'raise failed twice, claim released'
    }
  } else { $action = 'awaiting receipt' }
}
else {
  $s.phase = 'IDLE'; $s.since = $now.ToString('o'); $action = 'phase reset'
}

WriteState $s

# --- level: one of exactly four words -------------------------------------------------
$level = 'Silly'
$tailpart = ''
if ($action -like 'codex status=*') {
  # codex IS the last-resort raise: while it works the level is Warm, and its own verdict
  # decides the rest. Only FATAL is all-caps; every other level is first letter only.
  switch ($s.codexstatus) {
    'active'          { $level = 'Warm'; if ($s.codextail) { $tailpart = ' [' + $s.codextail + ']' } }
    'paused'          { $level = 'Error'; $tailpart = ' [paused]' }
    'blocked'         { $level = 'FATAL'; $tailpart = ' [blocked]' }
    'usage_limited'   { $level = 'FATAL'; $tailpart = ' [usage_limited]' }
    'budget_limited'  { $level = 'FATAL'; $tailpart = ' [budget_limited]' }
    'complete'        { $level = 'FATAL'; $tailpart = ' [complete but dsh still down]' }
    'NO_THREAD'       { $level = 'Error'; $tailpart = ' [no session id yet]' }
    'NO_ROW'          { $level = 'Error'; $tailpart = ' [codex has no goal row]' }
    default           { $level = 'Error'; $tailpart = ' [' + $s.codexstatus + ']' }
  }
}
# Warm = a raise is in flight, whichever raise it is: dsh web, the model, or codex.
elseif ($action -eq 'starting dsh web') { $level = 'Warm' }
elseif ($action -eq 'settling' -or $action -eq 'awaiting receipt') { $level = 'Warm' }
elseif ($action -eq 'model raise written') { $level = 'Warm' }
# Error = that raise failed, or a retry was spent.
elseif ($action -like 'codex attempt*' -or $action -like 'codex attempts exhausted' -or
        $action -eq 'no starter task' -or $action -eq 'node lost again' -or
        $action -eq 'raise did not land, retrying' -or $action -eq 'raise failed twice, claim released' -or
        $action -eq 'phase reset') { $level = 'Error' }
# Everything else -- the heartbeat, detections, and every raise that SUCCEEDED -- is Silly.

$esc = [char]27
$color = switch ($level) {
  'Silly' { $esc + '[34m' }
  'Warm'  { $esc + '[33m' }
  'Error' { $esc + '[38;5;208m' }
  'FATAL' { $esc + '[31m' }
  default { '' }
}
$reset = if ($color) { $esc + '[0m' } else { '' }
$green = $esc + '[32m'     # Yep  -- always green
$darkred = $esc + '[31m'   # Nope -- always red

# What is up and what is down. Only the words Yep/Nope carry colour: the brackets and
# everything inside them stay default, so the payload is never re-inked.
$up = @()
$down = @()
if ($hasNode) { $up += 'Main' } else { $down += 'Main' }
if ($port) { $up += 'Port' } else { $down += 'Port' }
$upList = if ($up.Count) { '[' + ($up -join ',') + ']' } else { '[Nope]' }
$downList = if ($down.Count) { '[' + ($down -join ',') + ']' } else { '[Nope]' }

# Recompute the wait from the state we JUST wrote. Computing it earlier used the
# PREVIOUS phase's timestamp, which is why the first "node gone" line once showed
# WaitSec=1057 and another showed absent=781 -- both were stale, not real.
$elapsed = 0
try { $elapsed = [int]((Get-Date) - [datetime]$s.since).TotalSeconds } catch { $elapsed = 0 }
$waitShown = if (-not $hasNode) { $elapsed } else { 0 }
$tryedShown = (Get-Content $triesFile -Raw -ErrorAction SilentlyContinue)
if ($tryedShown) { $tryedShown = $tryedShown.Trim() } else { $tryedShown = '0' }

# Event names in the operator's own voice, translated here rather than at every branch so
# the state machine keeps plain action ids.
#   none->NaN  node gone->Node404  restart detected->NodeSwapped  port held->NodeWait..
#   starting dsh web->NodeWakey  node up->NodeReborn  settling/awaiting->NodeWait..
#   model raise written->ModelWakey  receipt FOUND->ModelReciped!
$what = switch ($action) {
  'none'                               { 'NaN' }
  'node gone'                          { 'Node404' }
  'node returned'                      { 'NodeBack' }
  'restart detected'                   { 'NodeSwapped' }
  'port held, waiting'                 { 'NodeWait..' }
  'maintenance marker present'         { 'Paused' }
  'starting dsh web'                   { 'NodeWakey' }
  'no starter task'                    { 'StarterBomb' }
  'waiting for node'                   { 'NodeWait..' }
  'node up, settling'                  { 'NodeReborn' }
  'node lost again'                    { 'TrackLost' }
  'settling'                           { 'NodeWait..' }
  'model raise written'                { 'ModelWakey' }
  'awaiting receipt'                   { 'ModelWait..' }
  'receipt FOUND'                      { 'ModelReciped!' }
  'raise did not land, retrying'       { 'Modeldead/rty' }
  'raise failed twice, claim released' { 'Modelburned' }
  'phase reset'                        { 'PhaseReset!' }
  default                              { $action }
}
if ($action -like 'codex attempt*') {
  # 'codex attempt 2 of 3' -> Codexslp2
  $n = ($action.Replace('codex attempt ', '') -split ' ')[0]
  $what = 'Codexslp' + $n
}
if ($action -like 'codex attempts exhausted') { $what = 'Codexfired' }
if ($action -like 'codex status=*') {
  # the word in brackets is codex's own thread_goals.status; these are the shout
  $what = switch ($s.codexstatus) {
    'active'         { 'CodexWorking' }
    'paused'         { 'CodexPaused!' }
    'blocked'        { 'CodexplayMC' }
    'usage_limited'  { 'CodexUsed' }
    'budget_limited' { 'CodexStuffed' }
    'complete'       { 'CodexBurned' }
    default          { 'Codex?' + $s.codexstatus }
  }
}
if ($what.Length -gt 22) { $what = $what.Substring(0, 22) }
# TrackLost is the one event word that carries its own colour. It is red on purpose and
# deliberately not explained here; the ask was "mark it red, do not ask what it means".
if ($what -eq 'TrackLost') { $what = $esc + '[31m' + $what + $reset }
# Only a Warm line owns the tail slot. Clearing $tailpart unconditionally used to WIPE
# the bracket the codex-status block had just set, so a real FATAL line would have read
# "FATAL node=..." with no [blocked] on it -- and a demo that injects the bracket by hand
# would never have shown that. Only overwrite it when this branch is the one that owns it.
if ($level -eq 'Warm') {
  $tailpart = ''
  if ($s.codextail) { $tailpart = ' [' + $s.codextail + ']' }
}

W ('[{0}] {1}{2,-5}{3}{4} {5}Yep{6}:{7} {8}Nope{9}:{10} WaitSec={11}/s Tryed={12}t/min | {13}' -f `
   $now.ToString('HH:mm:ss'), $color, $level, $reset, $tailpart, `
   $green, $reset, $upList, $darkred, $reset, $downList, `
   $waitShown, $tryedShown, $what)
return
