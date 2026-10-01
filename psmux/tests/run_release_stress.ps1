# run_release_stress.ps1
# Release-readiness master runner: executes every namespaced robustness suite
# SERIALLY (they each use their own -L socket namespace, so they never collide
# and never global-kill). Aggregates pass/fail per suite and overall.
#
# Each child suite exits with its failure count; we capture that plus parse the
# "Passed:"/"Failed:" footer lines so a non-zero exit with unparseable output is
# still surfaced as a failure.

$ErrorActionPreference = "Continue"
$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$suites = @(
    "test_robust_scale.ps1",
    "test_robust_churn.ps1",
    "test_robust_race.ps1",
    "test_robust_flood.ps1",
    "test_robust_tcp.ps1",
    "test_robust_argfuzz.ps1",
    "test_robust_unicode.ps1",
    "test_robust_configfuzz.ps1",
    "test_robust_tui_proof.ps1"
)

$results = @()
$grandPass = 0
$grandFail = 0
$startAll = Get-Date

foreach ($s in $suites) {
    $path = Join-Path $testsDir $s
    if (-not (Test-Path $path)) {
        Write-Host "MISSING SUITE: $s" -ForegroundColor Red
        $results += [PSCustomObject]@{ Suite=$s; Pass=0; Fail=-1; Exit=-1; Secs=0 }
        $grandFail++
        continue
    }
    Write-Host ""
    Write-Host ("#" * 78) -ForegroundColor DarkCyan
    Write-Host "# RUNNING: $s" -ForegroundColor Cyan
    Write-Host ("#" * 78) -ForegroundColor DarkCyan

    $t0 = Get-Date
    $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $path 2>&1 | Out-String
    $exit = $LASTEXITCODE
    $secs = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    Write-Host $out

    # Parse footer counts (last occurrence wins).
    $p = 0; $f = 0
    $pm = [regex]::Matches($out, "(?im)^\s*Passed:\s*(\d+)")
    $fm = [regex]::Matches($out, "(?im)^\s*Failed:\s*(\d+)")
    if ($pm.Count -gt 0) { $p = [int]$pm[$pm.Count-1].Groups[1].Value }
    if ($fm.Count -gt 0) { $f = [int]$fm[$fm.Count-1].Groups[1].Value }

    # If the process exit code disagrees (e.g. crash with no footer), trust the worse.
    if ($exit -ne 0 -and $f -eq 0) { $f = $exit }

    $results += [PSCustomObject]@{ Suite=$s; Pass=$p; Fail=$f; Exit=$exit; Secs=$secs }
    $grandPass += $p
    $grandFail += $f
}

$totalSecs = [math]::Round(((Get-Date) - $startAll).TotalSeconds, 1)

Write-Host ""
Write-Host ("=" * 78) -ForegroundColor Yellow
Write-Host " RELEASE STRESS SUITE SUMMARY" -ForegroundColor Yellow
Write-Host ("=" * 78) -ForegroundColor Yellow
foreach ($r in $results) {
    $color = if ($r.Fail -eq 0) { "Green" } else { "Red" }
    Write-Host ("  {0,-32} pass={1,-4} fail={2,-4} exit={3,-3} {4,6}s" -f $r.Suite, $r.Pass, $r.Fail, $r.Exit, $r.Secs) -ForegroundColor $color
}
Write-Host ("-" * 78)
$gc = if ($grandFail -eq 0) { "Green" } else { "Red" }
Write-Host ("  GRAND TOTAL  pass={0}  fail={1}  ({2}s)" -f $grandPass, $grandFail, $totalSecs) -ForegroundColor $gc

exit $grandFail
