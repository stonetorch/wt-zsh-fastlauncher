<#
.SYNOPSIS
    EXTREME robustness: CONFIG FILE TORTURE / RESILIENT PARSING for psmux.

.DESCRIPTION
    Feeds malformed, BOM-laden, mixed-line-ending, empty, recursive, tilde,
    quoted, chained and live-reloaded config files into the psmux server and
    PROVES that:
      - a malformed line never aborts the whole config nor kills the server,
      - VALID directives in the SAME config still take effect,
      - the server stays alive after every torture case.

    Server isolation: dedicated socket namespace "rbCfg" via -L rbCfg on EVERY
    psmux invocation. Config is supplied through PSMUX_CONFIG_FILE before a
    session is created, or hot-applied via source-file. One session at a time.

    Namespaced state files (DOUBLE underscore):
      $env:USERPROFILE\.psmux\rbCfg__<session>.port / .key

    DO NOT run psmux globally. Cleanup is ONLY `& psmux -L rbCfg kill-server`.
#>

$ErrorActionPreference = "Continue"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) {
    $script:TestsPassed++
    Write-Host "PASS: $msg" -ForegroundColor Green
}
function Write-Fail($msg) {
    $script:TestsFailed++
    Write-Host "FAIL: $msg" -ForegroundColor Red
}

# ------------------------------------------------------------------
# Helpers (every psmux call routed through -L rbCfg)
# ------------------------------------------------------------------
$NS = "rbCfg"
$ConfFiles = New-Object System.Collections.Generic.List[string]

function Kill-Server {
    & psmux -L $NS kill-server 2>$null | Out-Null
    Start-Sleep -Seconds 1
}

function Server-Alive($sess) {
    # list-sessions exit 0 == server reachable / alive
    & psmux -L $NS list-sessions 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-Opt($sess, $opt) {
    $out = & psmux -L $NS show-options -g -v $opt -t $sess 2>&1 | Out-String
    return $out.Trim()
}

function Start-WithConfig($sess, $confPath) {
    $env:PSMUX_CONFIG_FILE = $confPath
    & psmux -L $NS new-session -d -s $sess 2>$null | Out-Null
    Start-Sleep -Seconds 3
    $env:PSMUX_CONFIG_FILE = $null
}

function New-Conf($name, $content, [bool]$bom = $false) {
    $p = Join-Path $env:TEMP $name
    if ($bom) {
        $enc = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($p, $content, $enc)
    } else {
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($p, $content, $enc)
    }
    $script:ConfFiles.Add($p)
    return $p
}

Write-Host "=== psmux CONFIG FUZZ / RESILIENT PARSING robustness (-L $NS) ===" -ForegroundColor Cyan

# Clean slate
Kill-Server

# ==================================================================
# Scenario 1: Valid baseline config (sanity that mechanism works)
# ==================================================================
Write-Host "`n--- Scenario 1: Valid baseline config ---" -ForegroundColor Yellow
$sess = "rbCfg_s1"
$c1 = New-Conf "rbcfg_baseline.conf" @"
set -g escape-time 42
set -g status-left "[CFG]"
"@
Start-WithConfig $sess $c1
$et = Get-Opt $sess "escape-time"
$sl = Get-Opt $sess "status-left"
if ($et -eq "42") { Write-Pass "baseline escape-time applied (=42)" } else { Write-Fail "baseline escape-time expected 42 got '$et'" }
if ($sl -match "CFG") { Write-Pass "baseline status-left applied (contains CFG)" } else { Write-Fail "baseline status-left expected CFG got '$sl'" }
if (Server-Alive $sess) { Write-Pass "baseline server alive" } else { Write-Fail "baseline server NOT alive" }
Kill-Server

# ==================================================================
# Scenario 2: Malformed lines interleaved with valid lines
# ==================================================================
Write-Host "`n--- Scenario 2: Malformed mixed with valid ---" -ForegroundColor Yellow
$sess = "rbCfg_s2"
$junk2000 = ("J" * 2000)
$unicodeLine = [char]0x4E2D + [char]0x6587 + [char]0x1F600  # CJK + emoji-ish garbage line
$c2 = New-Conf "rbcfg_mixed.conf" @"
this is not valid
set -g escape-time 77
set -g
set-option
bind-key
$unicodeLine
set -g history-limit 5000
$junk2000
"@
Start-WithConfig $sess $c2
$et = Get-Opt $sess "escape-time"
$hl = Get-Opt $sess "history-limit"
if ($et -eq "77") { Write-Pass "mixed: valid escape-time=77 applied despite junk" } else { Write-Fail "mixed escape-time expected 77 got '$et'" }
if ($hl -eq "5000") { Write-Pass "mixed: valid history-limit=5000 applied despite junk" } else { Write-Fail "mixed history-limit expected 5000 got '$hl'" }
if (Server-Alive $sess) { Write-Pass "mixed: server alive after malformed lines" } else { Write-Fail "mixed: server NOT alive (malformed line aborted config?)" }
Kill-Server

# ==================================================================
# Scenario 3: UTF-8 BOM on first line before a directive
# ==================================================================
Write-Host "`n--- Scenario 3: UTF-8 BOM first line ---" -ForegroundColor Yellow
$sess = "rbCfg_s3"
$c3 = New-Conf "rbcfg_bom.conf" "set -g history-limit 8888`n" $true
Start-WithConfig $sess $c3
$hl = Get-Opt $sess "history-limit"
if ($hl -eq "8888") { Write-Pass "BOM: first directive applied (history-limit=8888)" } else { Write-Fail "BOM: history-limit expected 8888 got '$hl'" }
if (Server-Alive $sess) { Write-Pass "BOM: server alive" } else { Write-Fail "BOM: server NOT alive" }
Kill-Server

# ==================================================================
# Scenario 4: CRLF and LF line endings
# ==================================================================
Write-Host "`n--- Scenario 4a: LF-only line endings ---" -ForegroundColor Yellow
$sess = "rbCfg_s4lf"
$c4lf = New-Conf "rbcfg_lf.conf" "set -g escape-time 401`nset -g history-limit 4010`n"
Start-WithConfig $sess $c4lf
$et = Get-Opt $sess "escape-time"
if ($et -eq "401") { Write-Pass "LF: escape-time=401 applied" } else { Write-Fail "LF: escape-time expected 401 got '$et'" }
if (Server-Alive $sess) { Write-Pass "LF: server alive" } else { Write-Fail "LF: server NOT alive" }
Kill-Server

Write-Host "`n--- Scenario 4b: CRLF line endings ---" -ForegroundColor Yellow
$sess = "rbCfg_s4crlf"
$c4crlf = New-Conf "rbcfg_crlf.conf" "set -g escape-time 402`r`nset -g history-limit 4020`r`n"
Start-WithConfig $sess $c4crlf
$et = Get-Opt $sess "escape-time"
if ($et -eq "402") { Write-Pass "CRLF: escape-time=402 applied" } else { Write-Fail "CRLF: escape-time expected 402 got '$et'" }
if (Server-Alive $sess) { Write-Pass "CRLF: server alive" } else { Write-Fail "CRLF: server NOT alive" }
Kill-Server

# ==================================================================
# Scenario 5: Empty config and comment-only config
# ==================================================================
Write-Host "`n--- Scenario 5a: Empty config file ---" -ForegroundColor Yellow
$sess = "rbCfg_s5empty"
$c5e = New-Conf "rbcfg_empty.conf" ""
Start-WithConfig $sess $c5e
if (Server-Alive $sess) { Write-Pass "empty config: server still starts/alive" } else { Write-Fail "empty config: server NOT alive" }
Kill-Server

Write-Host "`n--- Scenario 5b: Comment-only config file ---" -ForegroundColor Yellow
$sess = "rbCfg_s5comment"
$c5c = New-Conf "rbcfg_comment.conf" "# just a comment`n"
Start-WithConfig $sess $c5c
if (Server-Alive $sess) { Write-Pass "comment-only config: server still starts/alive" } else { Write-Fail "comment-only config: server NOT alive" }
Kill-Server

# ==================================================================
# Scenario 6: source-file LIVE RELOAD
# ==================================================================
Write-Host "`n--- Scenario 6: source-file live reload ---" -ForegroundColor Yellow
$sess = "rbCfg_s6"
$c6 = New-Conf "rbcfg_reload.conf" "set -g status-right `"BEFORE`"`n"
Start-WithConfig $sess $c6
$sr0 = Get-Opt $sess "status-right"
if ($sr0 -match "BEFORE") { Write-Pass "reload: initial status-right=BEFORE applied" } else { Write-Fail "reload: initial status-right expected BEFORE got '$sr0'" }
# rewrite the same file to AFTER and source-file it
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($c6, "set -g status-right `"AFTER`"`n", $enc)
& psmux -L $NS source-file -t $sess $c6 2>$null | Out-Null
Start-Sleep -Seconds 2
$sr1 = Get-Opt $sess "status-right"
if ($sr1 -match "AFTER") { Write-Pass "reload: status-right became AFTER after source-file" } else { Write-Fail "reload: status-right expected AFTER got '$sr1'" }
if (Server-Alive $sess) { Write-Pass "reload: server alive" } else { Write-Fail "reload: server NOT alive" }
Kill-Server

# ==================================================================
# Scenario 7: source-file of a NONEXISTENT path
# ==================================================================
Write-Host "`n--- Scenario 7: source-file nonexistent path ---" -ForegroundColor Yellow
$sess = "rbCfg_s7"
$c7 = New-Conf "rbcfg_s7base.conf" "set -g escape-time 70`n"
Start-WithConfig $sess $c7
$missing = Join-Path $env:TEMP ("rbcfg_does_not_exist_" + (Get-Random) + ".conf")
& psmux -L $NS source-file -t $sess $missing 2>$null | Out-Null
Start-Sleep -Seconds 2
if (Server-Alive $sess) { Write-Pass "nonexistent source-file: server stays alive" } else { Write-Fail "nonexistent source-file: server crashed/NOT alive" }
# prior valid option must still be intact
$et = Get-Opt $sess "escape-time"
if ($et -eq "70") { Write-Pass "nonexistent source-file: prior option (escape-time=70) intact" } else { Write-Fail "nonexistent source-file: escape-time expected 70 got '$et'" }
Kill-Server

# ==================================================================
# Scenario 8: Recursive / self source-file (must not infinite loop)
# ==================================================================
Write-Host "`n--- Scenario 8: recursive self source-file ---" -ForegroundColor Yellow
$sess = "rbCfg_s8"
$c8 = Join-Path $env:TEMP "rbcfg_recursive.conf"
$script:ConfFiles.Add($c8)
$enc = New-Object System.Text.UTF8Encoding($false)
# config sources ITSELF plus sets a verifiable option
$c8content = "set -g escape-time 88`nsource-file `"$c8`"`n"
[System.IO.File]::WriteAllText($c8, $c8content, $enc)
Start-WithConfig $sess $c8
# Give it a few seconds; rely on session readiness + list-sessions, never hang.
Start-Sleep -Seconds 3
if (Server-Alive $sess) { Write-Pass "recursive source-file: server alive (no infinite loop / crash)" } else { Write-Fail "recursive source-file: server NOT alive (possible hang/crash)" }
$et = Get-Opt $sess "escape-time"
if ($et -eq "88") { Write-Pass "recursive source-file: valid directive (escape-time=88) still applied" } else { Write-Fail "recursive source-file: escape-time expected 88 got '$et'" }
Kill-Server

# ==================================================================
# Scenario 9: Tilde expansion in source-file path
# ==================================================================
Write-Host "`n--- Scenario 9: tilde (~) expansion ---" -ForegroundColor Yellow
$sess = "rbCfg_s9"
$tildeReal = Join-Path $env:USERPROFILE ".rbcfg_tilde.conf"
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($tildeReal, "set -g history-limit 9191`n", $enc)
# start with a trivial valid config so a session exists, then source via tilde path
$c9 = New-Conf "rbcfg_s9base.conf" "set -g escape-time 90`n"
Start-WithConfig $sess $c9
& psmux -L $NS source-file -t $sess "~\.rbcfg_tilde.conf" 2>$null | Out-Null
Start-Sleep -Seconds 2
$hl = Get-Opt $sess "history-limit"
if ($hl -eq "9191") { Write-Pass "tilde: ~ path expanded, history-limit=9191 applied" } else { Write-Fail "tilde: history-limit expected 9191 got '$hl'" }
if (Server-Alive $sess) { Write-Pass "tilde: server alive" } else { Write-Fail "tilde: server NOT alive" }
Kill-Server
Remove-Item $tildeReal -Force -ErrorAction SilentlyContinue

# ==================================================================
# Scenario 10: Quoted values with spaces and escaped quotes
# ==================================================================
Write-Host "`n--- Scenario 10: quoted value with escaped quotes ---" -ForegroundColor Yellow
$sess = "rbCfg_s10"
# desired value: a b "c" d  -> in conf: "a b \"c\" d"
$c10 = New-Conf "rbcfg_quoted.conf" "set -g status-left `"a b \`"c\`" d`"`n"
Start-WithConfig $sess $c10
$sl = Get-Opt $sess "status-left"
if (($sl -match "a b") -and ($sl -match "c") -and ($sl -match "d")) { Write-Pass "quoted: escaped-quote value applied (got '$sl')" } else { Write-Fail "quoted: expected 'a b \"c\" d' content got '$sl'" }
if (Server-Alive $sess) { Write-Pass "quoted: server alive" } else { Write-Fail "quoted: server NOT alive" }
Kill-Server

# ==================================================================
# Scenario 11: bind-key from config
# ==================================================================
Write-Host "`n--- Scenario 11: bind-key from config ---" -ForegroundColor Yellow
$sess = "rbCfg_s11"
$c11 = New-Conf "rbcfg_bind.conf" "bind-key F5 split-window -v`n"
Start-WithConfig $sess $c11
$keys = & psmux -L $NS list-keys 2>&1 | Out-String
$f5line = ($keys -split "`n" | Where-Object { $_ -match "F5" }) -join "`n"
if (($f5line -match "F5") -and ($f5line -match "split-window")) { Write-Pass "bind-key: F5 bound to split-window (got '$($f5line.Trim())')" } else { Write-Fail "bind-key: F5->split-window not found in list-keys" }
if (Server-Alive $sess) { Write-Pass "bind-key: server alive" } else { Write-Fail "bind-key: server NOT alive" }
Kill-Server

# ==================================================================
# Scenario 12: Chained config line ( \; separator )
# ==================================================================
Write-Host "`n--- Scenario 12: chained directive (\;) ---" -ForegroundColor Yellow
$sess = "rbCfg_s12"
$c12 = New-Conf "rbcfg_chain.conf" "set -g status-left `"X`" \; set -g status-right `"Y`"`n"
Start-WithConfig $sess $c12
$sl = Get-Opt $sess "status-left"
$sr = Get-Opt $sess "status-right"
if ($sl -match "X") { Write-Pass "chain: status-left=X applied" } else { Write-Fail "chain: status-left expected X got '$sl'" }
if ($sr -match "Y") { Write-Pass "chain: status-right=Y applied (second of chain)" } else { Write-Fail "chain: status-right expected Y got '$sr'" }
if (Server-Alive $sess) { Write-Pass "chain: server alive" } else { Write-Fail "chain: server NOT alive" }
Kill-Server

# ==================================================================
# Cleanup
# ==================================================================
Write-Host "`n--- Cleanup ---" -ForegroundColor Yellow
Kill-Server
foreach ($f in $script:ConfFiles) {
    Remove-Item $f -Force -ErrorAction SilentlyContinue
}
$env:PSMUX_CONFIG_FILE = $null

# ==================================================================
# Results
# ==================================================================
Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "Passed: $script:TestsPassed" -ForegroundColor Green
Write-Host "Failed: $script:TestsFailed" -ForegroundColor Red

exit $script:TestsFailed
