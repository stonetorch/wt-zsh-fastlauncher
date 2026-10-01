@echo off
setlocal
set "PSMUX_EXE=%LOCALAPPDATA%\psmux\psmux.exe"
rem Native reuse/new-session entry; keep the default registry and isolate by namespace.
"%PSMUX_EXE%" -L zsh-pool zsh-pool
exit /b %errorlevel%
