# Issue #246: Reproduce sparse-cell rendering artifact
# Hypothesis from issue: snapshot races with reader.read() between chunks of a
# multi-chunk Ink-style frame, latching a partial state where ESC[2K cleared a
# row but only some CUP+text spans have landed.
#
# Strategy:
#   1. Start a psmux session.
#   2. Inside the pane, run a Python emitter that produces frames > 64 KB each,
#      where every row is supposed to end DENSE (80 spans of "#NN" across 200
#      cols) but starts with ESC[2K (clear line).
#   3. From outside, hammer `psmux capture-pane -p` as fast as possible.
#   4. For each capture, score each row's density (non-space cell count). A
#      "sparse anomaly" is a row that has a frame tag context (we're clearly in
#      the middle of a frame) but contains far fewer cells than expected, while
#      OTHER rows are dense. That is the visual bug from the screenshot.
#   5. If ANY capture shows >=1 anomalous row, the bug is reproduced.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "issue246"
$psmuxDir = "$env:USERPROFILE\.psmux"

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

Write-Host "=== Issue #246 reproduction ===" -ForegroundColor Cyan
Cleanup

# Big window so all 30 emitter rows fit
$env:LINES = "50"
$env:COLUMNS = "220"
& $PSMUX new-session -d -s $SESSION -x 220 -y 50
Start-Sleep -Seconds 3
& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: session not created" -ForegroundColor Red; exit 1 }

# Resize again for safety
& $PSMUX resize-window -t $SESSION -x 220 -y 50 2>&1 | Out-Null
Start-Sleep -Milliseconds 500

# Kick off the Python emitter in the pane.
$emitterPath = Join-Path $PSScriptRoot "issue246_emitter.py"
if (-not (Test-Path $emitterPath)) { Write-Host "FAIL: emitter missing at $emitterPath" -ForegroundColor Red; Cleanup; exit 1 }

Write-Host "Launching emitter in pane: 400 frames, 25ms gap" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION "python `"$emitterPath`" 400 25" Enter
# Tiny delay so the python process actually starts emitting
Start-Sleep -Milliseconds 800

# Hammer capture-pane and score density.
$captures = 0
$anomalies = [System.Collections.ArrayList]::new()
$startSw = [System.Diagnostics.Stopwatch]::StartNew()
$lastFrameSeen = -1

# Cap on rows the emitter paints (matches issue246_emitter.py)
$EMIT_ROW_START = 2
$EMIT_ROW_END   = 31  # rows 2..31 inclusive (30 rows)
$DENSE_THRESHOLD = 200  # we expect >=200 non-space chars per painted row (80 spans * ~3 chars + caret)
$SPARSE_THRESHOLD = 80  # below this on a painted row = anomaly
# Wait, our spans write only "#NN" (3 chars) at 80 positions across 200 cols.
# So expected non-space per row ~= 80*3 = 240 chars in best case.
# Reality: spans can overlap columns. Use lower bar: dense >=120, sparse <=40.
$DENSE_THRESHOLD = 120
$SPARSE_THRESHOLD = 40

while ($startSw.Elapsed.TotalSeconds -lt 15) {
    $cap = & $PSMUX capture-pane -t $SESSION -p 2>&1
    if (-not $cap) { continue }
    $captures++
    $lines = $cap -split "`r?`n"

    # Find frame tag line to confirm a frame is being painted
    $frameNo = -1
    foreach ($ln in $lines) {
        if ($ln -match '\[FRAME (\d+)\]') { $frameNo = [int]$matches[1]; break }
    }
    if ($frameNo -lt 0) { continue }
    $lastFrameSeen = $frameNo

    # Score each painted row
    $denseRows = 0
    $sparseRows = 0
    $sparseDetail = @()
    for ($r = 0; $r -lt $lines.Count; $r++) {
        $line = $lines[$r]
        if ([string]::IsNullOrEmpty($line)) { continue }
        # Only score lines that look like emitter rows: contain "#" markers OR are surrounded by such rows
        # Quick heuristic: row contains at least one "#NN" pattern OR is entirely blank between dense neighbours
        $nonSpace = ($line.ToCharArray() | Where-Object { $_ -ne ' ' -and $_ -ne "`t" }).Count
        $hasMarker = ($line -match '#\d\d')
        if ($hasMarker -and $nonSpace -ge $DENSE_THRESHOLD) { $denseRows++ }
        elseif ($hasMarker -and $nonSpace -le $SPARSE_THRESHOLD) {
            $sparseRows++
            $sparseDetail += "row=$r nonSpace=$nonSpace text=[$($line.Substring(0,[Math]::Min(120,$line.Length)))]"
        }
    }

    if ($sparseRows -ge 1 -and $denseRows -ge 5) {
        # Anomaly: while most rows are dense, at least one row is sparse mid-frame
        $rec = [PSCustomObject]@{
            Capture = $captures
            Frame   = $frameNo
            DenseRows = $denseRows
            SparseRows = $sparseRows
            Detail = $sparseDetail
        }
        [void]$anomalies.Add($rec)
        Write-Host ("[ANOMALY #{0}] frame={1} dense={2} sparse={3}" -f $captures, $frameNo, $denseRows, $sparseRows) -ForegroundColor Magenta
        foreach ($d in $sparseDetail) { Write-Host "    $d" -ForegroundColor DarkMagenta }
        if ($anomalies.Count -ge 5) { break }  # plenty of evidence
    }
}
$startSw.Stop()

Write-Host ""
Write-Host "=== Reproduction summary ===" -ForegroundColor Cyan
Write-Host ("Captures taken : {0}" -f $captures)
Write-Host ("Last frame seen: {0}" -f $lastFrameSeen)
$anomColor = if ($anomalies.Count -gt 0) { "Magenta" } else { "Green" }
Write-Host ("Anomalies      : {0}" -f $anomalies.Count) -ForegroundColor $anomColor

if ($anomalies.Count -gt 0) {
    Write-Host ""
    Write-Host "BUG REPRODUCED: at least one captured frame shows the issue #246 sparse-row pattern." -ForegroundColor Magenta
    # Persist evidence outside repo tree
    $evidenceDir = "$env:USERPROFILE\.psmux-test-data\issue246"
    New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
    $evFile = Join-Path $evidenceDir ("repro-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $anomalies | ConvertTo-Json -Depth 6 | Set-Content $evFile -Encoding UTF8
    Write-Host "Evidence saved: $evFile" -ForegroundColor DarkGray
} else {
    Write-Host ""
    Write-Host "NOT REPRODUCED in this run. Rerun or tune emitter timing." -ForegroundColor Yellow
}

Cleanup
exit 0
