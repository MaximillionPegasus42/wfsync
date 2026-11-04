import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// Where things live. Everything can be overridden with env vars:
//   WFSYNC_WOW_DIR   game flavor dir, e.g. /Applications/World of Warcraft/_classic_era_
//   WFSYNC_WOW_ROOT  World of Warcraft folder to search instead of the usual places
//   WFSYNC_ACCOUNT   WTF account folder name
//   WFSYNC_HOME      companion state dir (default ~/.wfsync)
//   WFSYNC_HANDLE    this player's r00ms person handle, e.g. mf
//   WFSYNC_SHARED    folder for `wfsync sync` (also saved in ~/.wfsync/config.json)
//   WFSYNC_SERVER    web app for `wfsync sync` (same), WFSYNC_TOKEN its token
// Without WFSYNC_WOW_DIR / WFSYNC_ACCOUNT we pick the flavor + account whose
// SavedVariables/WFSync.lua was written most recently, falling back to the
// newest account of the first flavor found. WoW Forever's launch folder name is
// not known yet (its beta was _classic_beta_), so every _*_ folder counts;
// ptr/beta folders only rank last when nothing has written WFSync.lua yet.

const WOW_ROOTS = [
  '/Applications/World of Warcraft',
  'C:\\Program Files (x86)\\World of Warcraft',
  'C:\\Program Files\\World of Warcraft',
];

const PREFERRED_FLAVORS = ['_forever_', '_camelot_', '_classic_era_', '_classic_'];

function flavorDirs() {
  const out = [];
  for (const root of process.env.WFSYNC_WOW_ROOT ? [process.env.WFSYNC_WOW_ROOT] : WOW_ROOTS) {
    if (!fs.existsSync(root)) continue;
    for (const d of fs.readdirSync(root, { withFileTypes: true })) {
      if (d.isDirectory() && /^_.+_$/.test(d.name)) out.push(path.join(root, d.name));
    }
  }
  const rank = p => {
    const name = path.basename(p);
    const i = PREFERRED_FLAVORS.indexOf(name);
    return i >= 0 ? i : /ptr|beta/.test(name) ? 100 : 99;
  };
  return out.sort((a, b) => rank(a) - rank(b));
}

function accountsOf(flavor) {
  const base = path.join(flavor, 'WTF', 'Account');
  if (!fs.existsSync(base)) return [];
  return fs.readdirSync(base, { withFileTypes: true })
    .filter(d => d.isDirectory() && d.name !== 'SavedVariables')
    .map(d => path.join(base, d.name));
}

const dbFile = account => path.join(account, 'SavedVariables', 'WFSync.lua');

let cached;
function resolve() {
  if (cached) return cached;
  const flavors = process.env.WFSYNC_WOW_DIR ? [process.env.WFSYNC_WOW_DIR] : flavorDirs();
  if (flavors.length === 0) throw new Error('WoW folder not found; set WFSYNC_WOW_DIR');
  let best;
  for (const flavor of flavors) {
    const accounts = process.env.WFSYNC_ACCOUNT
      ? [path.join(flavor, 'WTF', 'Account', process.env.WFSYNC_ACCOUNT)]
      : accountsOf(flavor);
    for (const account of accounts) {
      const f = dbFile(account);
      if (!fs.existsSync(f)) continue;
      const mtime = fs.statSync(f).mtimeMs;
      if (!best || mtime > best.mtime) best = { flavor, account, mtime };
    }
  }
  if (!best) {
    const flavor = flavors[0];
    const accounts = process.env.WFSYNC_ACCOUNT
      ? [path.join(flavor, 'WTF', 'Account', process.env.WFSYNC_ACCOUNT)]
      : accountsOf(flavor).sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs);
    best = { flavor, account: accounts[0] ?? null };
  }
  cached = best;
  return best;
}

export function wowDir() { return resolve().flavor; }

export function savedVariablesFile() {
  const { account } = resolve();
  if (!account) throw new Error(`no account folder under ${wowDir()}/WTF/Account; log in once or set WFSYNC_ACCOUNT`);
  return dbFile(account);
}

// The WFSync_Data mini add-on belongs to the companion; WFSync only reads it.
export function dataAddonDir() {
  return path.join(wowDir(), 'Interface', 'AddOns', 'WFSync_Data');
}

export function stateDir() {
  const dir = process.env.WFSYNC_HOME || path.join(os.homedir(), '.wfsync');
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

// Settings `wfsync sync --dir/--handle` saves for later runs (and double-click).
const configFile = () => path.join(stateDir(), 'config.json');
export const loadConfig = () => (fs.existsSync(configFile()) ? JSON.parse(fs.readFileSync(configFile(), 'utf8')) : {});
export function saveConfig(patch) {
  const c = { ...loadConfig(), ...patch };
  // Holds the web token: readable by this user only.
  fs.writeFileSync(configFile(), JSON.stringify(c, null, 1), { mode: 0o600 });
  fs.chmodSync(configFile(), 0o600);
  return c;
}

export function myHandle() {
  return process.env.WFSYNC_HANDLE || loadConfig().handle || os.userInfo().username;
}

export function sharedDir() {
  return process.env.WFSYNC_SHARED || loadConfig().shared || null;
}
