# kill-dsh-web.ps1 -- the 'dangerous task': deliberately stop dsh web so the whole
# self-heal chain has to bring it back and raise this session.
#
# Two deliberate choices:
#   * It finds the target by MATCHING the command line, never by a pid remembered
#     from an earlier turn. A remembered pid is exactly the kind of stale
#     representation that has been wrong all night.
#   * It sleeps first, so the message announcing the test is delivered before dsh
#     dies. Killing dsh kills the harness tree this turn runs in.
#
# How long that sleep has to be, measured rather than guessed: on 2026-09-30 03:45
# the announcement was out and the operator killed the host by hand about 15 s
# later, because 30 s was longer than the operator was willing to wait. So 30 was
# longer than the thing it protects. It now defaults to 10: long enough for the
# announcing text to be readable, short enough that nobody reaches past it. Pass
# -DelaySeconds when the announcing turn still has a long tail after this is armed.
#
# Known limitation, learned the hard way the same minute: the sleep runs inside a
# process the harness tree owns, so if the host dies during the sleep -- by any
# other hand -- this task dies with it and never reaches the kill. It can be one
# of the killers, never the only one.
#
# ASCII only, deliberately: PS 5.1 mis-decodes non-BOM UTF-8 literals.
param(
  [int]$DelaySeconds = 10,
  [string]$StateDir = (Join-Path $PSScriptRoot 'state')
)
$log = Join-Path $StateDir 'danger.log'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
function W([string]$m) { Add-Content -Path $log -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) }

W ('danger task armed; sleeping ' + $DelaySeconds + 's before the kill')
Start-Sleep -Seconds $DelaySeconds

$targets = Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Where-Object {
    $_.CommandLine -like '*lib*bin.js*web*' -and
    $_.CommandLine -notlike '*runner.js*' -and
    $_.CommandLine -notlike '*subprocess-local*'
  }
if (-not $targets) { W 'no dsh web process found to kill -- aborting'; exit 0 }
foreach ($t in $targets) {
  W ('killing dsh web pid ' + $t.ProcessId + ' (started ' + $t.CreationDate.ToString('HH:mm:ss') + ')')
  Stop-Process -Id $t.ProcessId -Force
}
Start-Sleep -Seconds 3
$after = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -like '*lib*bin.js*web*' -and $_.CommandLine -notlike '*runner.js*' -and $_.CommandLine -notlike '*subprocess-local*' }).Count
$port = @(Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue).Count
W ('after the kill: matching processes=' + $after + '  3080 listeners=' + $port + '  -- the chain now has to fix this itself')
