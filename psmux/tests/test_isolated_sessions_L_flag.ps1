# Isolated sessions via -L socket namespace
# Regression guard for the bug: bare `psmux -L <ns>` (no subcommand) with a fresh
# namespace had no warm server to claim, took the cold-spawn path, but that path
# never passed -L to the spawned server. The server started in the DEFAULT
# namespace and wrote <session>.port, while the client waited for the namespaced
# <ns>__<session>.port. The wait timed out (~5s) and the attach then failed with
# "The handle is invalid. (os error 6)" / exit code 1, leaving a dead window and
# no session. Fixed by propagating -L into the cold-spawn server_args in main.rs
# (the bare/default launch branch).
#
# This test proves isolated sessions work from every angle: bare interactive
# launch, detached create, attach, running commands, isolation between
# namespaces and from the default namespace, multiple sessions per namespace,
# kill-session, and a default-namespace regression check.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function HasSess($ns, $s) { & $PSMUX -L $ns has-session -t $s 2>$null; return ($LASTEXITCODE -eq 0) }

# Use namespaces unlikely to collide with prior runs.
$NS1 = "isoL_a"
$NS2 = "isoL_b"
$NSBARE = "isoL_bare"

# Best-effort cleanup of any prior servers in these namespaces.
foreach ($ns in @($NS1, $NS2, $NSBARE)) { & $PSMUX -L $ns kill-server 2>&1 | Out-Null }
Get-Process psmux -EA SilentlyContinue | Where-Object { $false } | Out-Null
Start-Sleep -Seconds 1

Write-Host "`n=== Isolated sessions (-L) tests ===" -ForegroundColor Cyan

# === TEST 1: bare `psmux -L <fresh ns>` must create AND attach a default session ===
Write-Host "`n[Test 1] bare 'psmux -L $NSBARE' creates and attaches (regression)" -ForegroundColor Yellow
$p = Start-Process -FilePath $PSMUX -ArgumentList "-L", $NSBARE -PassThru
$created = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 500
    if (Get-ChildItem "$psmuxDir\$NSBARE`__*.port" -EA SilentlyContinue) { $created = $true; break }
    if ($p.HasExited) { break }
}
if ($created -and -not $p.HasExited) { Write-Pass "bare -L created a namespaced session (process alive)" }
else { Write-Fail "bare -L did not create a session (created=$created exited=$($p.HasExited))" }

$ls = & $PSMUX -L $NSBARE list-sessions 2>&1 | Out-String
if ($ls -match '\(attached\)') { Write-Pass "bare -L session is attached" } else { Write-Fail "bare -L session not attached: $($ls.Trim())" }

& $PSMUX -L $NSBARE send-keys -t 0 "echo BARE_MARK_4242" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
$cap = & $PSMUX -L $NSBARE capture-pane -t 0 -p 2>&1 | Out-String
if ($cap -match 'BARE_MARK_4242') { Write-Pass "commands run inside bare -L session" } else { Write-Fail "no output in bare -L session" }
try { Stop-Process -Id $p.Id -Force -EA SilentlyContinue } catch {}
& $PSMUX -L $NSBARE kill-server 2>&1 | Out-Null

# === TEST 2: detached create in two separate namespaces ===
Write-Host "`n[Test 2] detached create in two namespaces" -ForegroundColor Yellow
& $PSMUX -L $NS1 new-session -d -s db 2>&1 | Out-Null
& $PSMUX -L $NS2 new-session -d -s web 2>&1 | Out-Null
Start-Sleep -Seconds 3
if (HasSess $NS1 db) { Write-Pass "$NS1/db created" } else { Write-Fail "$NS1/db not created" }
if (HasSess $NS2 web) { Write-Pass "$NS2/web created" } else { Write-Fail "$NS2/web not created" }

# === TEST 3: isolation between namespaces and from default ===
Write-Host "`n[Test 3] isolation" -ForegroundColor Yellow
if (-not (HasSess $NS1 web)) { Write-Pass "$NS1 cannot see $NS2/web" } else { Write-Fail "isolation breach: $NS1 sees web" }
if (-not (HasSess $NS2 db)) { Write-Pass "$NS2 cannot see $NS1/db" } else { Write-Fail "isolation breach: $NS2 sees db" }
& $PSMUX has-session -t db 2>$null
if ($LASTEXITCODE -ne 0) { Write-Pass "default namespace cannot see $NS1/db" } else { Write-Fail "default sees db" }

# === TEST 4: distinct commands stay in their own session ===
Write-Host "`n[Test 4] command output stays isolated" -ForegroundColor Yellow
& $PSMUX -L $NS1 send-keys -t db "echo NS1_DB_111" Enter 2>&1 | Out-Null
& $PSMUX -L $NS2 send-keys -t web "echo NS2_WEB_222" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
$rcap = & $PSMUX -L $NS1 capture-pane -t db -p 2>&1 | Out-String
$bcap = & $PSMUX -L $NS2 capture-pane -t web -p 2>&1 | Out-String
if ($rcap -match 'NS1_DB_111' -and $rcap -notmatch 'NS2_WEB_222') { Write-Pass "$NS1/db has only its own output" } else { Write-Fail "$NS1/db output leaked" }
if ($bcap -match 'NS2_WEB_222' -and $bcap -notmatch 'NS1_DB_111') { Write-Pass "$NS2/web has only its own output" } else { Write-Fail "$NS2/web output leaked" }

# === TEST 5: multiple sessions within one namespace ===
Write-Host "`n[Test 5] multiple sessions per namespace" -ForegroundColor Yellow
& $PSMUX -L $NS1 new-session -d -s cache 2>&1 | Out-Null
Start-Sleep -Seconds 3
if ((HasSess $NS1 cache) -and (HasSess $NS1 db)) { Write-Pass "$NS1 holds both db and cache" } else { Write-Fail "$NS1 missing a session" }

# === TEST 6: attach to an existing isolated session ===
Write-Host "`n[Test 6] attach to existing isolated session" -ForegroundColor Yellow
$pa = Start-Process -FilePath $PSMUX -ArgumentList "-L", $NS1, "attach", "-t", "db" -PassThru
Start-Sleep -Seconds 4
if (-not $pa.HasExited) { Write-Pass "attach window alive" } else { Write-Fail "attach exited code=$($pa.ExitCode)" }
& $PSMUX -L $NS1 send-keys -t db "echo REATTACH_333" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2
$rcap2 = & $PSMUX -L $NS1 capture-pane -t db -p 2>&1 | Out-String
if ($rcap2 -match 'REATTACH_333') { Write-Pass "attached session is interactive" } else { Write-Fail "attach not driving session" }
try { Stop-Process -Id $pa.Id -Force -EA SilentlyContinue } catch {}

# === TEST 7: kill-session within a namespace ===
Write-Host "`n[Test 7] kill-session within namespace" -ForegroundColor Yellow
& $PSMUX -L $NS1 kill-session -t cache 2>&1 | Out-Null
Start-Sleep -Seconds 1
if (-not (HasSess $NS1 cache) -and (HasSess $NS1 db)) { Write-Pass "kill-session removed cache, kept db" } else { Write-Fail "kill-session behaved wrong" }

# === TEST 8: default namespace regression ===
Write-Host "`n[Test 8] default namespace still works" -ForegroundColor Yellow
& $PSMUX new-session -d -s isoL_plain 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $PSMUX has-session -t isoL_plain 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "default namespace new-session works" } else { Write-Fail "default namespace regression" }

# === TEARDOWN ===
& $PSMUX -L $NS1 kill-server 2>&1 | Out-Null
& $PSMUX -L $NS2 kill-server 2>&1 | Out-Null
& $PSMUX kill-session -t isoL_plain 2>&1 | Out-Null

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
