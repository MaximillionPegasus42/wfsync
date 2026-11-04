#!/bin/sh
# Double-click on macOS: one `wfsync sync` with the folder or server saved by `wfsync sync --dir` / `--server`.
cd "$(dirname "$0")" && node bin/wfsync.js sync
printf '\nPress Return to close.'; read _
