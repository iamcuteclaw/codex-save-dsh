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
# The lid sampler sits beside this loop; its log lives in the shared state directory.
$lidLoop = Join-Path $PSScriptRoot 'lid-loop.ps1'
$lidLog  = Join-Path $StateDir 'lid-loop.log'
$psexec  = Join-Path $env:SystemRoot 'System32\PsExec.exe'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
Add-Content -Path $log -Value ('[{0}] guard-loop started at 1 Hz (owner={1})' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:USERNAME)
$lastLidCheck = [datetime]::MinValue
while ($true) {
  & $guard -StateDir $StateDir -UserHome $UserHome -SessionId $SessionId -SessionDir $SessionDir

  # Every 10 s, confirm the lid sampler is still alive and revive it if it is not. This
  # runs INSIDE the 1 Hz loop, so the cadence above is untouched -- the check is throttled
  # and costs a process query every ten seconds, never every second.
  #
  # TWO tests, because either one alone has a blind spot.
  #   - no PROCESS at all -> it was just killed. Its log is still fresh, so a
  #     freshness-only test calls a just-killed sampler healthy. Measured: killed at
  #     16:30:13, checked at 16:30:15, log age 2 s -> "alive", and the 50 s throttle
  #     turned that into a 70 s blind spot.
  #   - log STOPPED MOVING -> it is on the process list but no longer passing; the
  #     process test cannot see this one.
  #
  # This layer covers "the sampler died". The scheduled task's startup trigger covers "the
  # machine rebooted", which kills this loop too -- nothing here can survive that, and it
  # does not try to.
  if (((Get-Date) - $lastLidCheck).TotalSeconds -ge 10) {
    $lastLidCheck = Get-Date
    $lp = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*lid-loop.ps1*' }).Count
    $lage = 9999
    if (Test-Path $lidLog) { $lage = [math]::Round(((Get-Date) - (Get-Item $lidLog).LastWriteTime).TotalSeconds) }
    if ($lp -eq 0 -or $lage -gt 20) {
      Add-Content -Path $log -Value ('[{0}] lid-loop down (proc={1} log_age={2}s) -> relaunching' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $lp, $lage)
      & $psexec -accepteula -nobanner -s -realtime -d powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $lidLoop -StateDir $StateDir 2>&1 | Out-Null
    }
  }

  Start-Sleep -Milliseconds 1000
}
