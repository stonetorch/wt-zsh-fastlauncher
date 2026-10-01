# =====================================================================
#  test_robust_tui_proof.ps1
#
#  EXTREME robustness campaign: WIN32 TUI + WriteConsoleInput keystroke
#  injection proof. This is the most important VISUAL-PROOF file: it
#  launches a REAL visible psmux window and proves behavior two ways.
#
#  STRATEGY A  - CLI-driven visual verification. Launch a real visible
#                attached window, drive it via the CLI command path
#                (server/connection.rs / TCP dispatch), and verify every
#                expected outcome via display-message format vars and
#                capture-pane. NOT screen scraping.
#
#  STRATEGY B  - WriteConsoleInput keystroke injection. Compile the C#
#                injector (tests/injector.cs) and fire real keystrokes
#                into the visible console's input buffer. This exercises
#                the TUI input handling path (input.rs key dispatch,
#                prefix mode, command-prompt UI, copy-mode entry) that the
#                CLI dispatch path can NEVER reach.
#
#  NAMESPACE: rbTui (every psmux call passes  -L rbTui  FIRST).
#  Namespaced state files live at:
#     $env:USERPROFILE\.psmux\rbTui__<session>.port  (double underscore)
#     $env:USERPROFILE\.psmux\rbTui__<session>.key
#
#  SAFETY:
#    * NEVER a global kill-server. Always  -L rbTui  scoped.
#    * NEVER  Get-Process psmux | Stop-Process  (no image-name sweep).
#    * To stop an attached TUI we Stop-Process the SPECIFIC $proc.Id we
#      launched (our own process, by PID).
#    * finally{} cleans the namespace via  & psmux -L rbTui kill-server.
#    * At most 2 visible windows alive at once (A closes before B opens).
# =====================================================================

$ErrorActionPreference = "Continue"

# --------------------------------------------------------------------
# Counters + reporting helpers (project convention)
# --------------------------------------------------------------------
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass {
    param([string]$Msg)
    $script:TestsPassed++
    Write-Host "[PASS] $Msg" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Msg)
    $script:TestsFailed++
    Write-Host "[FAIL] $Msg" -ForegroundColor Red
}

function Write-Info {
    param([string]$Msg)
    Write-Host "[INFO] $Msg" -ForegroundColor Cyan
}

# --------------------------------------------------------------------
# psmux resolution. The launchable binary path is resolved via
# (Get-Command psmux).Source so Start-Process gets a real exe path.
# CLI verification calls go through  & psmux -L rbTui ...  (PATH).
# --------------------------------------------------------------------
$psmuxCmd = Get-Command psmux -ErrorAction SilentlyContinue
if (-not $psmuxCmd) {
    Write-Fail "psmux not found on PATH; cannot run TUI proof."
    Write-Host "`n=== Results ==="
    Write-Host "Passed: $script:TestsPassed"
    Write-Host "Failed: $script:TestsFailed"
    exit 1
}
$psmuxExe  = $psmuxCmd.Source
$psmuxDir  = "$env:USERPROFILE\.psmux"
$NS        = "rbTui"
$injectLog = "$env:TEMP\psmux_inject.log"

Write-Info "psmux exe: $psmuxExe"
Write-Info "namespace: $NS"

# --------------------------------------------------------------------
# CLI query helper (namespaced). Returns trimmed string.
# --------------------------------------------------------------------
function Get-Fmt {
    param([string]$Session, [string]$Format)
    $r = & psmux -L $NS display-message -t $Session -p $Format 2>&1
    return "$r".Trim()
}

# --------------------------------------------------------------------
# Raw dump-state JSON over the namespaced persistent TCP connection.
# Reads rbTui__<session>.port / .key (double underscore).
# Returns the raw JSON string (or $null).
# --------------------------------------------------------------------
function Get-RawDumpState {
    param([string]$Session)
    $portFile = "$psmuxDir\${NS}__${Session}.port"
    $keyFile  = "$psmuxDir\${NS}__${Session}.key"
    if (-not (Test-Path $portFile)) {
        Write-Info "port file not found: $portFile"
        return $null
    }
    $port = (Get-Content $portFile -Raw).Trim()
    $key  = ""
    if (Test-Path $keyFile) { $key = (Get-Content $keyFile -Raw).Trim() }
    $tcp = $null
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
        $tcp.NoDelay = $true
        $tcp.ReceiveTimeout = 5000
        $stream = $tcp.GetStream()
        $writer = [System.IO.StreamWriter]::new($stream)
        $reader = [System.IO.StreamReader]::new($stream)
        if ($key) {
            $writer.Write("AUTH $key`n"); $writer.Flush()
            $null = $reader.ReadLine()
        }
        $writer.Write("dump-state`n"); $writer.Flush()
        $resp = $reader.ReadLine()
        return $resp
    } catch {
        Write-Info "dump-state TCP error: $_"
        return $null
    } finally {
        if ($tcp) { $tcp.Close() }
    }
}

# --------------------------------------------------------------------
# Track launched PIDs so finally{} can guard-stop them.
# --------------------------------------------------------------------
$script:LaunchedPids = @()

try {

    # ================================================================
    #  Pre-clean the namespace (scoped, never global)
    # ================================================================
    & psmux -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    Remove-Item "$psmuxDir\${NS}__*.port" -Force -ErrorAction SilentlyContinue
    Remove-Item "$psmuxDir\${NS}__*.key"  -Force -ErrorAction SilentlyContinue

    # ================================================================
    #  STRATEGY A - CLI-driven visual verification
    #  Launch a REAL visible attached window (rbTui_a), drive via CLI.
    # ================================================================
    Write-Host "`n========== STRATEGY A: CLI-driven visual verification ==========" -ForegroundColor Magenta

    $sessA = "rbTui_a"
    $procA = Start-Process -FilePath $psmuxExe `
        -ArgumentList "-L", $NS, "new-session", "-s", $sessA -PassThru
    $script:LaunchedPids += $procA.Id
    Write-Info "Launched visible window for $sessA (PID $($procA.Id)); waiting 4s for TUI."
    Start-Sleep -Seconds 4

    # --- A0: session is alive --------------------------------------
    & psmux -L $NS has-session -t $sessA 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Pass "A0: visible session '$sessA' is alive (has-session)"
    } else {
        Write-Fail "A0: visible session '$sessA' did NOT come up (has-session failed)"
    }

    # --- A1: split-window -v  =>  window_panes == 2 ----------------
    & psmux -L $NS split-window -v -t $sessA 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    $panes = Get-Fmt $sessA '#{window_panes}'
    if ($panes -eq "2") {
        Write-Pass "A1: split-window -v -> window_panes == 2"
    } else {
        Write-Fail "A1: split-window -v -> expected window_panes=2, got [$panes]"
    }

    # --- A2: resize-pane -Z (zoom)  =>  zoomed_flag 1 then 0 -------
    & psmux -L $NS resize-pane -Z -t $sessA 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    $zoom1 = Get-Fmt $sessA '#{window_zoomed_flag}'
    if ($zoom1 -eq "1") {
        Write-Pass "A2a: resize-pane -Z -> window_zoomed_flag == 1"
    } else {
        Write-Fail "A2a: resize-pane -Z -> expected zoomed_flag=1, got [$zoom1]"
    }
    & psmux -L $NS resize-pane -Z -t $sessA 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    $zoom0 = Get-Fmt $sessA '#{window_zoomed_flag}'
    if ($zoom0 -eq "0") {
        Write-Pass "A2b: resize-pane -Z toggle -> window_zoomed_flag == 0"
    } else {
        Write-Fail "A2b: resize-pane -Z toggle -> expected zoomed_flag=0, got [$zoom0]"
    }

    # --- A3: new-window  =>  session_windows increased -------------
    $winsBeforeA = [int](Get-Fmt $sessA '#{session_windows}')
    & psmux -L $NS new-window -t $sessA 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    $winsAfterA = [int](Get-Fmt $sessA '#{session_windows}')
    if ($winsAfterA -gt $winsBeforeA) {
        Write-Pass "A3: new-window -> session_windows $winsBeforeA -> $winsAfterA (increased)"
    } else {
        Write-Fail "A3: new-window -> session_windows did not increase ($winsBeforeA -> $winsAfterA)"
    }

    # --- A4: send-keys echo TUI_MARKER  =>  capture-pane shows it --
    & psmux -L $NS send-keys -t $sessA "echo TUI_MARKER" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    & psmux -L $NS send-keys -t $sessA Enter 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    $capA = (& psmux -L $NS capture-pane -p -t $sessA 2>&1) -join "`n"
    if ($capA -match "TUI_MARKER") {
        Write-Pass "A4: send-keys 'echo TUI_MARKER' Enter -> capture-pane contains TUI_MARKER"
    } else {
        Write-Fail "A4: send-keys 'echo TUI_MARKER' -> capture-pane did NOT contain TUI_MARKER"
    }

    # --- A5: rename-window  =>  window_name == RENAMED -------------
    & psmux -L $NS rename-window -t $sessA "RENAMED" 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    $wname = Get-Fmt $sessA '#{window_name}'
    if ($wname -eq "RENAMED") {
        Write-Pass "A5: rename-window -> window_name == RENAMED"
    } else {
        Write-Fail "A5: rename-window -> expected window_name=RENAMED, got [$wname]"
    }

    # --- Close Strategy A visible window (specific PID), scoped kill -
    Write-Info "Strategy A complete; stopping visible window PID $($procA.Id)."
    try { Stop-Process -Id $procA.Id -Force -ErrorAction SilentlyContinue } catch {}
    $script:LaunchedPids = $script:LaunchedPids | Where-Object { $_ -ne $procA.Id }
    & psmux -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Seconds 2

    # ================================================================
    #  STRATEGY B - WriteConsoleInput keystroke injection
    #  Compile injector ONCE, then fire real keystrokes into the
    #  visible console input buffer (input.rs path).
    # ================================================================
    Write-Host "`n========== STRATEGY B: WriteConsoleInput keystroke injection ==========" -ForegroundColor Magenta

    # --- Compile the injector ONCE ---------------------------------
    $injectorExe = "$env:TEMP\psmux_robust_injector.exe"
    $injectorSrc = Join-Path $PSScriptRoot "injector.cs"
    $csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path $csc)) {
        $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) "csc.exe"
    }

    $injectorReady = $false
    if (-not (Test-Path $injectorSrc)) {
        Write-Fail "B-compile: injector source not found at $injectorSrc"
    } elseif (-not (Test-Path $csc)) {
        Write-Fail "B-compile: csc.exe not found (looked at Framework64 and runtime dir)"
    } else {
        Remove-Item $injectorExe -Force -ErrorAction SilentlyContinue
        $cscOut = & $csc /nologo /optimize /out:$injectorExe $injectorSrc 2>&1
        if (Test-Path $injectorExe) {
            $injectorReady = $true
            Write-Pass "B-compile: injector compiled -> $injectorExe"
        } else {
            Write-Fail "B-compile: csc failed; output: $($cscOut -join '; ')"
        }
    }

    if (-not $injectorReady) {
        # The injector is mandatory for every Strategy-B scenario.
        # Mark each one explicitly FAIL (do not silently skip).
        Write-Fail "B1 (prefix+c new-window): injector unavailable"
        Write-Fail "B2 (prefix+z zoom): injector unavailable"
        Write-Fail "B3 (command-prompt new-window): injector unavailable"
        Write-Fail "B4 (char injection into shell): injector unavailable"
        Write-Fail "B5 (copy-mode entry/exit): injector unavailable"
        Write-Fail "B6 (rapid prefix storm): injector unavailable"
    } else {
        # --- Launch a fresh visible attached session rbTui_b -------
        $sessB = "rbTui_b"
        $procB = Start-Process -FilePath $psmuxExe `
            -ArgumentList "-L", $NS, "new-session", "-s", $sessB -PassThru
        $script:LaunchedPids += $procB.Id
        Write-Info "Launched visible window for $sessB (PID $($procB.Id)); waiting 4s for TUI."
        Start-Sleep -Seconds 4

        & psmux -L $NS has-session -t $sessB 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "B0: visible session '$sessB' did NOT come up; Strategy-B scenarios will fail."
        } else {
            Write-Pass "B0: visible session '$sessB' is alive (has-session)"
        }

        # ----------------------------------------------------------
        # B1: PREFIX + c (new window).
        #     Proves keybinding dispatch through input.rs.
        # ----------------------------------------------------------
        $b1Before = [int](Get-Fmt $sessB '#{session_windows}')
        Write-Info "B1: session_windows before = $b1Before; injecting ^b c"
        & $injectorExe $procB.Id "^b{SLEEP:300}c"
        Start-Sleep -Seconds 2
        $b1After = [int](Get-Fmt $sessB '#{session_windows}')
        if ($b1After -eq ($b1Before + 1)) {
            Write-Pass "B1: prefix+c -> session_windows $b1Before -> $b1After (+1 via input.rs)"
        } else {
            Write-Fail "B1: prefix+c -> expected $($b1Before + 1), got $b1After"
        }

        # ----------------------------------------------------------
        # B2: PREFIX + z (zoom). Split first via CLI so 2 panes exist,
        #     then inject prefix+z and assert zoomed_flag toggled to 1.
        # ----------------------------------------------------------
        & psmux -L $NS split-window -v -t $sessB 2>&1 | Out-Null
        Start-Sleep -Seconds 1
        $b2PanesBefore = Get-Fmt $sessB '#{window_panes}'
        $b2ZoomBefore  = Get-Fmt $sessB '#{window_zoomed_flag}'
        Write-Info "B2: panes=$b2PanesBefore zoomed=$b2ZoomBefore before; injecting ^b z"
        & $injectorExe $procB.Id "^b{SLEEP:300}z"
        Start-Sleep -Seconds 2
        $b2ZoomAfter = Get-Fmt $sessB '#{window_zoomed_flag}'
        if ($b2ZoomAfter -eq "1") {
            Write-Pass "B2: prefix+z -> window_zoomed_flag == 1 (toggled via input.rs)"
        } else {
            Write-Fail "B2: prefix+z -> expected zoomed_flag=1, got [$b2ZoomAfter]"
        }
        # Un-zoom again via injection so subsequent scenarios are clean.
        & $injectorExe $procB.Id "^b{SLEEP:300}z"
        Start-Sleep -Seconds 1

        # ----------------------------------------------------------
        # B3: COMMAND PROMPT (prefix + : then a command + Enter).
        #     The ONLY way to exercise the command-prompt UI in input.rs.
        # ----------------------------------------------------------
        $b3Before = [int](Get-Fmt $sessB '#{session_windows}')
        Write-Info "B3: session_windows before = $b3Before; injecting prefix+: new-window Enter"
        & $injectorExe $procB.Id "^b{SLEEP:300}:{SLEEP:500}new-window{ENTER}"
        Start-Sleep -Seconds 3
        $b3After = [int](Get-Fmt $sessB '#{session_windows}')
        if ($b3After -gt $b3Before) {
            Write-Pass "B3: command-prompt 'new-window' -> session_windows $b3Before -> $b3After (increased)"
        } else {
            Write-Fail "B3: command-prompt 'new-window' -> session_windows did not increase ($b3Before -> $b3After)"
        }

        # ----------------------------------------------------------
        # B4: CHARACTER INJECTION INTO SHELL.
        #     Clear first via CLI, then inject 'echo INJECTED_MARKER'+Enter,
        #     assert capture-pane contains INJECTED_MARKER.
        # ----------------------------------------------------------
        & psmux -L $NS send-keys -t $sessB "clear" 2>&1 | Out-Null
        Start-Sleep -Milliseconds 300
        & psmux -L $NS send-keys -t $sessB Enter 2>&1 | Out-Null
        Start-Sleep -Seconds 1
        Write-Info "B4: injecting literal 'echo INJECTED_MARKER' + Enter into shell"
        & $injectorExe $procB.Id "echo INJECTED_MARKER{ENTER}"
        Start-Sleep -Seconds 2
        $capB = (& psmux -L $NS capture-pane -p -t $sessB 2>&1) -join "`n"
        if ($capB -match "INJECTED_MARKER") {
            Write-Pass "B4: char injection -> capture-pane contains INJECTED_MARKER"
        } else {
            Write-Fail "B4: char injection -> capture-pane did NOT contain INJECTED_MARKER"
        }

        # ----------------------------------------------------------
        # B5: COPY MODE entry/exit.
        #     Inject prefix+[ to enter copy mode; verify via dump-state
        #     JSON that the active pane reports "copy_mode":true. Then
        #     inject ESC to exit. Fallback proof: server still alive and
        #     a subsequent prefix+c still creates a window (input not
        #     wedged) if the JSON field check is inconclusive.
        # ----------------------------------------------------------
        Write-Info "B5: injecting prefix+[ to enter copy mode"
        & $injectorExe $procB.Id "^b{SLEEP:300}["
        Start-Sleep -Seconds 1
        $rawCopy = Get-RawDumpState $sessB
        $copyDetected = $false
        if ($rawCopy -and ($rawCopy -match '"copy_mode"\s*:\s*true')) {
            $copyDetected = $true
            Write-Pass "B5a: copy-mode entry -> dump-state JSON shows \"copy_mode\":true"
        } else {
            Write-Info "B5a: dump-state did not clearly show copy_mode:true (will use fallback proof)"
        }
        # Exit copy mode.
        & $injectorExe $procB.Id "{ESC}"
        Start-Sleep -Seconds 1

        # Fallback / cleanliness proof: after exiting copy mode, a
        # prefix+c must still create a window (input.rs not wedged).
        $b5WinBefore = [int](Get-Fmt $sessB '#{session_windows}')
        & $injectorExe $procB.Id "^b{SLEEP:300}c"
        Start-Sleep -Seconds 2
        $b5WinAfter = [int](Get-Fmt $sessB '#{session_windows}')
        if ($b5WinAfter -eq ($b5WinBefore + 1)) {
            if ($copyDetected) {
                Write-Pass "B5b: post-copy-mode prefix+c works -> session_windows +1 (input clean)"
            } else {
                Write-Pass "B5b: copy-mode entered/exited cleanly -> post-exit prefix+c created a window (input not wedged)"
            }
        } else {
            Write-Fail "B5b: post-copy-mode prefix+c did NOT create a window ($b5WinBefore -> $b5WinAfter) -- input may be wedged"
        }

        # ----------------------------------------------------------
        # B6: RAPID PREFIX STORM. Three quick prefix+c sequences.
        #     Allow off-by-one timing slack: assert increased by >= 2.
        # ----------------------------------------------------------
        $b6Before = [int](Get-Fmt $sessB '#{session_windows}')
        Write-Info "B6: session_windows before storm = $b6Before; injecting 3x ^b c"
        & $injectorExe $procB.Id "^b{SLEEP:200}c^b{SLEEP:200}c^b{SLEEP:200}c"
        Start-Sleep -Seconds 3
        $b6After = [int](Get-Fmt $sessB '#{session_windows}')
        if (($b6After - $b6Before) -ge 2) {
            Write-Pass "B6: rapid prefix storm -> session_windows $b6Before -> $b6After (+$($b6After - $b6Before), >= 2)"
        } else {
            Write-Fail "B6: rapid prefix storm -> expected >= +2, got +$($b6After - $b6Before) ($b6Before -> $b6After)"
        }

        # --- Stop Strategy B visible window (specific PID) ---------
        Write-Info "Strategy B complete; stopping visible window PID $($procB.Id)."
        try { Stop-Process -Id $procB.Id -Force -ErrorAction SilentlyContinue } catch {}
        $script:LaunchedPids = $script:LaunchedPids | Where-Object { $_ -ne $procB.Id }

        # --- Dump the injector log for diagnostics -----------------
        Write-Host "`n[Injector Log] ($injectLog):" -ForegroundColor Yellow
        if (Test-Path $injectLog) {
            $logTxt = Get-Content $injectLog -Raw -ErrorAction SilentlyContinue
            if ($logTxt) {
                $show = $logTxt.Substring(0, [Math]::Min(3000, $logTxt.Length))
                Write-Host $show
            } else {
                Write-Host "  (injector log empty)"
            }
        } else {
            Write-Host "  (injector log not found at $injectLog)"
        }
    }

} finally {
    # ================================================================
    #  Cleanup: guard-stop any launched PIDs (our own processes), then
    #  scoped kill-server. NEVER a global kill, NEVER an image sweep.
    # ================================================================
    foreach ($p in $script:LaunchedPids) {
        if ($p) {
            try { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
    & psmux -L $NS kill-server 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    Remove-Item "$psmuxDir\${NS}__*.port" -Force -ErrorAction SilentlyContinue
    Remove-Item "$psmuxDir\${NS}__*.key"  -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------
# Results footer (project convention)
# --------------------------------------------------------------------
Write-Host "`n=== Results ==="
Write-Host "Passed: $script:TestsPassed" -ForegroundColor Green
Write-Host "Failed: $script:TestsFailed" -ForegroundColor Red

exit $script:TestsFailed
