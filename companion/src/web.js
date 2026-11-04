// `wfsync sync --server URL`: the same exchange as the shared folder, through lois's
// web app instead. POST /api/v1/sync sends this player's state and answers with
// everybody's; GET /api/v1/players only pulls. The contract (status codes, error
// bodies) is in test/fixtures/web/*.json, which the server's tests use too.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { SCHEMA, ownBody, loadPlayers, savePlayers, mergePlayer, writeRemote, writeAtomic } from './sync.js';
import { myHandle, stateDir, loadConfig } from './paths.js';

const HANDLE = /^[\w-][\w.-]{0,63}$/;
const TIMEOUT = 15000;
const DEFAULT_RETRY = 10; // seconds, when a 429 has no Retry-After

// Fields a player shares with the website only after `wfsync share gold|pos on`.
const PRIVATE = { gold: ['money'], pos: ['pos', 'mapID'] };

// 401/403: retrying cannot help, `sync --watch` stops on it.
export class AuthError extends Error {}

export function serverUrl() {
  return process.env.WFSYNC_SERVER || loadConfig().server || null;
}

const token = () => process.env.WFSYNC_TOKEN || loadConfig().token || null;

// The token goes in a header, so it must not travel in clear text over the internet.
export function checkServer(url) {
  let u;
  try { u = new URL(url); } catch { throw new Error(`${url} is not a URL`); }
  const local = ['localhost', '127.0.0.1', '[::1]'].includes(u.hostname);
  if (u.protocol !== 'https:' && !(u.protocol === 'http:' && local)) throw new Error(`${url}: use https (http only for localhost)`);
  return u.origin + u.pathname.replace(/\/+$/, '');
}

export function uploadBody() {
  const body = ownBody();
  const share = loadConfig().share ?? {};
  for (const [what, fields] of Object.entries(PRIVATE)) {
    if (!share[what]) for (const f of fields) delete body[f];
  }
  return body;
}

// Which state the server already has (or refused), and when we may send again.
const stateFile = () => path.join(stateDir(), 'web.json');
const loadState = () => (fs.existsSync(stateFile()) ? JSON.parse(fs.readFileSync(stateFile(), 'utf8')) : {});
const saveState = s => writeAtomic(stateFile(), JSON.stringify(s));
const hash = text => crypto.createHash('sha256').update(text).digest('hex');

export async function syncServer({ server = serverUrl(), write = true, now = Date.now() } = {}) {
  if (!server) throw new Error('no server; run `wfsync sync --server <url>` once (or set WFSYNC_SERVER)');
  const base = checkServer(server);
  if (!token()) throw new Error('no token; run `wfsync token` and paste the token lois gave you');
  const handle = myHandle();
  if (!HANDLE.test(handle)) throw new Error(`handle ${handle} is not a plain name; run with --handle <name>`);
  const state = loadState();
  const out = { server: base, handle, own: null, players: [] };

  let text = null;
  try {
    text = JSON.stringify(uploadBody());
  } catch (e) {
    out.own = `skipped: ${e.message}`;
  }
  const h = text && hash(text);

  if ((state.retryAt ?? 0) > now) {
    out.own = `rate limited until ${new Date(state.retryAt).toISOString()}`;
    return out;
  }

  let res;
  if (h && h !== state.sent && h !== state.rejected) {
    res = await call(base, 'POST', '/api/v1/sync', text);
    if (res.status === 200) {
      state.sent = h;
      out.own = 'sent';
    } else if (res.status === 400 || res.status === 413) {
      // The same state would fail again; try once it has changed.
      state.rejected = h;
      out.own = `rejected ${res.status}: ${res.body?.error ?? 'no error code'}`;
      res = null;
    }
  } else if (h) {
    out.own = h === state.rejected ? 'unchanged (rejected before)' : 'unchanged';
  }
  if (res?.status === 429) {
    const after = Number(res.headers.get('retry-after'));
    state.retryAt = now + 1000 * (Number.isFinite(after) && after > 0 ? after : DEFAULT_RETRY);
    saveState(state);
    out.own = `rate limited for ${(state.retryAt - now) / 1000} s`;
    return out;
  }
  if (!res) res = await call(base, 'GET', '/api/v1/players');
  saveState(state);

  if (res.status === 401 || res.status === 403) {
    throw new AuthError(`server answered ${res.status} (${res.body?.error ?? 'no error code'}); check your token and handle`);
  }
  if (res.status === 429) {
    state.retryAt = now + 1000 * DEFAULT_RETRY;
    saveState(state);
    out.own ??= 'rate limited';
    return out;
  }
  if (res.status !== 200 || typeof res.body?.players !== 'object' || !res.body.players) {
    out.error = `server answered ${res.status}${res.body?.error ? ` (${res.body.error})` : ''}`;
    return out;
  }

  const players = loadPlayers();
  for (const [h2, body] of Object.entries(res.body.players)) {
    if (h2 === handle) continue;
    const r = { handle: h2 };
    if (!HANDLE.test(h2) || body?.v !== SCHEMA || body.handle !== h2) {
      r.status = 'ignored';
      r.why = 'not a WFSync v1 entry for this handle';
    } else {
      const { v, handle: _, seq, full, completed, completed_add, ...entry } = body;
      r.status = mergePlayer(players, h2, { entry, completed: Array.isArray(completed) ? completed : [], source: 'server' })
        ? 'updated' : 'kept newer';
      r.char = entry.char;
      r.level = entry.level;
    }
    out.players.push(r);
  }
  savePlayers(players);
  if (write) out.remote = writeRemote(players);
  return out;
}

async function call(base, method, route, body) {
  const headers = { authorization: `Bearer ${token()}`, accept: 'application/json' };
  if (body) headers['content-type'] = 'application/json';
  let r;
  try {
    r = await fetch(base + route, { method, headers, body, signal: AbortSignal.timeout(TIMEOUT) });
  } catch (e) {
    return { status: 0, headers: new Headers(), body: { error: e.cause?.code ?? e.name } };
  }
  let json = null;
  try { json = await r.json(); } catch { /* not JSON */ }
  return { status: r.status, headers: r.headers, body: json };
}
