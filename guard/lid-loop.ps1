# lid-loop.ps1 -- read the internal panel every 5 s, forever, and write
# lid.state ONLY when the panel state actually flips.
#
# Launched by PsExec as SYSTEM (-accepteula -nobanner -s -realtime -d), i.e. in
# session 0. Session 0 has no desktop, so this process cannot flash a console
# window on the human's screen -- which is the whole reason the sampler moved
# here from a user-session copy. It is windowless by construction: it never
# creates a form, a message box, or any interactive object, and it writes
# nothing to the console unless -Once is passed.
#
# The signal: PRESENCE of instances in
#   Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams
# Empty means the internal panel is powered off -> CLOSED; non-empty -> OPEN.
# This was measured on this machine: those instances appear and disappear with
# the panel. There is no MSAcpi_LidState class here and no System-log event, so
# this is the signal that moves.
#
# Write discipline, deliberately narrow: the state file is rewritten ONLY when
# the panel word changes between two passes. An earlier version rewrote it on
# any snapshot change (window counts, power, monitor set) and produced false
# "lid" notices -- and each false notice costs a full turn of every subscribed
# conversation. A change of seconds is not a change of state.
#
# -Once does exactly ONE pass and PRINTS what it would write. It never writes
# the state file and never touches the log, so it is safe to run in the user's
# session for a dry check. It is also excluded from the plugin's "is the sampler
# running" test, so a dry check cannot be mistaken for a live sampler.
#
# -StateDir defaults to a 'state' directory beside this script, the same way the
# other guard scripts resolve it, so the tree is relocatable and no published
# file carries a local path. The plugin reads the same file from the same place.
#
# ASCII only, deliberately: PS 5.1 mis-decodes non-BOM UTF-8 literals, so every
# byte in this file is < 0x80 on purpose. Do not add curly quotes or dashes.
param(
  [string]$StateDir = (Join-Path $PSScriptRoot 'state'),
  [switch]$Once
)

$ErrorActionPreference = 'SilentlyContinue'

$StateFile = Join-Path $StateDir 'lid.state'
$Log       = Join-Path $StateDir 'lid-loop.log'
$SampleNow = Join-Path $StateDir 'lid.sample-now'
$LogMax    = 2MB
$Interval  = 5
$Marker    = 'lid-loop-' + $PID

$script:writes = 0
# The state directory is created only for a real pass. -Once is a dry check and must not
# leave anything behind -- not even a directory -- so its early return comes before the
# create. (Measured: with the create above the return, -Once created the directory, which
# is a write from a flag documented as one that never writes.)
if (-not $Once -and -not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }

function Write-LogLine([string]$m) {
  Add-Content -LiteralPath $Log -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
}

function Invoke-Rotate {
  $f = Get-Item -LiteralPath $Log -ErrorAction SilentlyContinue
  if ($f -and $f.Length -gt $LogMax) {
    Move-Item -LiteralPath $Log -Destination ($Log + '.1') -Force -ErrorAction SilentlyContinue
    Write-LogLine 'rotated: previous log kept as lid-loop.log.1'
  }
}

function Get-PanelState {
  # $null means "could not read", which is NOT the same as CLOSED: a transient
  # CIM failure must never be allowed to produce a closed-lid notice.
  try { $m = @(Get-CimInstance -Namespace 'root\wmi' -ClassName 'WmiMonitorBasicDisplayParams' -ErrorAction Stop) }
  catch { return $null }
  if ($m.Count -gt 0) { return 'OPEN' }
  return 'CLOSED'
}

function Get-LastStateWord {
  # The state word is the FIRST token; the timestamp that follows contains a
  # space, and the marker after it is free text. Parse only the first token.
  if (-not (Test-Path -LiteralPath $StateFile)) { return $null }
  $t = (Get-Content -LiteralPath $StateFile -Raw -ErrorAction SilentlyContinue)
  if (-not $t) { return $null }
  $w = ($t.Trim() -split '\s+')[0].ToUpperInvariant()
  if ($w -eq 'OPEN' -or $w -eq 'CLOSED') { return $w }
  return $null
}

function Invoke-Pass {
  param([switch]$Dry)

  $panel = Get-PanelState
  $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

  if (-not $panel) {
    if ($Dry) { return 'panel=UNREADABLE would-write=(nothing: a failed read is not a state change)' }
    Write-LogLine 'panel=UNREADABLE wrote=n'
    return
  }

  $prev = Get-LastStateWord
  $prevText = if ($prev) { $prev } else { 'none' }

  if ($Dry) {
    if ($prev -eq $panel) { return ('panel={0} previous={1} would-write=(no change)' -f $panel, $prevText) }
    return ('panel={0} previous={1} would-write="{2} {3} {4}-1"' -f $panel, $prevText, $panel, $stamp, $Marker)
  }

  if ($prev -eq $panel) {
    Write-LogLine ('panel={0} wrote=n' -f $panel)
    return
  }

  $script:writes = $script:writes + 1
  $line = '{0} {1} {2}-{3}' -f $panel, $stamp, $Marker, $script:writes
  Set-Content -LiteralPath $StateFile -Value $line -Encoding ASCII
  Write-LogLine ('panel={0} wrote=y {1}' -f $panel, $line)
}

if ($Once) {
  Invoke-Pass -Dry
  return
}

Invoke-Rotate
Write-LogLine ('lid-loop started: interval={0}s owner={1} pid={2}' -f $Interval, $env:USERNAME, $PID)

while ($true) {
  Invoke-Rotate
  if (Test-Path -LiteralPath $SampleNow) {
    # On-demand read: the plugin asks for a fresh pass by dropping this marker
    # file instead of driving the loop itself. One read, write only if the state
    # differs, then remove the marker.
    Write-LogLine 'sample-now requested'
    Invoke-Pass
    Remove-Item -LiteralPath $SampleNow -Force -ErrorAction SilentlyContinue
    Write-LogLine 'sample-now served'
  } else {
    Invoke-Pass
  }
  Start-Sleep -Seconds $Interval
}
