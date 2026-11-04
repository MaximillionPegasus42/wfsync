@echo off
rem Double-click on Windows: one `wfsync sync` with the folder or server saved by `wfsync sync --dir` / `--server`.
cd /d "%~dp0"
node bin\wfsync.js sync
pause
