#!/usr/bin/env node
import fs from 'node:fs';
import { serve } from '../src/mcp.js';
import { makeSnapshot, ingest, writeRemote } from '../src/sync.js';
import { savedVariablesFile, wowDir, dataAddonDir, myHandle } from '../src/paths.js';
import * as q from '../src/query.js';

const [cmd, ...args] = process.argv.slice(2);
const flag = f => args.includes(f);
const print = v => console.log(typeof v === 'string' ? v : JSON.stringify(v, null, 1));

const USAGE = `wfsync <command>
  mcp                 run the MCP server on stdio
  paths               show which WoW folder / files are used
  status [handle]     player status as JSON
  overview            everyone at a glance
  snapshot [--full] [--peek]
                      room post for the current state (prints nothing if unchanged)
  ingest [file]       apply WFSYNC v1 blocks from a file or stdin, rewrite Remote.lua
  remote              rewrite WFSync_Data/Remote.lua
  watch               print one line each time SavedVariables/WFSync.lua changes`;

try {
  switch (cmd) {
    case 'mcp': serve(); break;
    case 'paths':
      print({ handle: myHandle(), wow: wowDir(), saved_variables: savedVariablesFile(), data_addon: dataAddonDir() });
      break;
    case 'status': print(q.status(args[0])); break;
    case 'overview': print(q.overview()); break;
    case 'snapshot': {
      const s = makeSnapshot({ full: flag('--full'), commit: !flag('--peek') });
      if (s.changed || flag('--peek')) print(s.text);
      break;
    }
    case 'ingest': {
      const text = fs.readFileSync(args[0] ?? 0, 'utf8');
      print(ingest(text));
      break;
    }
    case 'remote': print(writeRemote()); break;
    case 'watch': {
      const file = savedVariablesFile();
      let last = fs.existsSync(file) ? fs.statSync(file).mtimeMs : 0;
      console.log(`watching ${file}`);
      fs.watchFile(file, { interval: 2000 }, cur => {
        if (cur.mtimeMs && cur.mtimeMs !== last) {
          last = cur.mtimeMs;
          console.log(`changed ${new Date(cur.mtimeMs).toISOString()}`);
        }
      });
      break;
    }
    default: print(USAGE); process.exitCode = cmd ? 1 : 0;
  }
} catch (e) {
  console.error(`wfsync: ${e.message}`);
  process.exitCode = 1;
}
