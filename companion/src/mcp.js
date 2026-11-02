// MCP server over stdio (newline-delimited JSON-RPC 2.0), no dependencies.
import readline from 'node:readline';
import { makeSnapshot, ingest, writeRemote } from './sync.js';
import * as q from './query.js';

const handleArg = { handle: { type: 'string', description: 'r00ms person handle (e.g. mf, lois); default: this player' } };

const TOOLS = [
  {
    name: 'get_status',
    description: 'Level, XP %, zone, money, quest log and last update of a player.',
    inputSchema: { type: 'object', properties: handleArg },
    run: a => q.status(a.handle),
  },
  {
    name: 'recent_events',
    description: 'Latest events of a player (quest_turnin, levelup, zone, death, dungeon_enter). Filter with type, e.g. quest_turnin for recent quests.',
    inputSchema: { type: 'object', properties: { ...handleArg, type: { type: 'string' }, limit: { type: 'integer', default: 20 } } },
    run: a => q.recentEvents(a.handle, a),
  },
  {
    name: 'completed_quest_ids',
    description: 'All quest IDs a player has completed.',
    inputSchema: { type: 'object', properties: handleArg },
    run: a => q.completed(a.handle),
  },
  {
    name: 'session_log',
    description: "This player's play sessions (start, stop, XP and levels gained).",
    inputSchema: { type: 'object', properties: {} },
    run: () => q.sessions(),
  },
  {
    name: 'quest_status',
    description: 'For each quest ID: per player completed / in_log / open.',
    inputSchema: { type: 'object', properties: { quest_ids: { type: 'array', items: { type: 'integer' } } }, required: ['quest_ids'] },
    run: a => q.questStatus(a.quest_ids),
  },
  {
    name: 'group_overview',
    description: 'Everyone at a glance: level, XP %, zone, level range, and quests that sit in more than one quest log.',
    inputSchema: { type: 'object', properties: {} },
    run: () => q.overview(),
  },
  {
    name: 'make_snapshot',
    description: 'Room post for this player\'s current state (human line + ```WFSYNC v1 block). changed=false: nothing new, do not post. Delta by default; full=true when someone asked for a full snapshot. commit=false previews without advancing seq.',
    inputSchema: { type: 'object', properties: { full: { type: 'boolean' }, commit: { type: 'boolean', default: true } } },
    run: a => makeSnapshot({ full: a.full, commit: a.commit ?? true }),
  },
  {
    name: 'ingest_snapshots',
    description: 'Apply WFSYNC v1 blocks from room posts (pass the post text) and rewrite WFSync_Data/Remote.lua. Status need_full: ask that player\'s agent for a full snapshot.',
    inputSchema: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'] },
    run: a => ingest(a.text),
  },
  {
    name: 'write_remote',
    description: 'Rewrite WFSync_Data/Remote.lua from the stored players (e.g. after an add-on reinstall).',
    inputSchema: { type: 'object', properties: {} },
    run: () => ({ file: writeRemote() }),
  },
];

export function serve() {
  const send = msg => process.stdout.write(JSON.stringify(msg) + '\n');
  const rl = readline.createInterface({ input: process.stdin });
  rl.on('line', line => {
    if (!line.trim()) return;
    let msg;
    try { msg = JSON.parse(line); } catch { return send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } }); }
    const { id, method, params } = msg;
    const reply = result => id !== undefined && send({ jsonrpc: '2.0', id, result });
    const fail = (code, message) => id !== undefined && send({ jsonrpc: '2.0', id, error: { code, message } });
    switch (method) {
      case 'initialize':
        return reply({
          protocolVersion: params?.protocolVersion ?? '2025-06-18',
          capabilities: { tools: {} },
          serverInfo: { name: 'wfsync', version: '0.1.0' },
          instructions: 'WoW Forever group progress. Own data comes from SavedVariables (updated on logout or /reload); other players come from WFSYNC v1 room snapshots fed in with ingest_snapshots.',
        });
      case 'ping':
        return reply({});
      case 'tools/list':
        return reply({ tools: TOOLS.map(({ run, ...t }) => t) });
      case 'tools/call': {
        const tool = TOOLS.find(t => t.name === params?.name);
        if (!tool) return fail(-32602, `unknown tool ${params?.name}`);
        try {
          const out = tool.run(params.arguments ?? {});
          return reply({ content: [{ type: 'text', text: JSON.stringify(out, null, 1) }] });
        } catch (e) {
          return reply({ content: [{ type: 'text', text: e.message }], isError: true });
        }
      }
      default:
        if (method?.startsWith('notifications/')) return;
        return fail(-32601, `method not found: ${method}`);
    }
  });
}
