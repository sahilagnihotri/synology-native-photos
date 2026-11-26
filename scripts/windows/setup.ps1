# Windows development setup for synology-native-photos.
# The Windows UI is a deferred, future phase (see documentation/plans). The
# Rust core is cross-platform, and this script sets up the toolchain so the
# shared crates build and test on Windows today (the gate is scripts/ci/ci.ps1).
#
# Usage:
#   pwsh scripts/windows/setup.ps1            # install whatever is missing
#   pwsh scripts/windows/setup.ps1 -Verify    # check only, install nothing
#
# What it covers, in order:
#   1. rustup, rustc and cargo.
#   2. The toolchain pinned in rust-toolchain.toml (not "stable": the repo pin
#      is what cargo will actually use inside this checkout), with the clippy
#      and rustfmt components that scripts/ci/ci.ps1 needs.
#   3. The x86_64-pc-windows-msvc target for that toolchain.
#   4. The MSVC linker and C compiler (Visual Studio Build Tools with the C++
#      workload). rustc needs link.exe, and the bundled SQLite and ring need
#      cl.exe. Without them every build fails at the first C dependency.
#   5. The project-driven UniFFI bindgen (a bin target of the photoscore crate).

param([switch]$Verify)

$ErrorActionPreference = "Stop"
$RustTarget = "x86_64-pc-windows-msvc"
$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

function Info($m) { Write-Host "==> $m" -ForegroundColor Blue }
function Ok($m)   { Write-Host "  ok $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  ! $m"  -ForegroundColor Yellow }
function Fail($m) { Write-Host "  x $m"  -ForegroundColor Red; $script:Fails++ }
$script:Fails = 0

function Have($cmd) { return [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

# The channel pinned in rust-toolchain.toml, or $null when there is no pin.
function Get-PinnedChannel {
    $file = Join-Path $RepoRoot "rust-toolchain.toml"
    if (-not (Test-Path $file)) { return $null }
    foreach ($line in Get-Content $file) {
        if ($line -match '^\s*channel\s*=\s*"([^"]+)"') { return $Matches[1] }
    }
    return $null
}

# Install path of a Visual Studio (or Build Tools) instance that has the
# x64 C++ toolset, or $null. vswhere ships with every VS 2017+ installer.
function Get-MsvcInstallPath {
    $roots = @(${env:ProgramFiles(x86)}, $env:ProgramFiles) | Where-Object { $_ }
    foreach ($root in $roots) {
        $vswhere = Join-Path $root "Microsoft Visual Studio\Installer\vswhere.exe"
        if (Test-Path $vswhere) {
            $path = & $vswhere -latest -products * `
                -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
                -property installationPath
            if ($LASTEXITCODE -eq 0 -and $path) { return ($path | Select-Object -First 1) }
        }
    }
    return $null
}

Info "Windows setup (core toolchain only; UI is a future phase)."
Write-Host ""

# --- Rust ---
Write-Host "Rust toolchain"
if (-not ((Have "rustup") -and (Have "rustc") -and (Have "cargo"))) {
    if ($Verify) {
        Fail "rustup, rustc or cargo missing. Run without -Verify to install (or install rustup from https://rustup.rs)."
    } else {
        Info "Installing Rust via rustup..."
        $rustupInit = Join-Path $env:TEMP "rustup-init.exe"
        Invoke-WebRequest -Uri "https://win.rustup.rs/x86_64" -OutFile $rustupInit
        & $rustupInit -y --default-toolchain none --profile minimal
        if ($LASTEXITCODE -ne 0) { Fail "rustup-init exited with code $LASTEXITCODE" }
        $env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"
    }
}

if (Have "rustup") {
    # No stderr redirect here: Windows PowerShell 5.1 turns redirected native
    # stderr into terminating errors under ErrorActionPreference = Stop.
    Ok ("rustup " + ((rustup --version | Select-Object -First 1) -split " ")[1])
    $channel = Get-PinnedChannel
    if (-not $channel) {
        Warn "no channel pinned in rust-toolchain.toml; using stable"
        $channel = "stable"
    }

    # rustup lists toolchains as "<channel>-<host triple>", so match the prefix.
    $toolchains = @(rustup toolchain list)
    $hasToolchain = [bool]($toolchains | Where-Object { $_ -like "$channel-*" -or $_ -like "$channel *" -or $_ -eq $channel })
    if ($hasToolchain) {
        Ok "pinned toolchain $channel present"
    } elseif ($Verify) {
        Fail "pinned toolchain $channel missing (rust-toolchain.toml)"
    } else {
        Info "Installing pinned toolchain $channel..."
        rustup toolchain install $channel --profile minimal --component clippy --component rustfmt
        if ($LASTEXITCODE -eq 0) { Ok "toolchain $channel installed"; $hasToolchain = $true }
        else { Fail "rustup toolchain install $channel exited with code $LASTEXITCODE" }
    }

    if ($hasToolchain) {
        $installed = @(rustup target list --installed --toolchain $channel)
        if ($installed -contains $RustTarget) {
            Ok "target $RustTarget present"
        } elseif ($Verify) {
            Fail "target $RustTarget missing for toolchain $channel"
        } else {
            Info "Adding target $RustTarget..."
            rustup target add $RustTarget --toolchain $channel
            if ($LASTEXITCODE -eq 0) { Ok "target $RustTarget added" }
            else { Fail "rustup target add exited with code $LASTEXITCODE" }
        }
    }
} elseif (-not $Verify) {
    Fail "Rust install did not put rustup on PATH. Open a new terminal and re-run."
}

# --- MSVC build tools (linker + C compiler) ---
Write-Host ""
Write-Host "MSVC build tools"
$msvc = Get-MsvcInstallPath
if ($msvc) {
    Ok "C++ toolset found at $msvc"
} elseif ($Verify) {
    Fail "Visual Studio Build Tools with the C++ workload not found (needed for link.exe and cl.exe)."
} elseif (Have "winget") {
    # DEFER(WIN-2): this install branch has never been run. Exercise it on a
    # Windows machine without Visual Studio.
    Info "Installing Visual Studio Build Tools (C++ workload) via winget. This is a large download and asks for elevation..."
    winget install --id Microsoft.VisualStudio.2022.BuildTools --exact `
        --accept-package-agreements --accept-source-agreements `
        --override "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --passive --norestart --wait"
    if (Get-MsvcInstallPath) { Ok "C++ toolset installed" }
    else { Fail "Build Tools install did not produce a C++ toolset. Install the 'Desktop development with C++' workload by hand." }
} else {
    Fail "Visual Studio Build Tools missing and winget is unavailable. Install the 'Desktop development with C++' workload from https://visualstudio.microsoft.com/visual-cpp-build-tools/"
}

# --- UniFFI bindgen: project-driven, same as macOS ---
Write-Host ""
Write-Host "UniFFI bindgen (project-driven)"
$bindgen = Join-Path $RepoRoot "core\photoscore\src\bin\uniffi-bindgen.rs"
if (Test-Path $bindgen) {
    Ok "project uniffi-bindgen present (cargo run -p photoscore --bin uniffi-bindgen)"
} else {
    Fail "core\photoscore\src\bin\uniffi-bindgen.rs not found; is this a full checkout?"
}

Write-Host ""
if ($script:Fails -eq 0) {
    Write-Host "All checks passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "$($script:Fails) check(s) failed." -ForegroundColor Red
    exit 1
}
