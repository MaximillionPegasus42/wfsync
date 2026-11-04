// `wfsync sync`: exchange state through a shared folder, for players without an
// agent or r00ms. Each player writes only <handle>.json (same JSON as a full room
// snapshot) and reads everybody else's, so syncing tools never see a conflict.
// Works with any synced folder (Dropbox, iCloud Drive, Syncthing, a network share)
// and with a git checkout, which gets pulled before and pushed after.
// Nothing here is encrypted or signed: anyone who can write the folder can post as anyone.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { SCHEMA, ownBody, loadPlayers, savePlayers, mergePlayer, writeRemote, writeAtomic } from './sync.js';
import { myHandle, sharedDir } from './paths.js';

const HANDLE = /^[\w-][\w.-]{0,63}$/;

const git = (dir, ...args) => execFileSync('git', ['-C', dir, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
const isGit = dir => fs.existsSync(path.join(dir, '.git'));

export function sync({ dir = sharedDir(), write = true } = {}) {
  if (!dir) throw new Error('no shared folder; run `wfsync sync --dir <folder>` once (or set WFSYNC_SHARED)');
  if (!fs.existsSync(dir)) throw new Error(`shared folder ${dir} does not exist`);
  const handle = myHandle();
  if (!HANDLE.test(handle)) throw new Error(`handle ${handle} is not a plain name; run with --handle <name>`);
  const out = { dir, handle, git: isGit(dir) ? {} : undefined, own: null, players: [] };

  if (out.git) {
    try { git(dir, 'pull', '--rebase', '--autostash', '-q'); out.git.pull = 'ok'; } catch (e) { out.git.pull = gitError(e); }
  }

  // Own state, written only when it changed so synced folders stay quiet.
  const ownFile = path.join(dir, `${handle}.json`);
  try {
    const text = JSON.stringify(ownBody(), null, 1) + '\n';
    const changed = !fs.existsSync(ownFile) || fs.readFileSync(ownFile, 'utf8') !== text;
    if (changed) writeAtomic(ownFile, text);
    out.own = changed ? 'written' : 'unchanged';
  } catch (e) {
    out.own = `skipped: ${e.message}`;
  }

  const players = loadPlayers();
  for (const name of fs.readdirSync(dir).filter(f => f.endsWith('.json')).sort()) {
    const h = name.slice(0, -'.json'.length);
    if (h === handle) continue;
    const r = { handle: h };
    try {
      const body = JSON.parse(fs.readFileSync(path.join(dir, name), 'utf8'));
      if (body.v !== SCHEMA || body.handle !== h || !HANDLE.test(h)) throw new Error('not a WFSync v1 file for this handle');
      const { v, handle: _, seq, full, completed, completed_add, ...entry } = body;
      r.status = mergePlayer(players, h, { entry, completed, source: 'shared' }) ? 'updated' : 'kept newer';
      r.char = entry.char;
      r.level = entry.level;
    } catch (e) {
      r.status = 'ignored';
      r.why = e.message;
    }
    out.players.push(r);
  }
  savePlayers(players);
  if (write) out.remote = writeRemote(players);

  // Decided from the repo, not from `own`: a commit or push that failed once is
  // retried on the next run even though the file itself is unchanged by then.
  if (out.git) {
    const rel = `${handle}.json`;
    let step = 'commit';
    try {
      if (git(dir, 'status', '--porcelain', '--', rel).trim()) {
        git(dir, 'add', '--', rel);
        git(dir, 'commit', '-q', '-m', `wfsync: ${handle}`, '--', rel);
        out.git.commit = 'ok';
      }
      step = 'push';
      if (unpushed(dir)) { git(dir, 'push', '-q'); out.git.push = 'ok'; }
    } catch (e) {
      out.git[step] = gitError(e);
    }
  }
  return out;
}

// Commits the upstream lacks; without an upstream (or with an empty repo) always push.
function unpushed(dir) {
  try { return Number(git(dir, 'rev-list', '--count', '@{u}..HEAD').trim()) > 0; } catch { return true; }
}

const gitError = e => `failed: ${(e.stderr || e.message).trim().split('\n').pop()}`;
