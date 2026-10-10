# Image Gen MCP for Windows. setup.cmd, start.cmd, update.cmd and stop.cmd run this script; the steps are in lib.ps1.
#   start    start the server; the first time (no config.yaml yet) it runs the setup first
#   setup    choose where the server runs and which model it uses, then start it
#   update   install the latest version with git
#   stop     stop the server
# -Build builds (or, with IMAGE_REPO set, pulls) the image again; -Restart restarts a running server without asking.
param(
    [Parameter(Position = 0)][ValidateSet('start', 'setup', 'update', 'stop')][string]$Action = 'start',
    [switch]$Build,
    [switch]$Restart
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # no progress bar from Invoke-WebRequest
$Root = Split-Path -Parent $PSScriptRoot
Set-Location -Path $Root
$Launcher = "$Action.cmd"
. (Join-Path $PSScriptRoot 'lib.ps1')

switch ($Action) {
    'start' {
        Write-Host 'Image Gen MCP'
        Test-Docker
        $mode = if ($Restart) { 'restart' } else { 'ask' }
        if (Test-Path config.yaml) {
            Show-Settings (Get-Machine)
        } elseif (Test-Interactive) {
            Invoke-Setup
            $mode = 'restart'
        } else {
            Copy-Item config.example.yaml config.yaml
            Write-Host '==> created config.yaml from config.example.yaml (run setup.cmd to choose the GPU and the model)'
        }
        Start-Server $mode $Build
    }
    'setup' {
        Write-Host 'Image Gen MCP setup'
        Test-Docker
        Invoke-Setup
        Start-Server 'restart' $false
    }
    'update' {
        Write-Host 'Image Gen MCP update'
        Invoke-Update
    }
    'stop' { Stop-Server }
}
exit 0
