# guard-loop.ps1 -- call DSH-guard.ps1 once per second, forever, in the SAME process.
#
# Launched by PsExec as SYSTEM (-s) at realtime priority (-realtime), so the thing
# that kept killing the user-session copies cannot reach it. Measured: this loop has
# survived a dsh web death outright.
#
# In-process, deliberately. At 1 Hz, spawning a fresh powershell every second would
# create ~3600 processes an hour and make Task Manager flicker. DSH-guard.ps1 ends
# with a top-level `return` instead of `exit`, so it can be called here with `&`
# (same process, child scope) without taking the loop down with it.
#
# The per-minute task DSH-guard stays as an outer net. It runs the guard as a
# SEPARATE process, so its pass and this loop's pass can interleave -- but a double
# trigger is harmless: the second dsh web cannot bind 3080 and exits on its own.
#
# -SessionId and -SessionDir have no default here either: they are forwarded verbatim.
# ASCII only, deliberately: PS 5.1 mis-decodes non-BOM UTF-8 literals.
param(
  [string]$StateDir = (Join-Path $PSScriptRoot 'state'),
  [string]$UserHome = $env:USERPROFILE,
  [Parameter(Mandatory=$true)][string]$SessionId,
  [Parameter(Mandatory=$true)][string]$SessionDir
)
$guard = Join-Path $PSScriptRoot 'DSH-guard.ps1'
$log   = Join-Path $StateDir 'guard-loop.log'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
Add-Content -Path $log -Value ('[{0}] guard-loop started at 1 Hz (owner={1})' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:USERNAME)
while ($true) {
  & $guard -StateDir $StateDir -UserHome $UserHome -SessionId $SessionId -SessionDir $SessionDir
  Start-Sleep -Milliseconds 1000
}
