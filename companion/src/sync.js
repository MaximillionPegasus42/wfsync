import fs from 'node:fs';
import path from 'node:path';
import { parseSavedVariables, toLua } from './lua.js';
import { savedVariablesFile, dataAddonDir, stateDir, myHandle } from './paths.js';

export const SCHEMA = 1;
const RECENT = 20;
const MARKER = 'WFSYNC v1';

// ---------- own data (SavedVariables) ----------

export function readDb(file = savedVariablesFile()) {
  if (!fs.existsSync(file)) throw new Error(`${file} does not exist yet; log in with WFSync enabled, then /reload or log out`);
  const vars = parseSavedVariables(fs.readFileSync(file, 'utf8'));
  const db = vars.WFSync_DB;
  if (!db || typeof db !== 'object') throw new Error(`${file} has no WFSync_DB`);
  if (db.schema !== SCHEMA) throw new Error(`WFSync_DB schema ${db.schema}, companion speaks ${SCHEMA}`);
  for (const c of Object.values(db.chars ?? {})) {
    c.completed = byId(c.completed);
    c.log = byId(c.log);
  }
  return db;
}

// Quest maps keyed 1..n come out of the Lua reader as arrays; key them by ID again.
function byId(v) {
  if (!Array.isArray(v)) return v ?? {};
  return Object.fromEntries(v.map((x, i) => [String(i + 1), x]));
}

// The character played most recently, or the one named.
export function myChar(db, name) {
  const chars = Object.entries(db.chars ?? {});
  if (chars.length === 0) throw new Error('WFSync_DB has no characters yet');
  if (name) {
    const hit = chars.find(([k]) => k === name || k.split('-')[0] === name);
    if (!hit) throw new Error(`no character ${name}; have ${chars.map(([k]) => k).join(', ')}`);
    return { name: hit[0], ...hit[1] };
  }
  chars.sort(([, a], [, b]) => (b.updated ?? 0) - (a.updated ?? 0));
  return { name: chars[0][0], ...chars[0][1] };
}

export const asList = v => (Array.isArray(v) ? v : Object.values(v ?? {}));
export const completedIds = c => Object.entries(c.completed ?? {})
  .filter(([, done]) => done).map(([id]) => Number(id)).sort((a, b) => a - b);

// Remote.lua entry: same fields as WFSync_DB.chars[x] without events/sessions/completed.
function entryOf(c) {
  const { name, events, sessions, completed, ...rest } = c;
  return { char: name, ...rest, recent: asList(events).slice(-RECENT) };
}

// ---------- snapshots posted to the room ----------

const meFile = () => path.join(stateDir(), 'me.json');
const loadMe = () => (fs.existsSync(meFile()) ? JSON.parse(fs.readFileSync(meFile(), 'utf8')) : { seq: 0, sent: [], fingerprint: null });

export function xpPercent(c) {
  return c.xpMax ? Math.floor((100 * (c.xp ?? 0)) / c.xpMax) : 0;
}

function humanLine(handle, c, added) {
  const parts = [`Lvl ${c.level} (${xpPercent(c)} %)`];
  if (c.zone) parts.push(c.subzone ? `${c.zone} / ${c.subzone}` : c.zone);
  if (added > 0) parts.push(`+${added} Quest${added === 1 ? '' : 's'}`);
  return `${handle}: ${parts.join(' · ')}`;
}

// Builds the room post for this player's current state.
// changed=false means nothing new since the last committed snapshot (don't post).
// commit=true advances seq/sent so the next call produces a delta.
export function makeSnapshot({ full = false, commit = true, charName } = {}) {
  const handle = myHandle();
  const c = myChar(readDb(), charName);
  const me = loadMe();
  const ids = completedIds(c);
  const sent = new Set(me.sent);
  const added = ids.filter(id => !sent.has(id));
  const entry = entryOf(c);
  const fingerprint = JSON.stringify({ ...entry, recent: entry.recent.at(-1) ?? null, ids: ids.length });
  const sendFull = full || me.seq === 0 || me.char !== c.name;
  const changed = sendFull || added.length > 0 || fingerprint !== me.fingerprint;

  const seq = me.seq + 1;
  const body = { v: SCHEMA, handle, seq, full: sendFull, ...entry };
  if (sendFull) body.completed = ids;
  else body.completed_add = added;

  const text = `${humanLine(handle, c, sendFull ? 0 : added.length)}\n\`\`\`${MARKER}\n${JSON.stringify(body)}\n\`\`\``;
  if (commit && changed) {
    fs.writeFileSync(meFile(), JSON.stringify({ seq, sent: ids, fingerprint, char: c.name }));
  }
  return { changed, full: sendFull, seq, text };
}

// Full state of this player, the same JSON as a full room snapshot (without seq).
export function ownBody(charName) {
  const c = myChar(readDb(), charName);
  return { v: SCHEMA, handle: myHandle(), full: true, ...entryOf(c), completed: completedIds(c) };
}

// ---------- other players (from the room) ----------

const playersFile = () => path.join(stateDir(), 'players.json');
export const loadPlayers = () => (fs.existsSync(playersFile()) ? JSON.parse(fs.readFileSync(playersFile(), 'utf8')) : {});
export const savePlayers = p => writeAtomic(playersFile(), JSON.stringify(p, null, 1));

// Folds one state of `handle` into `players`, whatever path it came by: the entry
// with the newest `updated` (set by that player's own client) wins, completed quests
// add up (a turned-in quest stays turned in). seq stays the room's.
export function mergePlayer(players, handle, { entry, completed = [], seq, source }) {
  const prev = players[handle];
  const newer = !prev || (entry.updated ?? 0) >= (prev.entry.updated ?? 0);
  const done = new Set([...(prev?.completed ?? []), ...completed]);
  players[handle] = {
    seq: seq ?? prev?.seq ?? 0,
    entry: newer ? entry : prev.entry,
    completed: [...done].sort((a, b) => a - b),
    updated: Date.now(),
    source: newer ? source : prev.source,
  };
  return newer;
}

export function extractSnapshots(text) {
  const out = [];
  const re = /```WFSYNC v1\s*\n([\s\S]*?)\n?```/g;
  for (let m; (m = re.exec(text));) {
    try { out.push(JSON.parse(m[1])); } catch { /* ignore broken block */ }
  }
  return out;
}

// The person behind a room author: `lois` posts as lois, `AddonBuilder@lois` as lois.
export const personOf = author => author.split('@').pop();

// Applies every WFSYNC block in `text`. Returns per-handle results; need_full marks
// handles whose deltas had a seq gap (ask them for `full`). With `author` (the room
// handle that posted `text`), blocks claiming to be another person are rejected.
export function ingest(text, { author, writeRemote: write = true } = {}) {
  const players = loadPlayers();
  const results = [];
  const me = myHandle();
  for (const s of extractSnapshots(text)) {
    if (s.v !== SCHEMA || typeof s.handle !== 'string' || !Number.isInteger(s.seq)) {
      results.push({ handle: s.handle ?? null, status: 'ignored', why: 'bad header' });
      continue;
    }
    if (author && personOf(author) !== s.handle) {
      results.push({ handle: s.handle, status: 'rejected', why: `posted by ${author}, not by ${s.handle} or their agent` });
      continue;
    }
    if (s.handle === me) { results.push({ handle: s.handle, status: 'ignored', why: 'own snapshot' }); continue; }
    const prev = players[s.handle];
    const { v, handle, seq, full, completed, completed_add, ...entry } = s;
    if (full) {
      mergePlayer(players, handle, { entry, completed, seq, source: 'room' });
      results.push({ handle, status: 'full', seq });
    } else if (!prev) {
      results.push({ handle, status: 'need_full', why: 'no full snapshot yet' });
    } else if (seq <= prev.seq) {
      results.push({ handle, status: 'ignored', why: `old seq ${seq} (have ${prev.seq})` });
    } else if (seq !== prev.seq + 1) {
      results.push({ handle, status: 'need_full', why: `seq gap ${prev.seq} -> ${seq}` });
    } else {
      mergePlayer(players, handle, { entry, completed: completed_add, seq, source: 'room' });
      results.push({ handle, status: 'delta', seq, added: (completed_add ?? []).length });
    }
  }
  savePlayers(players);
  if (write && results.some(r => r.status === 'full' || r.status === 'delta')) writeRemote(players);
  return results;
}

// ---------- WFSync_Data add-on ----------

// Same Interface number as the installed WFSync add-on, so both change together.
function interfaceVersion() {
  if (process.env.WFSYNC_INTERFACE) return process.env.WFSYNC_INTERFACE;
  const main = path.join(dataAddonDir(), '..', 'WFSync', 'WFSync.toc');
  const m = fs.existsSync(main) && /^## Interface:\s*([\d, ]+?)\s*$/m.exec(fs.readFileSync(main, 'utf8'));
  return m ? m[1].trim() : '11509, 16001';
}

const tocText = () => `## Interface: ${interfaceVersion()}
## Title: WFSync Data
## Notes: Written by the WFSync companion
Remote.lua
`;

export function writeRemote(players = loadPlayers()) {
  const dir = dataAddonDir();
  fs.mkdirSync(dir, { recursive: true });
  const toc = path.join(dir, 'WFSync_Data.toc');
  const want = tocText();
  if (!fs.existsSync(toc) || fs.readFileSync(toc, 'utf8') !== want) writeAtomic(toc, want);
  const remote = { schema: SCHEMA, generated: Math.floor(Date.now() / 1000), players: {} };
  for (const [handle, p] of Object.entries(players)) {
    const completed = {};
    for (const id of p.completed) completed[id] = true;
    remote.players[handle] = { ...p.entry, completed };
  }
  const file = path.join(dir, 'Remote.lua');
  writeAtomic(file, `-- Written by the WFSync companion. Do not edit.\nWFSync_Remote = ${toLua(remote)}\n`);
  return file;
}

export function writeAtomic(file, data) {
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, data);
  fs.renameSync(tmp, file);
}
