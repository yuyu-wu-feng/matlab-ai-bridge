$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'config.local.json'))) {
    throw 'First run: open and run start_ai.m inside MATLAB to complete the setup wizard. See docs/安装与使用.md.'
}
$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.local.json') -Raw -Encoding UTF8 | ConvertFrom-Json
& $config.python_executable -B (Join-Path $PSScriptRoot 'launch_ui.py')
exit $LASTEXITCODE
