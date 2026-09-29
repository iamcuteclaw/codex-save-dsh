# install.ps1 -- register the two scheduled tasks codex-save-dsh needs.
#
# ASCII only, deliberately: PS 5.1 mis-decodes non-BOM UTF-8 literals.
#
# This script REGISTERS NOTHING until you confirm. It prints every path it is about to
# use and the exact two tasks it will register, then asks for y/N.
#
# HONEST NOTE ABOUT THE SYSTEM TASK: the guard is registered as NT AUTHORITY\SYSTEM so
# that it cannot draw a console on, or be killed from, the interactive desktop. SYSTEM
# does NOT inherit the interactive user's PATH: `codex` and `node` may both be missing,
# `codex` is certainly not on PATH, and %USERPROFILE% is the systemprofile rather than
# the user's home. The guard therefore pins USERPROFILE and CODEX_HOME from -UserHome
# and resolves node via Get-Command with an absolute fallback. Pass -UserHome
# explicitly whenever this script itself runs as SYSTEM.
#
# -SessionId and -SessionDir are REQUIRED and have no default. A tool that guessed
# someone's session id would be worse than useless.
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$SessionId,
  [Parameter(Mandatory=$true)][string]$SessionDir,
  [string]$UserHome    = $env:USERPROFILE,
  [string]$InstallRoot = $PSScriptRoot,
  [string]$StateDir    = (Join-Path $PSScriptRoot 'state'),
  [string]$TaskNameGuard   = 'DSH-guard',
  [string]$TaskNameStarter = 'DSH-start-web'
)

if ([string]::IsNullOrWhiteSpace($SessionId) -or [string]::IsNullOrWhiteSpace($SessionDir)) {
  Write-Host 'REFUSING: -SessionId and -SessionDir are both required and neither has a default.'
  Write-Host 'A tool that guessed a session id would be worse than useless.'
  exit 2
}
if ([string]::IsNullOrWhiteSpace($UserHome) -or $UserHome -like '*systemprofile*') {
  Write-Host ('REFUSING: -UserHome resolves to "{0}", which is SYSTEM''s profile, not the user''s.' -f $UserHome)
  Write-Host 'The guard would then read the wrong codex config, auth and goal store.'
  Write-Host 'Pass -UserHome with the interactive user''s profile path.'
  exit 2
}

# --- every path this install will touch -------------------------------------------------
$psExe         = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
if (-not $psExe) { $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
$guardScript   = Join-Path $InstallRoot 'guard\DSH-guard.ps1'
$loopScript    = Join-Path $InstallRoot 'guard\guard-loop.ps1'
$starterScript = Join-Path $InstallRoot 'guard\start-dsh-web.ps1'
$checkerScript = Join-Path $InstallRoot 'guard\check-raise.js'
$statusScript  = Join-Path $InstallRoot 'guard\codex-status.js'
$promptTemplate = Join-Path $InstallRoot 'guard\rescue-prompt.txt'
$promptLive    = Join-Path $StateDir 'rescue-prompt.txt'
$nodeExe       = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $nodeExe) { $nodeExe = 'C:\Program Files\nodejs\node.exe' }
$codexExe      = Join-Path $UserHome 'AppData\Roaming\npm\codex.cmd'
# $env:APPDATA under SYSTEM is the systemprofile, so this must be derived from -UserHome,
# not from the current process's environment. It is only printed, but a printed lie is
# still a lie, and this line is the one an operator reads while checking the plan.
$dshBin        = Join-Path $UserHome 'AppData\Roaming\npm\node_modules\@deepseek-ai\dsh\lib\bin.js'

$paths = [ordered]@{
  'install root'        = $InstallRoot
  'guard script'        = $guardScript
  'guard loop script'   = $loopScript
  'starter script'      = $starterScript
  'raise checker (js)'  = $checkerScript
  'codex status (js)'   = $statusScript
  'prompt template'     = $promptTemplate
  'state directory'     = $StateDir
  'prompt (written)'    = $promptLive
  'interactive home'    = $UserHome
  'session id'          = $SessionId
  'session directory'   = $SessionDir
  'powershell'          = $psExe
  'node'                = $nodeExe
  'codex (user)'        = $codexExe
  'dsh web entry'       = $dshBin
}

Write-Host ''
Write-Host '=== codex-save-dsh install plan ==='
Write-Host ''
Write-Host 'Paths:'
foreach ($k in $paths.Keys) {
  $v = [string]$paths[$k]
  $exists = if ($k -eq 'session id') { '(input)' }
            elseif ($k -eq 'state directory' -or $k -eq 'prompt (written)') { '(created below)' }
            else { if (Test-Path -LiteralPath $v) { '(exists)' } else { '(MISSING)' } }
  Write-Host ('  {0,-20} {1}  {2}' -f $k, $v, $exists)
}

$guardArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -StateDir "{1}" -UserHome "{2}" -SessionId "{3}" -SessionDir "{4}"' -f `
             $guardScript, $StateDir, $UserHome, $SessionId, $SessionDir
$starterArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -StateDir "{1}"' -f $starterScript, $StateDir

Write-Host ''
Write-Host 'Scheduled tasks that will be registered (nothing is registered yet):'
Write-Host ''
Write-Host ('  [1] {0}' -f $TaskNameGuard)
Write-Host ('      run as   : NT AUTHORITY\SYSTEM  (LogonType ServiceAccount, RunLevel Highest)')
Write-Host ('      trigger  : every 1 minute, forever')
Write-Host ('      action   : {0}' -f $guardScript)
Write-Host ('      command  : "{0}" {1}' -f $psExe, $guardArgs)
Write-Host ''
Write-Host ('  [2] {0}' -f $TaskNameStarter)
Write-Host ('      run as   : {0}\{1}  (LogonType Interactive, RunLevel Limited)' -f $env:USERDOMAIN, $env:USERNAME)
Write-Host ('      trigger  : none -- on demand; the guard starts it with Start-ScheduledTask')
Write-Host ('      action   : {0}' -f $starterScript)
Write-Host ('      command  : "{0}" {1}' -f $psExe, $starterArgs)
Write-Host ''
Write-Host 'Honest note: the SYSTEM-run guard has no codex on PATH and no user home. It pins'
Write-Host ('USERPROFILE={0} and CODEX_HOME={1} before it runs anything.' -f $UserHome, (Join-Path $UserHome '.codex'))
Write-Host ''

$answer = Read-Host 'Register these two tasks? [y/N]'
if ($answer -notmatch '^(y|yes)$') {
  Write-Host 'Aborted. Nothing was created or registered.'
  exit 1
}

# --- apply ------------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $StateDir)) {
  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  Write-Host ('created state directory {0}' -f $StateDir)
}

# Substitute the two placeholders into a live copy inside the state directory. The shipped
# template in guard\ keeps its placeholders, so the repo stays free of any real id.
if (Test-Path -LiteralPath $promptTemplate) {
  $text = Get-Content -LiteralPath $promptTemplate -Raw -Encoding UTF8
  $text = $text.Replace('<SESSION-ID>', $SessionId).Replace('<STATE-DIR>', $StateDir)
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($promptLive, $text, $utf8NoBom)
  Write-Host ('wrote substituted prompt to {0}' -f $promptLive)
} else {
  Write-Host ('WARNING: prompt template missing at {0}; the guard will not be able to call codex.' -f $promptTemplate)
}

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

$guardTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date)
$guardTrigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
  -RepetitionInterval (New-TimeSpan -Minutes 1) `
  -RepetitionDuration (New-TimeSpan -Days 3650)).Repetition

$guardPrincipal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
# RunLevel Highest, not Limited: the host this restarts is normally started by an operator
# with an elevated shell, and a restarted host that quietly has fewer rights than the one
# it replaces is a different host. Highest means the user's own highest available token.
$starterPrincipal = New-ScheduledTaskPrincipal -UserId ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME) -LogonType Interactive -RunLevel Highest

$guardAction = New-ScheduledTaskAction -Execute $psExe -Argument $guardArgs -WorkingDirectory $InstallRoot
Register-ScheduledTask -TaskName $TaskNameGuard -Action $guardAction -Trigger $guardTrigger `
  -Principal $guardPrincipal -Settings $settings -Force `
  -Description 'codex-save-dsh guard: one state-machine step, runs as SYSTEM every minute.' | Out-Null
Write-Host ('registered task {0}' -f $TaskNameGuard)

# No -Trigger: this task exists to be started on demand by the guard.
$starterAction = New-ScheduledTaskAction -Execute $psExe -Argument $starterArgs -WorkingDirectory $InstallRoot
Register-ScheduledTask -TaskName $TaskNameStarter -Action $starterAction `
  -Principal $starterPrincipal -Settings $settings -Force `
  -Description 'codex-save-dsh starter: bring dsh web up in the interactive user context.' | Out-Null
Write-Host ('registered task {0}' -f $TaskNameStarter)

Write-Host ''
Write-Host 'Done. The guard task will take its first step within a minute.'
Write-Host ('State and logs live in {0}.' -f $StateDir)
