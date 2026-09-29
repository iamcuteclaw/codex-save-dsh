# wake.ps1 -- raise the WINDOWS master volume to 100%. That IS the whole wake.
#
# It must run in the interactive user's session: a process in session 0 has no desktop and
# no audio session of his. It is triggered by the DSH-wake task, which an agent starts
# through the wake_user tool.
#
# ---------------------------------------------------------------------------------------
# WHY THERE IS NO SOUND OF OUR OWN
# Measured, by the operator's ears, 2026-09-29: the player's own slider is already at 100
# and the headphone dial is at 50, while the WINDOWS master sits at 30. So nothing has to
# be played: raising the master roughly triples what he is already hearing, and the music
# he chose is the alarm. An earlier version also played a 45 s system sound. It is gone --
# it competed with the music and added nothing.
#
# WHY keybd_event AND NOT SendKeys
# Measured, same night: WScript.Shell.SendKeys does NOT move the volume when this script is
# launched by the scheduled task. A task process has no foreground window, and SendKeys
# sends keys to the ACTIVE application -- so it reported success and did nothing. The
# operator's ears caught it; the log could not. keybd_event injects into the SYSTEM input
# stream instead, which any process can do and which needs no focus at all. Same keys,
# different door.
#
# Known limit, stated rather than hidden: even keybd_event has NO readback. This script
# cannot prove the master volume reached 100% -- it can only say how many keys it injected
# and how it injected them. The real receipt is the one at the end of this file: a human
# dismissing the box, plus whatever their ears report.
#
# THE BOX IS NOT AN ASK. Measured, same night: the operator read this box as an approval
# request and waited for something to approve. Nothing here wants an answer, and a box that
# looks like a permission prompt at 3am costs exactly the turn it was meant to save. The
# line that says so is in the message, in plain English.
#
# RULE ONE: this is a BOOLEAN, not a dial. 100%, or it does not run at all. Quieter does not
# wake him, so a soft wake would only let an agent believe it had done something.
# RULE TWO: it is NEVER bound to a log level, a phase, or any automatic trigger. Firing it
# is destructive to a person wearing headphones, so the trigger is an agent's decision.
# RULE THREE: the second agent does not get this; Codex escalates by its own goal status,
# which the guard reads and turns into a FATAL line -- a report, not a noise.
#
# NEVER touch the media player. He falls asleep to music; the master volume and the
# player's own slider are different controls, and only the master is ours to move.
#
# ASCII only, deliberately: PS 5.1 mis-decodes non-BOM UTF-8 literals.
param(
  [string]$Reason = 'An agent decided this needs you.',
  [string]$Context = '',
  [switch]$Quiet
)
$log = Join-Path $PSScriptRoot 'wake.log'
function W([string]$m) { Add-Content -Path $log -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) }

# The agent tool that triggers this cannot pass arguments -- a scheduled task takes none --
# so the reason arrives by file. It is consumed here and put on the box, because at 3am the
# one thing the human needs is to know WHY. The state directory is whichever directory this
# script was installed into, never a path baked in at build time.
$reasonFile = Join-Path $PSScriptRoot 'wake.reason'
if (Test-Path -LiteralPath $reasonFile) {
  $fromFile = (Get-Content -LiteralPath $reasonFile -Raw -Encoding UTF8)
  if ($fromFile -and $fromFile.Trim()) { $Reason = $fromFile.Trim() }
  Remove-Item -LiteralPath $reasonFile -Force -ErrorAction SilentlyContinue
}

W ('wake requested (quiet=' + [bool]$Quiet + ') : ' + $Reason)
if ($Context) { W ('context: ' + $Context) }

if (-not $Quiet) {
  try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class VigilVolume {
  [DllImport("user32.dll")]
  public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
  // 0xAF = VK_VOLUME_UP. 60 presses is far more than 30 -> 100 needs, and Windows clamps
  // at the top, so the exact starting level does not matter.
  public static void RaiseMaster(int presses) {
    for (int i = 0; i < presses; i++) {
      keybd_event(0xAF, 0, 0, UIntPtr.Zero);         // key down
      keybd_event(0xAF, 0, 2, UIntPtr.Zero);         // key up (some handlers need both)
    }
  }
}
'@ -ErrorAction Stop
    [VigilVolume]::RaiseMaster(60)
    W 'volume: 60 volume-up key events injected into the system input stream (keybd_event, not SendKeys; master only, no app slider touched)'
  } catch {
    W ('volume step FAILED: ' + $_.Exception.Message)
  }
} else {
  W 'volume: skipped by the quiet test -- nothing will get loud'
}

# The box: what happened, and why. TopMost so it cannot hide behind the thing he is
# watching, and modal because the act of dismissing it IS the receipt that a human saw it.
try {
  Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
  $owner = New-Object System.Windows.Forms.Form
  $owner.TopMost = $true
  $owner.ShowInTaskbar = $false
  $owner.WindowState = 'Minimized'
  $owner.Show()
  $owner.Activate()

  $nl = [Environment]::NewLine
  $msg = 'An agent decided you are needed.' + $nl + $nl + $Reason
  if ($Context) { $msg += $nl + $nl + $Context }
  $msg += $nl + $nl + 'Your WINDOWS master volume was raised to 100%. The player was not touched.'
  # Read this before the volume line: the operator once took this box for an approval
  # request and waited for it. It asks for nothing.
  $msg += $nl + $nl + 'This is not a permission prompt. You are being woken; dismissing this box is the receipt.'
  $msg += $nl + 'Log: ' + $log
  if ($Quiet) { $msg = '[QUIET TEST -- nothing was made loud]' + $nl + $nl + $msg }
  [System.Windows.Forms.MessageBox]::Show($owner, $msg, 'WAKE: HUMAN NEEDED', 'OK', 'Warning') | Out-Null
  $owner.Close()
  W 'topmost box dismissed by a human -- that is the receipt that someone saw it'
} catch { W ('box step FAILED: ' + $_.Exception.Message) }

W 'wake done'
