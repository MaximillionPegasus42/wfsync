# WFSync companion

Runs next to WoW on each player's machine. No dependencies, Node ≥ 20.

- Reads `WTF/Account/<ACC>/SavedVariables/WFSync.lua` (`WFSync_DB`, schema 1), which WoW writes on logout or `/reload`.
- Serves it to the player's agent as an MCP server.
- Turns the player's state into a room post (`WFSYNC v1` block) and applies other players' posts.
- Writes their state into the `WFSync_Data` add-on (`Remote.lua`), which WFSync loads at login or `/reload`.

## Setup

```bash
claude mcp add wfsync -e WFSYNC_HANDLE=mf -- node /path/to/companion/bin/wfsync.js mcp
```

`WFSYNC_HANDLE` is your r00ms person handle (`mf`, `lois`). The WoW flavor folder is detected automatically: the `_*_` folder whose `WFSync.lua` was written most recently, else `_forever_`, `_classic_era_`, `_classic_`. Set `WFSYNC_WOW_DIR` / `WFSYNC_ACCOUNT` to override. Companion state lives in `~/.wfsync` (`WFSYNC_HOME`).

Check what it found: `node bin/wfsync.js paths`.

## Agent loop

1. `wfsync watch` prints a line whenever `WFSync.lua` changes. On a change, call `make_snapshot`; if `changed` is true, post its `text` in the room.
2. For every room post with a `WFSYNC v1` block from another player, call `ingest_snapshots` with the post text.
3. If a result says `need_full`, ask that player's agent for a full snapshot; it answers with `make_snapshot {full: true}`.

## Room post format

````
mf: Lvl 24 (1 %) · Ashenvale / Astranaar · +2 Quests
```WFSYNC v1
{"v":1,"handle":"mf","seq":2,"full":false,"char":"Name-Realm","level":24,...,"completed_add":[102,103],"recent":[...]}
```
````

`full: true` carries `completed` (all quest IDs); deltas carry `completed_add`. `seq` increases by one per post; a gap means the receiver needs a full snapshot.

## Without an agent: `wfsync sync`

For players without an agent or r00ms. Pick a folder the group shares: Dropbox, iCloud Drive, Syncthing, a network share, or a clone of a **private** git repo. Then, once:

```bash
node bin/wfsync.js sync --dir "/path/to/shared/folder" --handle mf
```

Every run writes your state to `<handle>.json` in that folder, reads everybody else's file, and rewrites `Remote.lua`. In a git checkout it pulls first and pushes your file afterwards. `--dir` and `--handle` are remembered (`~/.wfsync/config.json`), so after that a double-click on `WFSync Sync.command` (macOS) or `WFSync Sync.bat` (Windows) is enough. `sync --watch` keeps running and syncs after each logout or `/reload`, plus every 5 minutes.

The same rules hold for every path a state takes (room, shared folder, add-on): the state with the newest `updated` (set by the player's own client) wins, and completed quests add up.

The files are plain JSON with character, realm, guild, gold and position. Nothing is encrypted or signed: anyone who can write the folder can change anyone's file. Use a folder only your group can reach.

## MCP tools

`get_status`, `recent_events` (type `quest_turnin` = recent quests), `completed_quest_ids`, `session_log`, `quest_status`, `group_overview`, `make_snapshot`, `ingest_snapshots`, `write_remote`.

## Tests

`npm test`
