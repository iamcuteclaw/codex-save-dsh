# see-screen.ps1 -- capture the whole desktop to a PNG and report its size.
#
# Used by the see_screen agent tool. It MUST run in the user's interactive session: a
# capture taken from session 0 (SYSTEM) returns a black frame, which is exactly why the
# tool lives in the dsh plugin -- dsh runs in the user's session -- and not in the guard.
#
# Prints one parseable line:  <width>x<height>:<bytes>
#
# param() must be the first executable statement in a PowerShell script: only comments and
# #Requires may precede it. With an assignment in front, the parser looks for a COMMAND
# named "param" and the whole script dies -- measured, at 16:54, loudly.
param([string]$Out = (Join-Path $PSScriptRoot 'screen.png'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.Left, $b.Top, 0, 0, $bmp.Size)
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose()
$bmp.Dispose()
Write-Output ($b.Width.ToString() + 'x' + $b.Height.ToString() + ':' + (Get-Item $Out).Length.ToString())
