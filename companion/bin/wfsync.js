#!/usr/bin/env node
import fs from 'node:fs';
import { serve } from '../src/mcp.js';
import { makeSnapshot, ingest, writeRemote } from '../src/sync.js';
import { sync } from '../src/shared.js';
import { syncServer, serverUrl, checkServer, AuthError } from '../src/web.js';
import { savedVariablesFile, wowDir, dataAddonDir, myHandle, sharedDir, saveConfig, loadConfig } from '../src/paths.js';
import * as q from '../src/query.js';
import { suggest } from '../src/suggest.js';

const [cmd, ...args] = process.argv.slice(2);
const flag = f => args.includes(f);
const option = f => { const i = args.indexOf(f); return i >= 0 ? args.splice(i, 2)[1] : undefined; };
const print = v => console.log(typeof v === 'string' ? v : JSON.stringify(v, null, 1));

const USAGE = `wfsync <command>
  mcp                 run the MCP server on stdio
  paths               show which WoW folder / files are used
  status [handle]     player status as JSON
  overview            everyone at a glance
  suggest [handle]    quests to do together, friends nearby, fitting dungeons
  snapshot [--full] [--peek]
                      room post for the current state (prints nothing if unchanged)
  ingest [--author H] [file]
                      apply WFSYNC v1 blocks from a file or stdin, rewrite Remote.lua;
                      with --author, reject blocks for anyone but H's person
  remote              rewrite WFSync_Data/Remote.lua
  sync [--dir D | --server URL] [--handle H] [--watch]
                      without r00ms: swap state through shared folder D (Dropbox,
                      iCloud, git checkout, ...) or the web app at URL, rewrite
                      Remote.lua; --dir/--server and --handle are remembered;
                      --watch repeats after each logout and every 5 minutes
  token               read the web app token from stdin and remember it
  share gold|pos on|off
                      let the web app see your gold / position (default off)
  watch               print one line each time SavedVariables/WFSync.lua changes`;

try {
  switch (cmd) {
    case 'mcp': serve(); break;
    case 'paths':
      print({ handle: myHandle(), wow: wowDir(), saved_variables: savedVariablesFile(), data_addon: dataAddonDir(), shared: sharedDir(), server: serverUrl() });
      break;
    case 'status': print(q.status(args[0])); break;
    case 'overview': print(q.overview()); break;
    case 'suggest': print(suggest(args[0])); break;
    case 'snapshot': {
      const s = makeSnapshot({ full: flag('--full'), commit: !flag('--peek') });
      if (s.changed || flag('--peek')) print(s.text);
      break;
    }
    case 'ingest': {
      const author = option('--author');
      const text = fs.readFileSync(args[0] ?? 0, 'utf8');
      print(ingest(text, { author }));
      break;
    }
    case 'remote': print(writeRemote()); break;
    case 'sync': {
      const dir = option('--dir');
      const server = option('--server');
      const handle = option('--handle');
      if (dir && server) throw new Error('use either --dir or --server');
      if (server) checkServer(server);
      // The last of --dir / --server given decides where sync goes.
      if (dir || server || handle) {
        saveConfig({ ...(dir && { shared: dir, server: undefined }), ...(server && { server, shared: undefined }), ...(handle && { handle }) });
      }
      if (handle) process.env.WFSYNC_HANDLE = handle;
      let stop = () => {};
      let running = false;
      const once = async () => {
        if (running) return;
        running = true;
        try {
          print(serverUrl() ? await syncServer() : sync());
        } catch (e) {
          console.error(`wfsync: ${e.message}`);
          process.exitCode = 1;
          if (e instanceof AuthError) stop();
        } finally {
          running = false;
        }
      };
      await once();
      if (flag('--watch') && process.exitCode !== 1) {
        // WoW writes WFSync.lua on logout or /reload; others' state may change any time.
        const file = savedVariablesFile();
        fs.watchFile(file, { interval: 2000 }, (cur, prev) => cur.mtimeMs !== prev.mtimeMs && once());
        const timer = setInterval(once, 5 * 60 * 1000);
        stop = () => { fs.unwatchFile(file); clearInterval(timer); };
      }
      break;
    }
    case 'token': {
      const t = fs.readFileSync(0, 'utf8').trim();
      if (!/^\S{8,}$/.test(t)) throw new Error('paste the token (one line, no spaces) on stdin');
      saveConfig({ token: t });
      print('token saved');
      break;
    }
    case 'share': {
      const [what, on] = args;
      if (!['gold', 'pos'].includes(what) || !['on', 'off'].includes(on)) throw new Error('usage: wfsync share gold|pos on|off');
      const share = { ...loadConfig().share, [what]: on === 'on' };
      saveConfig({ share });
      print({ share });
      break;
    }
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
