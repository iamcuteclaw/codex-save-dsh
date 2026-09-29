# system-probe.ps1 -- prove a SYSTEM-context process can reach codex and its store.
#
# The per-minute DSH-guard runs as SYSTEM. That is what stops it drawing a console
# on whichever desktop the user is on -- but SYSTEM's %USERPROFILE% is the systemprofile,
# so `codex` is not on PATH and its config, auth and goal store are under the wrong home.
# The guard pins USERPROFILE and CODEX_HOME instead of trusting the environment. This
# probe checks that the pinning actually works from SYSTEM, before we ever need it.
#
# PsExec does not return stdout, so the result is written to a file.
#
# -UserHome is the INTERACTIVE user's profile, not SYSTEM's. Pass it explicitly when
# running under PsExec -s. The two thread ids are optional: when supplied, the probe
# re-reads those rows out of the store to show that known statuses come back intact.
# They are inputs, never baked in -- a guessed id proves nothing.
#
# ASCII only, deliberately: PS 5.1 mis-decodes non-BOM UTF-8 literals.
param(
  [string]$StateDir = (Join-Path $PSScriptRoot 'state'),
  [string]$UserHome = $env:USERPROFILE,
  [string]$BlockedThreadId = '',
  [string]$PausedThreadId  = ''
)
$log = Join-Path $StateDir 'system-probe.log'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
function W([string]$m) { Add-Content -Path $log -Value ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) }

W ('=== probe: running as ' + $env:USERNAME + ' ===')
$env:USERPROFILE = $UserHome
$env:CODEX_HOME  = Join-Path $UserHome '.codex'
W ('pinned USERPROFILE=' + $env:USERPROFILE + '  CODEX_HOME=' + $env:CODEX_HOME)

$node  = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { $node = 'C:\Program Files\nodejs\node.exe' }
$codex = Join-Path $UserHome 'AppData\Roaming\npm\codex.cmd'
$statuser = Join-Path $PSScriptRoot 'codex-status.js'
W ('codex.cmd exists: ' + (Test-Path $codex) + '   node exists: ' + (Test-Path $node))

$v = (& cmd.exe /c ('"' + $codex + '" --version 2>&1')) -join ' '
W ('codex --version -> ' + $v)

if ($BlockedThreadId) {
  $st = (& $node $statuser $BlockedThreadId 2>&1) -join ' '
  W ('codex-status.js (' + $BlockedThreadId + ', expected blocked) -> ' + $st)
} else { W 'codex-status.js blocked-row check skipped (no -BlockedThreadId given)' }

if ($PausedThreadId) {
  $st2 = (& $node $statuser $PausedThreadId 2>&1) -join ' '
  W ('codex-status.js (' + $PausedThreadId + ', expected paused) -> ' + $st2)
} else { W 'codex-status.js paused-row check skipped (no -PausedThreadId given)' }

$db = Join-Path $UserHome '.codex\goals_1.sqlite'
W ('goals db readable: ' + (Test-Path $db) + '   size ' + (Get-Item $db -ErrorAction SilentlyContinue).Length)
W '=== probe done ==='
