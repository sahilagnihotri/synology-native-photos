# Windows development setup for synology-native-photos.
# STUB: the Windows UI is a deferred, future phase (see documentation/plans).
# The Rust core is cross-platform; this script sets up the core toolchain so
# the shared crates build and test on Windows today. The Windows UI project
# does not exist yet and is intentionally out of scope.
#
# Usage:
#   pwsh scripts/setup/windows.ps1            # install missing core toolchain
#   pwsh scripts/setup/windows.ps1 -Verify    # check only, install nothing
#
# Version floor: Rust stable via rustup, target x86_64-pc-windows-msvc.

param([switch]$Verify)

$ErrorActionPreference = "Stop"
$RustTarget = "x86_64-pc-windows-msvc"

function Info($m) { Write-Host "==> $m" -ForegroundColor Blue }
function Ok($m)   { Write-Host "  ok $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  ! $m"  -ForegroundColor Yellow }
function Fail($m) { Write-Host "  x $m"  -ForegroundColor Red; $script:Fails++ }
$script:Fails = 0

function Have($cmd) { return [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

Info "Windows setup (core toolchain only; UI is a future phase)."
Write-Host ""

# --- Rust ---
Write-Host "Rust toolchain"
if (Have "rustc" -and (Have "cargo")) {
    Ok ("rustc " + (rustc --version).Split(" ")[1])
} elseif ($Verify) {
    Fail "Rust not installed. Run without -Verify to install (or install rustup from https://rustup.rs)."
} else {
    Info "Installing Rust via rustup..."
    $rustup = Join-Path $env:TEMP "rustup-init.exe"
    Invoke-WebRequest -Uri "https://win.rustup.rs/x86_64" -OutFile $rustup
    & $rustup -y --default-toolchain stable --profile default
    $env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"
    if (Have "rustc") { Ok "Rust installed" } else { Fail "Rust install did not add rustc to PATH" }
}

if (Have "rustup") {
    $installed = (rustup target list --installed)
    if ($installed -contains $RustTarget) {
        Ok "target $RustTarget present"
    } elseif ($Verify) {
        Fail "target $RustTarget missing"
    } else {
        Info "Adding target $RustTarget..."
        rustup target add $RustTarget
        Ok "target $RustTarget added"
    }
}

# --- UniFFI bindgen: project-driven, same as macOS ---
Write-Host ""
Write-Host "UniFFI bindgen (project-driven)"
$binManifest = Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent) "core\uniffi-bindgen\Cargo.toml"
if (Test-Path $binManifest) {
    Ok "project uniffi-bindgen present (cargo run --manifest-path core\uniffi-bindgen\Cargo.toml)"
} else {
    Ok "no core\ bindgen yet (created by the plan's scaffold task; nothing to install globally)"
}

Write-Host ""
if ($script:Fails -eq 0) {
    Write-Host "All checks passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($script:Fails) check(s) failed." -ForegroundColor Red
    exit 1
}
