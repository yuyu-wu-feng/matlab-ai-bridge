param(
    [ValidateSet('discover', 'status', 'probe', 'app', 'test', 'test-local', 'demo', 'test-models', 'test-generate', 'ui-status', 'upgrade-ui', 'install-info', 'test-workflow', 'test-workflow-local', 'test-responsiveness', 'test-help', 'test-help-local', 'simulink-status', 'test-simulink', 'test-simulink-local')][string]$Command = 'status',
    [string]$PythonExe = '',
    [string]$MatlabRoot = '',
    [string]$Session = 'MATLAB_AI_BRIDGE'
)
$ErrorActionPreference = 'Stop'
if (-not $PythonExe) {
    $config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.local.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $PythonExe = $config.python_executable
}
$bridgeArgs = @('-B', (Join-Path $PSScriptRoot 'bridge.py'), $Command, '--session', $Session)
if ($MatlabRoot) { $bridgeArgs += @('--matlab-root', $MatlabRoot) }
& $PythonExe @bridgeArgs
exit $LASTEXITCODE
