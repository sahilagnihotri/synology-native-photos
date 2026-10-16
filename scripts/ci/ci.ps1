#Requires -Version 7.0
<#
Local CI gate for synology-native-photos on Windows, the counterpart of
scripts/ci/ci.sh. This script is the source of truth on Windows: the GitHub
workflow only ever calls it.

Stages:
  core     fmt      cargo fmt --all --check
           clippy   cargo clippy --workspace --all-targets -- -D warnings
           test     cargo test --workspace
  windows  app      Windows app tests (there is no Windows app yet, so SKIP)

The bash script tests under scripts/tests are not run here; ci.sh runs them.

Usage:
  pwsh scripts/ci/ci.ps1            # all
  pwsh scripts/ci/ci.ps1 core       # core stages only
  pwsh scripts/ci/ci.ps1 windows    # Windows app stage only

Every stage runs even after an earlier one fails, then a summary table is
printed. Exit code: 0 when every stage passed, 1 when any failed, 2 on bad usage.

CI_ROOT=<dir> runs the core stages against another Cargo workspace, as in ci.sh.
#>
param(
    [Parameter(Position = 0)]
    [string]$What = 'all'
)

$ErrorActionPreference = 'Continue'

if ($What -notin @('core', 'windows', 'all')) {
    Write-Host "usage: ci.ps1 [core|windows|all]" -ForegroundColor Red
    exit 2
}

$Repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Root = if ($env:CI_ROOT) { $env:CI_ROOT } else { $Repo }

$Results = [System.Collections.Generic.List[object]]::new()
$script:Failed = $false

function Add-Result([string]$Name, [string]$Result, [string]$Note = '') {
    $Results.Add([pscustomobject]@{ Stage = $Name; Result = $Result; Note = $Note })
    switch ($Result) {
        'PASS' { Write-Host "PASS $Name $Note" -ForegroundColor Green }
        'SKIP' { Write-Host "SKIP $Name $Note" -ForegroundColor Yellow }
        default { Write-Host "FAIL $Name $Note" -ForegroundColor Red; $script:Failed = $true }
    }
}

# Run a native command from the workspace root and record PASS or FAIL by its exit code.
function Invoke-Stage([string]$Name, [string[]]$Command) {
    Write-Host "== ${Name}: $($Command -join ' ')" -ForegroundColor Cyan
    Push-Location $Root
    try {
        & $Command[0] @($Command | Select-Object -Skip 1)
        $code = $LASTEXITCODE
    } catch {
        Write-Host $_ -ForegroundColor Red
        $code = 1
    } finally {
        Pop-Location
    }
    if ($code -eq 0) { Add-Result $Name 'PASS' } else { Add-Result $Name 'FAIL' "(exit $code)" }
}

function Invoke-Core {
    if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
        Add-Result 'core' 'FAIL' '(cargo not found; run scripts/windows/setup.ps1)'
        return
    }
    Invoke-Stage 'fmt' @('cargo', 'fmt', '--all', '--check')
    Invoke-Stage 'clippy' @('cargo', 'clippy', '--workspace', '--all-targets', '--', '-D', 'warnings')
    Invoke-Stage 'test' @('cargo', 'test', '--workspace')
}

function Invoke-WindowsApp {
    # Anything beyond the placeholder README means the app has started.
    $appFiles = Get-ChildItem (Join-Path $Repo 'platforms\windows') -Exclude 'README.md' -ErrorAction SilentlyContinue
    if ($appFiles) {
        Add-Result 'app' 'FAIL' '(a Windows app exists but this stage is not wired up yet)'
    } else {
        Add-Result 'app' 'SKIP' '(no Windows app yet)'
    }
}

switch ($What) {
    'core' { Invoke-Core }
    'windows' { Invoke-WindowsApp }
    'all' { Invoke-Core; Invoke-WindowsApp }
}

Write-Host ''
Write-Host "CI summary ($What)"
$Results | Format-Table -AutoSize | Out-String | Write-Host
if ($script:Failed) {
    Write-Host 'CI FAIL' -ForegroundColor Red
    exit 1
}
Write-Host 'CI PASS' -ForegroundColor Green
exit 0
