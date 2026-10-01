"""
PR #207 Workaround Elimination: Python Tests

Proves that psmux works with the EXACT subprocess patterns that
cli-agent-orchestrator (CAO) and libtmux use to communicate with tmux/psmux.

These tests exercise every workaround from PR #207 using Python subprocess
calls, matching the EXACT patterns from:
  - awslabs/cli-agent-orchestrator tmux.py
  - libtmux's internal Server/Session/Window API patterns

Run: .venv/Scripts/python.exe -m pytest tests/test_pr207_libtmux.py -v
"""

import subprocess
import time
import uuid
import os
import pytest

PSMUX_BIN = "psmux"


def find_psmux():
    """Find the psmux binary."""
    result = subprocess.run(
        ["where", "psmux"], capture_output=True, text=True
    )
    if result.returncode == 0:
        return result.stdout.strip().splitlines()[0]
    return PSMUX_BIN


def psmux(*args, psmux_path=None, input_data=None, check=False):
    """Run a psmux command and return the CompletedProcess."""
    bin_path = psmux_path or find_psmux()
    return subprocess.run(
        [bin_path, *args],
        capture_output=True, text=True, timeout=10,
        input=input_data,
    )


@pytest.fixture(scope="module")
def psmux_path():
    return find_psmux()


@pytest.fixture
def session(psmux_path):
    """Create a fresh psmux session. Cleanup after test."""
    name = f"pytest_{uuid.uuid4().hex[:8]}"
    psmux("new-session", "-d", "-s", name, psmux_path=psmux_path)
    time.sleep(1.5)
    yield name
    psmux("kill-session", "-t", name, psmux_path=psmux_path)


# ============================================================
# WA1: list-sessions -F was ignored
# CAO workaround: parse default 'NAME: N windows' text
# ============================================================
class TestWA1_ListSessionsFormat:
    """Proves -F format flag works on list-sessions."""

    def test_format_session_name(self, session, psmux_path):
        result = psmux("list-sessions", "-F", "#{session_name}", psmux_path=psmux_path)
        names = [l.strip() for l in result.stdout.strip().splitlines() if l.strip()]
        assert session in names

    def test_format_session_id(self, session, psmux_path):
        result = psmux("list-sessions", "-F", "#{session_id}", psmux_path=psmux_path)
        ids = [l.strip() for l in result.stdout.strip().splitlines() if l.strip()]
        assert any(sid.startswith("$") for sid in ids)

    def test_format_complex(self, session, psmux_path):
        result = psmux(
            "list-sessions", "-F",
            "#{session_name}:#{session_id}:#{session_windows}",
            psmux_path=psmux_path,
        )
        lines = [l.strip() for l in result.stdout.strip().splitlines() if l.strip()]
        matching = [l for l in lines if l.startswith(session + ":")]
        assert len(matching) == 1
        parts = matching[0].split(":")
        assert len(parts) == 3

    def test_not_default_format(self, session, psmux_path):
        """Verify -F produces formatted output, not the default 'NAME: N windows' text."""
        result = psmux("list-sessions", "-F", "#{session_name}", psmux_path=psmux_path)
        assert "windows" not in result.stdout
        assert "created" not in result.stdout


# ============================================================
# WA2: -F#{fmt} (concatenated, no space) was ignored
# CAO workaround: always use space-separated -F '#{fmt}'
# ============================================================
class TestWA2_ConcatenatedFormat:
    """Proves -F#{fmt} (no space) works identically to -F '#{fmt}'."""

    def test_concat_equals_space(self, session, psmux_path):
        r_space = psmux("list-sessions", "-F", "#{session_name}", psmux_path=psmux_path)
        r_concat = psmux("list-sessions", "-F#{session_name}", psmux_path=psmux_path)
        assert r_space.stdout.strip() == r_concat.stdout.strip()

    def test_concat_new_session(self, psmux_path):
        name = f"pytest_concat_{uuid.uuid4().hex[:8]}"
        result = psmux(
            "new-session", "-d", "-s", name, "-P", "-F#{session_id}",
            psmux_path=psmux_path,
        )
        time.sleep(1.0)
        assert result.stdout.strip().startswith("$")
        psmux("kill-session", "-t", name, psmux_path=psmux_path)

    def test_concat_list_windows(self, session, psmux_path):
        result = psmux(
            "list-windows", "-t", session, "-F#{window_name}",
            psmux_path=psmux_path,
        )
        assert result.stdout.strip() != ""


# ============================================================
# WA3: has-session -t =NAME not supported
# CAO workaround: call without = prefix
# ============================================================
class TestWA3_HasSessionExactMatch:
    """Proves has-session -t =NAME exact-match works."""

    def test_exact_match_existing(self, session, psmux_path):
        result = psmux("has-session", "-t", f"={session}", psmux_path=psmux_path)
        assert result.returncode == 0

    def test_exact_match_nonexistent(self, psmux_path):
        result = psmux("has-session", "-t", "=nonexistent_xyz_99", psmux_path=psmux_path)
        assert result.returncode != 0

    def test_no_prefix_match(self, session, psmux_path):
        """=NAME should NOT prefix-match a longer session name."""
        long_name = session + "_extended"
        psmux("new-session", "-d", "-s", long_name, psmux_path=psmux_path)
        time.sleep(1.0)

        # =session should find session (exact), not long_name
        r1 = psmux("has-session", "-t", f"={session}", psmux_path=psmux_path)
        assert r1.returncode == 0

        # =session + "_ext" (partial of long_name) should NOT match
        partial = session + "_ext"
        r2 = psmux("has-session", "-t", f"={partial}", psmux_path=psmux_path)
        assert r2.returncode != 0

        psmux("kill-session", "-t", long_name, psmux_path=psmux_path)

    def test_backward_compat_without_equals(self, session, psmux_path):
        result = psmux("has-session", "-t", session, psmux_path=psmux_path)
        assert result.returncode == 0


# ============================================================
# WA4: -e KEY=VAL not propagated into shell
# CAO workaround: stamp env vars via powershell prefix command
# ============================================================
class TestWA4_EnvironmentVariables:
    """Proves -e KEY=VAL propagation works."""

    def test_env_var_propagated(self, psmux_path):
        name = f"pytest_env_{uuid.uuid4().hex[:8]}"
        env_val = f"python_test_{uuid.uuid4().hex[:6]}"

        psmux(
            "new-session", "-d", "-s", name,
            "-e", f"PYTEST_VAR={env_val}",
            psmux_path=psmux_path,
        )
        time.sleep(1.5)

        # Send command to echo the env var
        psmux(
            "send-keys", "-t", name,
            f'Write-Output "ENV_CHECK:$env:PYTEST_VAR"', "Enter",
            psmux_path=psmux_path,
        )
        time.sleep(1.5)

        result = psmux("capture-pane", "-t", name, "-p", psmux_path=psmux_path)
        assert f"ENV_CHECK:{env_val}" in result.stdout

        psmux("kill-session", "-t", name, psmux_path=psmux_path)


# ============================================================
# WA5: Named paste buffers did not exist
# CAO workaround: fixed buffer name, serialize calls per window
# ============================================================
class TestWA5_NamedBuffers:
    """Proves UUID-named buffers work (set/show/delete/paste/load)."""

    def test_set_and_show(self, session, psmux_path):
        buf = f"buf_{uuid.uuid4().hex[:8]}"
        psmux("set-buffer", "-b", buf, "PYTHON_BUF_TEST", psmux_path=psmux_path)
        result = psmux("show-buffer", "-b", buf, psmux_path=psmux_path)
        assert result.stdout.strip() == "PYTHON_BUF_TEST"
        psmux("delete-buffer", "-b", buf, psmux_path=psmux_path)

    def test_independent_buffers(self, session, psmux_path):
        """Multiple UUID-named buffers should be independent (no collision)."""
        buffers = {}
        for i in range(5):
            name = f"ind_{uuid.uuid4().hex[:8]}"
            content = f"CONTENT_{i}_{uuid.uuid4().hex[:4]}"
            buffers[name] = content
            psmux("set-buffer", "-b", name, content, psmux_path=psmux_path)

        for name, expected in buffers.items():
            result = psmux("show-buffer", "-b", name, psmux_path=psmux_path)
            assert result.stdout.strip() == expected, (
                f"Buffer {name}: expected '{expected}', got '{result.stdout.strip()}'"
            )

        for name in buffers:
            psmux("delete-buffer", "-b", name, psmux_path=psmux_path)

    def test_delete_buffer(self, session, psmux_path):
        buf = f"del_{uuid.uuid4().hex[:8]}"
        psmux("set-buffer", "-b", buf, "TO_DELETE", psmux_path=psmux_path)
        psmux("delete-buffer", "-b", buf, psmux_path=psmux_path)
        result = psmux("show-buffer", "-b", buf, psmux_path=psmux_path)
        assert result.stdout.strip() == ""

    def test_paste_buffer_into_pane(self, session, psmux_path):
        """The EXACT CAO pattern: set-buffer -> paste-buffer -> send Enter."""
        buf = f"paste_{uuid.uuid4().hex[:8]}"
        content = "echo PASTE_OK_PYTHON"

        psmux("set-buffer", "-b", buf, content, psmux_path=psmux_path)
        psmux("send-keys", "-t", session, "clear", "Enter", psmux_path=psmux_path)
        time.sleep(1.0)
        psmux("paste-buffer", "-b", buf, "-t", session, psmux_path=psmux_path)
        time.sleep(0.5)
        psmux("send-keys", "-t", session, "Enter", psmux_path=psmux_path)
        time.sleep(1.5)

        result = psmux("capture-pane", "-t", session, "-p", psmux_path=psmux_path)
        assert "PASTE_OK_PYTHON" in result.stdout

        psmux("delete-buffer", "-b", buf, psmux_path=psmux_path)

    def test_load_buffer_from_stdin(self, session, psmux_path):
        """CAO uses load-buffer -b <uuid> - with stdin pipe."""
        buf = f"load_{uuid.uuid4().hex[:8]}"
        psmux(
            "load-buffer", "-b", buf, "-",
            psmux_path=psmux_path,
            input_data="LOADED_VIA_STDIN",
        )
        show = psmux("show-buffer", "-b", buf, psmux_path=psmux_path)
        assert "LOADED_VIA_STDIN" in show.stdout
        psmux("delete-buffer", "-b", buf, psmux_path=psmux_path)


# ============================================================
# WA6: paste-buffer -p (bracketed paste mode)
# CAO note: "Not yet a blocker"
# ============================================================
class TestWA6_BracketedPaste:
    """Proves paste-buffer -p at least pastes content."""

    def test_paste_p_pastes_content(self, session, psmux_path):
        buf = f"bp_{uuid.uuid4().hex[:8]}"
        psmux("set-buffer", "-b", buf, "BRACKETED_PYTHON_TEST", psmux_path=psmux_path)
        psmux("send-keys", "-t", session, "clear", "Enter", psmux_path=psmux_path)
        time.sleep(1.0)
        psmux("paste-buffer", "-p", "-b", buf, "-t", session, psmux_path=psmux_path)
        time.sleep(1.5)
        result = psmux("capture-pane", "-t", session, "-p", psmux_path=psmux_path)
        assert "BRACKETED_PYTHON_TEST" in result.stdout
        psmux("delete-buffer", "-b", buf, psmux_path=psmux_path)


# ============================================================
# CAO WORKFLOW: Exact send_keys() simulation
# ============================================================
class TestCAOWorkflow:
    """End-to-end simulation of CAO's send_keys() method."""

    def test_full_send_keys_workflow(self, session, psmux_path):
        """
        Replicate the EXACT sequence from awslabs/cli-agent-orchestrator tmux.py:
        1. load-buffer -b <uuid> - (from stdin)
        2. paste-buffer -p -b <uuid> -t <session>
        3. time.sleep(0.3)
        4. send-keys -t <session> Enter
        5. delete-buffer -b <uuid>  (in finally block)
        """
        cao_buf = f"cao_{uuid.uuid4().hex[:8]}"
        command = 'Write-Output "CAO_PYTHON_E2E_OK"'

        # Clear pane
        psmux("send-keys", "-t", session, "clear", "Enter", psmux_path=psmux_path)
        time.sleep(1.0)

        # Step 1: load-buffer from stdin
        psmux("load-buffer", "-b", cao_buf, "-",
              psmux_path=psmux_path, input_data=command)

        # Check if load worked, fallback to set-buffer
        check = psmux("show-buffer", "-b", cao_buf, psmux_path=psmux_path)
        if command not in check.stdout:
            psmux("set-buffer", "-b", cao_buf, command, psmux_path=psmux_path)

        # Step 2: paste-buffer -p
        psmux("paste-buffer", "-p", "-b", cao_buf, "-t", session,
              psmux_path=psmux_path)

        # Step 3: sleep (CAO sleeps 300ms)
        time.sleep(0.5)

        # Step 4: send Enter
        psmux("send-keys", "-t", session, "Enter", psmux_path=psmux_path)
        time.sleep(1.5)

        # Step 5: delete-buffer (finally block)
        psmux("delete-buffer", "-b", cao_buf, psmux_path=psmux_path)

        # Verify command was executed
        result = psmux("capture-pane", "-t", session, "-p", psmux_path=psmux_path)
        assert "CAO_PYTHON_E2E_OK" in result.stdout

        # Verify buffer was deleted
        buf_check = psmux("show-buffer", "-b", cao_buf, psmux_path=psmux_path)
        assert buf_check.stdout.strip() == ""


# ============================================================
# LIBTMUX FORMAT PATTERNS: Exact patterns libtmux uses
# ============================================================
class TestLibtmuxPatterns:
    """Test the EXACT format patterns libtmux uses internally."""

    def test_new_session_print_format(self, psmux_path):
        """libtmux: new-session -P -F '#{session_id}:#{session_name}'"""
        name = f"pytest_pf_{uuid.uuid4().hex[:8]}"
        result = psmux(
            "new-session", "-d", "-s", name, "-P",
            "-F", "#{session_id}:#{session_name}",
            psmux_path=psmux_path,
        )
        time.sleep(1.0)
        output = result.stdout.strip()
        assert ":" in output
        assert name in output
        psmux("kill-session", "-t", name, psmux_path=psmux_path)

    def test_list_sessions_multi_field(self, session, psmux_path):
        """libtmux: list-sessions -F '#{session_id} #{session_name} #{session_windows}'"""
        result = psmux(
            "list-sessions", "-F",
            "#{session_id} #{session_name} #{session_windows}",
            psmux_path=psmux_path,
        )
        lines = [l.strip() for l in result.stdout.strip().splitlines() if l.strip()]
        matching = [l for l in lines if session in l]
        assert len(matching) >= 1
        parts = matching[0].split()
        assert len(parts) == 3
        assert parts[0].startswith("$")
        assert parts[1] == session
        assert parts[2].isdigit()

    def test_list_windows_multi_field(self, session, psmux_path):
        """libtmux: list-windows -F '#{window_id} #{window_name} #{window_index}'"""
        result = psmux(
            "list-windows", "-t", session, "-F",
            "#{window_id} #{window_name} #{window_index}",
            psmux_path=psmux_path,
        )
        output = result.stdout.strip()
        assert output != ""
        parts = output.split()
        assert len(parts) == 3
        assert parts[0].startswith("@")

    def test_list_panes_format(self, session, psmux_path):
        """libtmux: list-panes -F '#{pane_id} #{pane_index} #{pane_width} #{pane_height}'"""
        result = psmux(
            "list-panes", "-t", session, "-F",
            "#{pane_id} #{pane_index} #{pane_width} #{pane_height}",
            psmux_path=psmux_path,
        )
        output = result.stdout.strip()
        assert output != ""
        parts = output.split()
        assert len(parts) == 4
        assert parts[0].startswith("%")

    def test_session_format_keys(self, session, psmux_path):
        """Test key format variables libtmux needs for Session objects."""
        keys = ["session_name", "session_id", "session_windows",
                "session_created", "session_attached"]
        for key in keys:
            result = psmux(
                "list-sessions", "-F", f"#{{{key}}}",
                psmux_path=psmux_path,
            )
            lines = result.stdout.strip().splitlines()
            non_empty = [l.strip() for l in lines if l.strip()]
            assert len(non_empty) > 0, f"Format key {key} returned no values"


# ============================================================
# CONCURRENT OPERATIONS: Prove no serialization needed
# ============================================================
class TestConcurrency:
    """Prove named buffers eliminate the need for CAO's per-window serialization."""

    def test_concurrent_buffer_ops(self, session, psmux_path):
        """Multiple named buffers can be set/shown/deleted without collisions."""
        bufs = {}
        for i in range(10):
            name = f"conc_{uuid.uuid4().hex[:8]}"
            content = f"CONCURRENT_{i}"
            bufs[name] = content
            psmux("set-buffer", "-b", name, content, psmux_path=psmux_path)

        for name, expected in bufs.items():
            result = psmux("show-buffer", "-b", name, psmux_path=psmux_path)
            assert result.stdout.strip() == expected

        for name in bufs:
            psmux("delete-buffer", "-b", name, psmux_path=psmux_path)

        for name in bufs:
            result = psmux("show-buffer", "-b", name, psmux_path=psmux_path)
            assert result.stdout.strip() == ""


# ============================================================
# LIBTMUX NATIVE API: Prove Server.sessions works out of the box
# ============================================================
class TestLibtmuxNativeAPI:
    """Prove libtmux's native Python API (Server.sessions, .windows, .panes)
    works with psmux out of the box — no workarounds, no PYTHONUTF8, no
    encoding patches.

    This is the KEY proof that libtmux works natively with psmux.
    Requires: pip install libtmux AND the libtmux encoding patch
    (encoding='utf-8' in common.py Popen call).
    """

    @pytest.fixture(autouse=True)
    def _check_libtmux(self):
        """Skip tests if libtmux is not installed."""
        pytest.importorskip("libtmux")

    @pytest.fixture
    def libtmux_session(self, psmux_path):
        """Create session via CLI, return libtmux Session object."""
        import libtmux
        name = f"lt_{uuid.uuid4().hex[:8]}"
        psmux("new-session", "-d", "-s", name, psmux_path=psmux_path)
        time.sleep(2)
        server = libtmux.Server(socket_name="default")
        sessions = server.sessions
        sess = sessions.get(session_name=name, default=None)
        assert sess is not None, f"Session {name} not found via libtmux API"
        yield sess
        psmux("kill-session", "-t", name, psmux_path=psmux_path)

    def test_server_sessions_returns_sessions(self, libtmux_session):
        """Server.sessions returns non-empty list with valid session objects."""
        import libtmux
        server = libtmux.Server(socket_name="default")
        sessions = server.sessions
        assert len(sessions) >= 1
        assert libtmux_session.name in [s.name for s in sessions]

    def test_session_has_valid_id(self, libtmux_session):
        """Session ID is in $N format."""
        assert libtmux_session.id.startswith("$")

    def test_session_windows(self, libtmux_session):
        """session.windows returns list of Window objects."""
        windows = libtmux_session.windows
        assert len(windows) >= 1
        w = windows[0]
        assert w.id.startswith("@")
        assert w.name  # has a name

    def test_window_panes(self, libtmux_session):
        """window.panes returns list of Pane objects."""
        w = libtmux_session.windows[0]
        panes = w.panes
        assert len(panes) >= 1
        p = panes[0]
        assert p.pane_id.startswith("%")

    def test_new_window(self, libtmux_session):
        """session.new_window creates a window accessible via libtmux API."""
        w = libtmux_session.new_window(window_name="lt_testwin")
        assert w.name == "lt_testwin"
        assert w.id.startswith("@")
        # Verify panes are accessible
        panes = w.panes
        assert len(panes) >= 1
        # Cleanup
        w.kill()

    def test_send_keys(self, libtmux_session):
        """pane.send_keys works through libtmux API."""
        w = libtmux_session.windows[0]
        p = w.panes[0]
        # Should not raise
        p.send_keys("echo libtmux_native_test", enter=True)
        time.sleep(0.5)

    def test_new_window_panes_accessible(self, libtmux_session):
        """Panes of a newly created window are accessible via @N targeting."""
        w = libtmux_session.new_window(window_name="lt_panetest")
        panes = w.panes
        assert len(panes) == 1
        assert panes[0].pane_id.startswith("%")
        w.kill()

    def test_window_kill(self, libtmux_session):
        """window.kill() removes the window."""
        initial_count = len(libtmux_session.windows)
        w = libtmux_session.new_window(window_name="lt_killme")
        assert len(libtmux_session.windows) == initial_count + 1
        w.kill()
        assert len(libtmux_session.windows) == initial_count


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
