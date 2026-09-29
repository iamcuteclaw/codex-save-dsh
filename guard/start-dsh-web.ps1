# start-dsh-web.ps1 -- bring dsh web up in the INTERACTIVE USER context.
#
# Run by the DSH-start-web scheduled task. The guard runs as SYSTEM and must NOT
# launch dsh web itself:
#   * SYSTEM's %APPDATA% and %USERPROFILE% are not the user's, so `dsh` is not on
#     its PATH and DSH_HOME would default to the systemprofile -- a dsh pointed at
#     the wrong home, which is worse than no dsh.
#   * a SYSTEM-owned dsh web would then fight the user's own next restart for 3080.
# So the guard triggers this task instead, and the process lands in the right context.
#
# Detached and hidden, deliberately. The first version ran dsh web in the FOREGROUND
# of this script, which left a console window sitting on the user's desktop like a
# nohup, kept the task in "Running" forever, and made dsh web a CHILD of that window
# (so closing the window would have killed the server). Now the script launches it
# and exits; dsh belongs to nobody and no window survives.
#
# ASCII only, deliberately: PS 5.1 mis-decodes non-BOM UTF-8 literals.
param(
  [string]$StateDir = (Join-Path $PSScriptRoot 'state')
)
$env:DSH_HOME    = Join-Path $env:USERPROFILE '.dsh'
$env:DSH_PROFILE = 'web'
$log = Join-Path $StateDir 'dshweb-started.log'
$out = Join-Path $StateDir 'dshweb.out.log'
$err = Join-Path $StateDir 'dshweb.err.log'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
Add-Content -Path $log -Value ('[{0}] launching dsh web detached (user={1})' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:USERNAME)

# Absolute paths first: a scheduled task inherits a minimal environment.
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { $node = 'C:\Program Files\nodejs\node.exe' }
if (-not $env:APPDATA) { $env:APPDATA = Join-Path $env:USERPROFILE 'AppData\Roaming' }
$bin  = Join-Path $env:APPDATA 'npm\node_modules\@deepseek-ai\dsh\lib\bin.js'
if ((Test-Path $node) -and (Test-Path $bin)) {
  $exe = $node
  $argv = @($bin, 'web')
} else {
  Add-Content -Path $log -Value '  absolute paths missing -- falling back to `dsh web`'
  $exe = 'dsh'
  $argv = @('web')
}

$p = Start-Process -FilePath $exe -ArgumentList $argv -WorkingDirectory $env:USERPROFILE `
     -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
Add-Content -Path $log -Value ('  detached pid ' + $p.Id + ' -- this script exits now: no foreground parent, no window')
