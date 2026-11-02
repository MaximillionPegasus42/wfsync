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

## MCP tools

`get_status`, `recent_events` (type `quest_turnin` = recent quests), `completed_quest_ids`, `session_log`, `quest_status`, `group_overview`, `make_snapshot`, `ingest_snapshots`, `write_remote`.

## Tests

`npm test`
