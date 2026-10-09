param([Parameter(Mandatory=$true)][string]$ProjectRoot,
      [Parameter(Mandatory=$true)][string]$ShortcutPath,
      [Parameter(Mandatory=$true)][string]$MatlabRoot)
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath (Join-Path $ProjectRoot 'config.local.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$pythonWindowless = Join-Path (Split-Path $config.python_executable) 'pythonw.exe'
if (-not (Test-Path -LiteralPath $pythonWindowless)) { throw 'pythonw.exe was not found.' }
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($ShortcutPath)
$shortcut.TargetPath = $pythonWindowless
$shortcut.Arguments = '-B "' + (Join-Path $ProjectRoot 'launch_ui.py') + '" --matlab-root "' + $MatlabRoot + '"'
$shortcut.WorkingDirectory = $ProjectRoot
$shortcut.IconLocation = (Join-Path $MatlabRoot 'bin\matlab.exe') + ',0'
$shortcut.Description = 'MATLAB AI Assistant - Generate, preview and insert code'
$shortcut.Save()
