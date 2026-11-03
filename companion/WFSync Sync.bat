@echo off
rem Double-click on Windows: one `wfsync sync` with the folder saved by `wfsync sync --dir`.
cd /d "%~dp0"
node bin\wfsync.js sync
pause
