#!/bin/sh
# Double-click on macOS: one `wfsync sync` with the folder saved by `wfsync sync --dir`.
cd "$(dirname "$0")" && node bin/wfsync.js sync
printf '\nPress Return to close.'; read _
