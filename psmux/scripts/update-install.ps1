# Sync this fork's psmux build into the machine-wide install directory.
#
# Run after changing anything under src/, so the copy that PATH and the Windows
# Terminal "Zsh Tmux" profile point at picks the change up:
#
#   pwsh -File scripts/update-install.ps1              # build, then install
#   pwsh -File scripts/update-install.ps1 -SkipBuild   # install the last build as-is
#
# The build target directory matches docs/zsh-pool.md (target\pool-final).

[CmdletBinding()]
param(
    # Must match the entry already on your user PATH.
    [string]$InstallDir = "$env:LOCALAPPDATA\psmux",
    [string]$TargetDir  = "target\pool-final",
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Binaries = @('psmux.exe', 'pmux.exe', 'tmux.exe')

Push-Location $RepoRoot
try {
    if (-not $SkipBuild) {
        Write-Host "Building psmux (release, --bin psmux, target-dir $TargetDir)..." -ForegroundColor Cyan
        & cargo build --release --bin psmux --target-dir $TargetDir
        if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }
    }

    $built = Join-Path $RepoRoot (Join-Path $TargetDir 'release\psmux.exe')
    if (-not (Test-Path $built)) {
        throw "built binary not found: $built`nRun without -SkipBuild, or pass the right -TargetDir."
    }

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

    $running = @(Get-Process -Name psmux, pmux, tmux -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        Write-Host ""
        Write-Host "$($running.Count) psmux process(es) are running." -ForegroundColor Yellow
        Write-Host "A running server locks its own executable, so overwriting it can fail." -ForegroundColor Yellow
        Write-Host "If the copy step errors, run 'psmux kill-server' first (ends your psmux sessions)." -ForegroundColor Yellow
        Write-Host ""
    }

    foreach ($name in $Binaries) {
        Copy-Item -Path $built -Destination (Join-Path $InstallDir $name) -Force
        Write-Host "  $name" -ForegroundColor Green
    }

    # The source-tree-independent entry point; recreate it if the directory was wiped.
    $launcher = Join-Path $InstallDir 'launch-zsh-pool.cmd'
    if (-not (Test-Path $launcher)) {
        Set-Content -Path $launcher -Encoding ascii -Value @(
            '@echo off'
            'setlocal'
            'rem Stable entry point: lives beside psmux.exe, independent of any source tree.'
            'rem Native reuse/new-session entry; keep the default registry and isolate by namespace.'
            '"%~dp0psmux.exe" -L zsh-pool zsh-pool'
            'exit /b %errorlevel%'
        )
        Write-Host "  launch-zsh-pool.cmd (created)" -ForegroundColor Green
    }

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -notlike "*$InstallDir*") {
        Write-Host ""
        Write-Host "$InstallDir is not on your user PATH; add it or 'psmux' will not resolve." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Done. Installed to $InstallDir" -ForegroundColor Green
    Write-Host "Sessions already running keep the old binary until the server restarts (psmux kill-server)." -ForegroundColor Gray
}
finally {
    Pop-Location
}
