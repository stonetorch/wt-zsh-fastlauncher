#!/usr/bin/env pwsh
# =============================================================================
# test_robust_unicode.ps1 - EXTREME ROBUSTNESS: Unicode / wide-char / control-char
# Thesis: psmux correctly handles non-ASCII in names and pane content.
#
# Namespace: -L rbUni (DOUBLE-underscore namespaced files at
#            $env:USERPROFILE\.psmux\rbUni__<session>.port / .key)
# RULES: never global kill-server; never Get-Process|Stop-Process. Cleanup is
#        ONLY `& psmux -L rbUni kill-server` in finally. 1-2 sessions max.
# Each scenario proves the EXPECTED text round-trips, not merely "no crash".
# =============================================================================

# --- Encoding setup so unicode round-trips through the CLI -------------------
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$ErrorActionPreference = "Continue"

$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  PASS: $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  FAIL: $msg" -ForegroundColor Red;   $script:TestsFailed++ }

# psmux is on PATH. EVERY call passes -L rbUni FIRST.
$L = @("-L", "rbUni")
$MAIN = "rbUni_main"

# Poll capture-pane (active pane of $target) until $needle appears or timeout.
function Wait-ForCapture {
    param(
        [string]$Target,
        [string]$Needle,
        [int]$TimeoutSec = 20
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $last = ""
    while ((Get-Date) -lt $deadline) {
        $last = (& psmux @L capture-pane -t $Target -p 2>&1 | Out-String)
        if ($last -match [regex]::Escape($Needle)) { return @{ Found = $true; Text = $last } }
        Start-Sleep -Milliseconds 500
    }
    return @{ Found = $false; Text = $last }
}

# Build unicode strings from codepoints (avoid file-encoding ambiguity).
$emojiRocket = [char]::ConvertFromUtf32(0x1F680)   # ROCKET
$emojiGrin   = [char]::ConvertFromUtf32(0x1F600)   # GRINNING FACE
$emojiParty  = [char]::ConvertFromUtf32(0x1F389)   # PARTY POPPER
$cjkTest     = [char]::ConvertFromUtf32(0x6D4B) + [char]::ConvertFromUtf32(0x8BD5)  # 测试
$cafe        = "caf" + [char]::ConvertFromUtf32(0x00E9)            # cafe-acute
# Window name = rocket + CJK + accented latin
$winName     = "$emojiRocket$cjkTest$cafe"

# Session name: accented latin only (filesystem-safe-ish)
$accentSess  = "caf" + [char]::ConvertFromUtf32(0x00E9) + "_na" + `
               [char]::ConvertFromUtf32(0x00EF) + "ve_" + `
               [char]::ConvertFromUtf32(0x00DC) + "n" + `
               [char]::ConvertFromUtf32(0x00EF) + "c" + `
               [char]::ConvertFromUtf32(0x00F6) + "d" + `
               [char]::ConvertFromUtf32(0x00E9)            # cafe_naive_Unicode (accented)
# CJK session name
$cjkSess     = [char]::ConvertFromUtf32(0x4E2D) + [char]::ConvertFromUtf32(0x6587)  # 中文

# Pane content building blocks
$emojiLine   = "EMOJI_BEGIN $emojiGrin$emojiParty$emojiRocket EMOJI_END"
$cjkHello    = ([char]::ConvertFromUtf32(0x4F60) + [char]::ConvertFromUtf32(0x597D) + `
                [char]::ConvertFromUtf32(0x4E16) + [char]::ConvertFromUtf32(0x754C)) + " " + `
               ([char]::ConvertFromUtf32(0x3053) + [char]::ConvertFromUtf32(0x3093) + `
                [char]::ConvertFromUtf32(0x306B) + [char]::ConvertFromUtf32(0x3061) + `
                [char]::ConvertFromUtf32(0x306F)) + " " + `
               ([char]::ConvertFromUtf32(0xC548) + [char]::ConvertFromUtf32(0xB155) + `
                [char]::ConvertFromUtf32(0xD558) + [char]::ConvertFromUtf32(0xC138) + `
                [char]::ConvertFromUtf32(0xC694))   # 你好世界 こんにちは 안녕하세요

# Combining / zalgo: base "e" + several combining diacriticals
$combining   = "e" + [char]::ConvertFromUtf32(0x0301) + [char]::ConvertFromUtf32(0x0300) + `
               [char]::ConvertFromUtf32(0x0302) + [char]::ConvertFromUtf32(0x0303) + `
               [char]::ConvertFromUtf32(0x0308)

# RTL: Hebrew "shalom olam"
$rtl         = [char]::ConvertFromUtf32(0x05E9) + [char]::ConvertFromUtf32(0x05DC) + `
               [char]::ConvertFromUtf32(0x05D5) + [char]::ConvertFromUtf32(0x05DD) + " " + `
               [char]::ConvertFromUtf32(0x05E2) + [char]::ConvertFromUtf32(0x05D5) + `
               [char]::ConvertFromUtf32(0x05DC) + [char]::ConvertFromUtf32(0x05DD)

Write-Host "`n=== psmux UNICODE / WIDE-CHAR ROBUSTNESS (-L rbUni) ===" -ForegroundColor Cyan

try {
    # -------------------------------------------------------------------------
    # SETUP: detached session rbUni_main
    # -------------------------------------------------------------------------
    Write-Host "`n--- SETUP: new-session -d -s $MAIN ---" -ForegroundColor Yellow
    & psmux @L new-session -d -s $MAIN -x 200 -y 50 2>&1 | Out-Null
    Start-Sleep -Seconds 3

    & psmux @L has-session -t $MAIN 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Pass "session $MAIN created and alive" }
    else { Write-Fail "session $MAIN did NOT come up" }

    # -------------------------------------------------------------------------
    # SCENARIO 1: WINDOW NAME UNICODE (emoji + CJK + accented latin)
    # -------------------------------------------------------------------------
    Write-Host "`n--- SCENARIO 1: WINDOW NAME UNICODE ---" -ForegroundColor Yellow
    & psmux @L rename-window -t $MAIN $winName 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    $readWin = (& psmux @L display-message -t $MAIN -p '#{window_name}' 2>&1 | Out-String).Trim()
    Write-Host "    set : [$winName]"
    Write-Host "    read: [$readWin]"
    # Wide chars must be preserved: assert the CJK and accented parts round-trip.
    if ($readWin -match [regex]::Escape($cjkTest)) { Write-Pass "window name preserves CJK ($cjkTest)" }
    else { Write-Fail "window name lost CJK" }
    if ($readWin -match [regex]::Escape($cafe)) { Write-Pass "window name preserves accented latin ($cafe)" }
    else { Write-Fail "window name lost accented latin" }
    if ($readWin -match [regex]::Escape($emojiRocket)) { Write-Pass "window name preserves emoji rocket" }
    else { Write-Fail "window name lost emoji rocket" }

    # -------------------------------------------------------------------------
    # SCENARIO 2: SESSION NAME UNICODE (accented latin + a CJK session)
    # Server must round-trip OR reject gracefully while staying alive.
    # -------------------------------------------------------------------------
    Write-Host "`n--- SCENARIO 2: SESSION NAME UNICODE ---" -ForegroundColor Yellow

    # 2a: accented-latin session name
    & psmux @L new-session -d -s $accentSess -x 100 -y 30 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    & psmux @L has-session -t $accentSess 2>&1 | Out-Null
    $accentExists = ($LASTEXITCODE -eq 0)
    if ($accentExists) {
        Write-Pass "accented-latin session has-session succeeds"
        $readSess = (& psmux @L display-message -t $accentSess -p '#{session_name}' 2>&1 | Out-String).Trim()
        Write-Host "    set : [$accentSess]"
        Write-Host "    read: [$readSess]"
        if ($readSess -eq $accentSess) { Write-Pass "accented session_name round-trips exactly" }
        else { Write-Fail "accented session_name mismatch (read [$readSess])" }
        # keep resource ceiling: drop this extra session immediately
        & psmux @L kill-session -t $accentSess 2>&1 | Out-Null
    } else {
        Write-Host "    (server declined accented session name)" -ForegroundColor DarkGray
    }

    # 2b: CJK session name -- accept either round-trip or graceful rejection,
    #     but the server MUST stay alive afterward.
    & psmux @L new-session -d -s $cjkSess -x 100 -y 30 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    & psmux @L has-session -t $cjkSess 2>&1 | Out-Null
    $cjkExists = ($LASTEXITCODE -eq 0)
    if ($cjkExists) {
        $readCjkSess = (& psmux @L display-message -t $cjkSess -p '#{session_name}' 2>&1 | Out-String).Trim()
        if ($readCjkSess -match [regex]::Escape($cjkSess)) { Write-Pass "CJK session_name round-trips" }
        else { Write-Fail "CJK session_name mismatch (read [$readCjkSess])" }
        & psmux @L kill-session -t $cjkSess 2>&1 | Out-Null
    } else {
        Write-Host "    (server declined CJK session name -- acceptable if graceful)" -ForegroundColor DarkGray
    }
    # Critical: server still alive after the name experiments.
    & psmux @L has-session -t $MAIN 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Pass "server alive after session-name experiments" }
    else { Write-Fail "server NOT alive after session-name experiments" }

    # -------------------------------------------------------------------------
    # SCENARIO 3: PANE CONTENT EMOJI (echo multiple emoji, poll capture)
    # -------------------------------------------------------------------------
    Write-Host "`n--- SCENARIO 3: PANE CONTENT EMOJI ---" -ForegroundColor Yellow
    & psmux @L send-keys -t $MAIN "echo $emojiLine" Enter 2>&1 | Out-Null
    $r = Wait-ForCapture -Target $MAIN -Needle "EMOJI_END"
    if ($r.Found) {
        Write-Pass "emoji echo line appeared (markers present)"
        $okGrin  = $r.Text -match [regex]::Escape($emojiGrin)
        $okParty = $r.Text -match [regex]::Escape($emojiParty)
        $okRck   = $r.Text -match [regex]::Escape($emojiRocket)
        if ($okGrin -and $okParty -and $okRck) { Write-Pass "all three emoji present in capture" }
        else { Write-Fail "missing emoji in capture (grin=$okGrin party=$okParty rocket=$okRck)" }
    } else { Write-Fail "emoji line never appeared in capture-pane" }

    # -------------------------------------------------------------------------
    # SCENARIO 4: CJK WIDE CHARS (double-width)
    # -------------------------------------------------------------------------
    Write-Host "`n--- SCENARIO 4: CJK WIDE CHARS ---" -ForegroundColor Yellow
    & psmux @L send-keys -t $MAIN "echo CJK_MARK $cjkHello CJK_TAIL" Enter 2>&1 | Out-Null
    $r = Wait-ForCapture -Target $MAIN -Needle "CJK_TAIL"
    if ($r.Found) {
        Write-Pass "CJK echo line appeared"
        $ni = [char]::ConvertFromUtf32(0x4F60)  # 你
        $ko = [char]::ConvertFromUtf32(0xC548)  # 안
        $ja = [char]::ConvertFromUtf32(0x3053)  # こ
        if (($r.Text -match [regex]::Escape($ni)) -and ($r.Text -match [regex]::Escape($ja)) -and ($r.Text -match [regex]::Escape($ko))) {
            Write-Pass "CJK/Hiragana/Hangul characters present in capture"
        } else { Write-Fail "wide chars missing from capture" }
    } else { Write-Fail "CJK line never appeared in capture-pane" }

    # -------------------------------------------------------------------------
    # SCENARIO 5: COMBINING / ZALGO diacriticals
    # -------------------------------------------------------------------------
    Write-Host "`n--- SCENARIO 5: COMBINING / ZALGO ---" -ForegroundColor Yellow
    & psmux @L send-keys -t $MAIN "echo ZAL_HEAD $combining ZAL_FOOT" Enter 2>&1 | Out-Null
    $r = Wait-ForCapture -Target $MAIN -Needle "ZAL_FOOT"
    if ($r.Found) {
        Write-Pass "combining-char line returned from capture without error"
        # base letter 'e' between the markers should survive
        if ($r.Text -match "ZAL_HEAD\s+e") { Write-Pass "base text (e) preserved under combining marks" }
        else { Write-Fail "base text lost under combining marks" }
    } else { Write-Fail "combining line never appeared in capture-pane" }

    # -------------------------------------------------------------------------
    # SCENARIO 6: RTL (Hebrew)
    # -------------------------------------------------------------------------
    Write-Host "`n--- SCENARIO 6: RTL ---" -ForegroundColor Yellow
    & psmux @L send-keys -t $MAIN "echo RTL_HEAD $rtl RTL_FOOT" Enter 2>&1 | Out-Null
    $r = Wait-ForCapture -Target $MAIN -Needle "RTL_FOOT"
    if ($r.Found) {
        Write-Pass "RTL line appeared"
        $shin = [char]::ConvertFromUtf32(0x05E9)  # ש
        if ($r.Text -match [regex]::Escape($shin)) { Write-Pass "Hebrew characters present in capture" }
        else { Write-Fail "Hebrew characters missing from capture" }
    } else { Write-Fail "RTL line never appeared in capture-pane" }

    # -------------------------------------------------------------------------
    # SCENARIO 7: MIXED WIDTH ALIGNMENT (ascii + CJK + emoji, then a row of #)
    # Proving no crash + content preservation (not pixel alignment).
    # -------------------------------------------------------------------------
    Write-Host "`n--- SCENARIO 7: MIXED WIDTH ALIGNMENT ---" -ForegroundColor Yellow
    $mixed = "MIX abc $cjkTest $emojiRocket xyz MIX_TAIL"
    & psmux @L send-keys -t $MAIN "echo $mixed" Enter 2>&1 | Out-Null
    $r = Wait-ForCapture -Target $MAIN -Needle "MIX_TAIL"
    $mixOk = $r.Found -and ($r.Text -match [regex]::Escape($cjkTest)) -and ($r.Text -match [regex]::Escape($emojiRocket))
    if ($mixOk) { Write-Pass "mixed-width line preserved (ascii+CJK+emoji)" }
    else { Write-Fail "mixed-width line not fully preserved" }

    $hashes = ("#" * 40)
    & psmux @L send-keys -t $MAIN "echo HASHROW $hashes HASH_TAIL" Enter 2>&1 | Out-Null
    $r2 = Wait-ForCapture -Target $MAIN -Needle "HASH_TAIL"
    if ($r2.Found -and ($r2.Text -match [regex]::Escape($hashes))) { Write-Pass "hash row appeared after mixed line" }
    else { Write-Fail "hash row missing after mixed line" }

    # -------------------------------------------------------------------------
    # SCENARIO 8: CONTROL CHARS IN send-keys (tab + others), pane still works
    # -------------------------------------------------------------------------
    Write-Host "`n--- SCENARIO 8: CONTROL CHARS IN send-keys ---" -ForegroundColor Yellow
    $tab = [char]9
    $ctrlLine = "CTRL_A${tab}CTRL_B${tab}CTRL_C"
    # send the control-laden string literally (-l), no Enter
    & psmux @L send-keys -t $MAIN -l $ctrlLine 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    # clear the input line so the marker echo is clean
    & psmux @L send-keys -t $MAIN C-c 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    & psmux @L send-keys -t $MAIN "echo CTRL_AFTER_MARKER" Enter 2>&1 | Out-Null
    $r = Wait-ForCapture -Target $MAIN -Needle "CTRL_AFTER_MARKER"
    if ($r.Found) { Write-Pass "pane still works after control-char send-keys (marker echoed)" }
    else { Write-Fail "pane unresponsive after control-char send-keys" }

    # -------------------------------------------------------------------------
    # SCENARIO 9: VERY LONG UNICODE LINE (~5000 graphemes), trailing marker
    # -------------------------------------------------------------------------
    Write-Host "`n--- SCENARIO 9: VERY LONG UNICODE LINE ---" -ForegroundColor Yellow
    $unit = $cjkTest + $emojiRocket          # small wide unit
    $longBody = $unit * 2500                  # ~5000 graphemes
    # echo with a unique trailing marker; we only assert the tail survives.
    & psmux @L send-keys -t $MAIN -l "echo LONGUNI $longBody LONGUNI_TAIL" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    & psmux @L send-keys -t $MAIN Enter 2>&1 | Out-Null
    $r = Wait-ForCapture -Target $MAIN -Needle "LONGUNI_TAIL" -TimeoutSec 30
    if ($r.Found) { Write-Pass "very long unicode line: trailing marker present (no overflow crash)" }
    else { Write-Fail "very long unicode line: trailing marker NOT found" }
    # server still alive after the long line?
    & psmux @L has-session -t $MAIN 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Pass "server alive after very long unicode line" }
    else { Write-Fail "server dead after very long unicode line" }

    # -------------------------------------------------------------------------
    # SCENARIO 10: STATUS-LEFT UNICODE round-trip via show-options
    # -------------------------------------------------------------------------
    Write-Host "`n--- SCENARIO 10: STATUS-LEFT UNICODE ---" -ForegroundColor Yellow
    $statusVal = "$emojiRocket $cjkTest $cafe SL_TAIL"
    & psmux @L set-option -g status-left $statusVal 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    $readSL = (& psmux @L show-options -g -v status-left 2>&1 | Out-String).Trim()
    Write-Host "    set : [$statusVal]"
    Write-Host "    read: [$readSL]"
    if ($readSL -eq $statusVal) { Write-Pass "status-left unicode round-trips exactly" }
    elseif (($readSL -match [regex]::Escape($cjkTest)) -and ($readSL -match [regex]::Escape($emojiRocket)) -and ($readSL -match "SL_TAIL")) {
        Write-Pass "status-left preserves emoji+CJK+marker (whitespace-normalized)"
    } else { Write-Fail "status-left unicode did not round-trip" }

    # -------------------------------------------------------------------------
    # FINAL: server alive and prompt works
    # -------------------------------------------------------------------------
    Write-Host "`n--- FINAL: server alive + prompt works ---" -ForegroundColor Yellow
    & psmux @L send-keys -t $MAIN "echo FINAL_OK" Enter 2>&1 | Out-Null
    $r = Wait-ForCapture -Target $MAIN -Needle "FINAL_OK"
    if ($r.Found) { Write-Pass "FINAL_OK echoed -- prompt responsive at end" }
    else { Write-Fail "FINAL_OK never appeared -- prompt unresponsive at end" }
    & psmux @L has-session -t $MAIN 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Pass "server alive at end of suite" }
    else { Write-Fail "server NOT alive at end of suite" }
}
catch {
    Write-Fail "UNEXPECTED EXCEPTION: $($_.Exception.Message)"
}
finally {
    Write-Host "`n--- CLEANUP: kill-server (-L rbUni only) ---" -ForegroundColor Yellow
    & psmux -L rbUni kill-server 2>&1 | Out-Null
}

# =============================================================================
# === Results ===
# =============================================================================
Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $script:TestsPassed" -ForegroundColor Green
Write-Host "  Failed: $script:TestsFailed" -ForegroundColor $(if ($script:TestsFailed -eq 0) { "Green" } else { "Red" })
Write-Host "  Total : $($script:TestsPassed + $script:TestsFailed)"

exit $script:TestsFailed
