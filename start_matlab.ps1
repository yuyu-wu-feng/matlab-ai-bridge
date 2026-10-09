param([Parameter(Mandatory=$true)][string]$MatlabRoot)
$ErrorActionPreference = 'Stop'
$bootstrap = (Join-Path $PSScriptRoot 'matlab\bridge_bootstrap.m').Replace("'", "''")
$log = Join-Path $PSScriptRoot 'output\matlab-startup.log'
New-Item -ItemType Directory -Path (Split-Path $log) -Force | Out-Null
$matlabExe = Join-Path $MatlabRoot 'bin\matlab.exe'
$matlabArgs = @('-desktop', '-sd', ('"' + $PSScriptRoot + '"'), '-logfile', ('"' + $log + '"'), '-r', ('"run(''' + $bootstrap + ''')"'))
Start-Process -FilePath $matlabExe -ArgumentList $matlabArgs -WindowStyle Hidden -PassThru | Select-Object Id,ProcessName
