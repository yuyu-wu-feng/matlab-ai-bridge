$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.local.json') -Raw -Encoding UTF8 | ConvertFrom-Json
& $config.python_executable -B (Join-Path $PSScriptRoot 'integration\install.py') --uninstall
exit $LASTEXITCODE
