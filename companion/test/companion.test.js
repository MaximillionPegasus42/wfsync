import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { parseSavedVariables, toLua } from '../src/lua.js';

const BIN = new URL('../bin/wfsync.js', import.meta.url).pathname;

const DEFAULT_LOG = '[1250] = { ["title"] = "Bounty", ["accepted"] = 1792990000 }';

function fixtureDb({ level = 23, xp = 4120, completed = [100, 101], zone = 'Ashenvale', updated = 1793000000, log = DEFAULT_LOG, events = '', faction = 'Horde' } = {}) {
  return `
WFSync_DB = {
	["schema"] = 1,
	["chars"] = {
		["Zitzenmelkee-Spineshatter"] = {
			["updated"] = ${updated},
			["class"] = "WARRIOR", ["race"] = "Orc", ["faction"] = "${faction}",
			["level"] = ${level}, ["xp"] = ${xp}, ["xpMax"] = 9800, ["rested"] = 1200,
			["zone"] = "${zone}", ["subzone"] = "Astranaar \\"Ost\\"", ["mapID"] = 1440,
			["pos"] = { ["x"] = 0.412, ["y"] = 0.633 },
			["money"] = 154321,
			["completed"] = { ${completed.map(id => `[${id}] = true`).join(', ')} },
			["log"] = { ${log} },
			["events"] = {
				{ ["t"] = 1792999000, ["type"] = "quest_turnin", ["id"] = 101, ["title"] = "Wolves", ["zone"] = "Ashenvale" },
				{ ["t"] = 1792999500, ["type"] = "levelup", ["level"] = ${level} }, -- comment
				${events}
			},
			["sessions"] = { { ["start"] = 1792990000, ["stop"] = 1793000000, ["xpGained"] = 9000, ["levelFrom"] = 22, ["levelTo"] = ${level} } },
		},
	},
}
`;
}

function setup(handle) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), `wfsync-${handle}-`));
  const wow = path.join(root, '_classic_era_');
  const sv = path.join(wow, 'WTF', 'Account', 'ACC1', 'SavedVariables');
  fs.mkdirSync(sv, { recursive: true });
  const env = { ...process.env, WFSYNC_WOW_DIR: wow, WFSYNC_HOME: path.join(root, 'state'), WFSYNC_HANDLE: handle };
  const run = (args, input) => execFileSync('node', [BIN, ...args], { env, input, encoding: 'utf8' });
  return { wow, svFile: path.join(sv, 'WFSync.lua'), run };
}

test('parses WoW-style SavedVariables', () => {
  const v = parseSavedVariables(fixtureDb());
  const c = v.WFSync_DB.chars['Zitzenmelkee-Spineshatter'];
  assert.equal(c.level, 23);
  assert.equal(c.subzone, 'Astranaar "Ost"');
  assert.deepEqual(c.completed, { 100: true, 101: true });
  assert.equal(c.events.length, 2);
  assert.equal(c.events[1].type, 'levelup');
});

test('parses nil holes, [0] keys and negative numbers', () => {
  const v = parseSavedVariables('X = { 1, nil, 3, [0] = -2.5, ["a b"] = "x" }\nY = 0x10');
  assert.deepEqual(v.X, { 1: 1, 3: 3, 0: -2.5, 'a b': 'x' });
  assert.equal(v.Y, 16);
});

test('toLua round-trips', () => {
  const data = { schema: 1, players: { mf: { char: 'A-B', completed: { 5: true }, recent: [{ t: 1, type: 'zone' }] }, 'we"ird': { end: 'x\ny' } } };
  assert.deepEqual(parseSavedVariables(`Z = ${toLua(data)}`).Z, data);
});

test('real Blizzard SavedVariables on this machine parse', () => {
  const dir = '/Applications/World of Warcraft/_classic_era_/WTF/Account';
  if (!fs.existsSync(dir)) return;
  const files = execFileSync('find', [dir, '-name', '*.lua'], { encoding: 'utf8' }).split('\n').filter(Boolean);
  for (const f of files) parseSavedVariables(fs.readFileSync(f, 'utf8'));
});

test('snapshot full -> delta -> ingest on the other side -> Remote.lua', () => {
  const mf = setup('mf');
  const lois = setup('lois');
  fs.writeFileSync(mf.svFile, fixtureDb());

  const first = mf.run(['snapshot']);
  assert.match(first, /^mf: Lvl 23 \(42 %\) · Ashenvale/);
  assert.match(first, /"full":true/);
  assert.equal(mf.run(['snapshot']), '', 'unchanged state posts nothing');

  fs.writeFileSync(mf.svFile, fixtureDb({ level: 24, xp: 100, completed: [100, 101, 102, 103] }));
  const second = mf.run(['snapshot']);
  assert.match(second, /\+2 Quests/);
  assert.match(second, /"completed_add":\[102,103\]/);

  // lois receives the delta first: needs a full snapshot.
  assert.equal(JSON.parse(lois.run(['ingest'], second))[0].status, 'need_full');
  assert.equal(JSON.parse(lois.run(['ingest'], first))[0].status, 'full');
  assert.equal(JSON.parse(lois.run(['ingest'], second))[0].status, 'delta');

  const remoteFile = path.join(lois.wow, 'Interface', 'AddOns', 'WFSync_Data', 'Remote.lua');
  const remote = parseSavedVariables(fs.readFileSync(remoteFile, 'utf8')).WFSync_Remote;
  assert.equal(remote.players.mf.level, 24);
  assert.deepEqual(Object.keys(remote.players.mf.completed), ['100', '101', '102', '103']);
  assert.equal(remote.players.mf.recent.length, 2);
  assert.ok(fs.existsSync(path.join(lois.wow, 'Interface', 'AddOns', 'WFSync_Data', 'WFSync_Data.toc')));

  const ov = JSON.parse(lois.run(['overview']));
  assert.ok(ov.players.some(p => p.handle === 'mf' && p.level === 24));
});

test('MCP server lists and calls tools', () => {
  const mf = setup('mf');
  fs.writeFileSync(mf.svFile, fixtureDb());
  const input = [
    { jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18' } },
    { jsonrpc: '2.0', method: 'notifications/initialized' },
    { jsonrpc: '2.0', id: 2, method: 'tools/list' },
    { jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'get_status', arguments: {} } },
    { jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'quest_status', arguments: { quest_ids: [101, 1250, 999] } } },
  ].map(m => JSON.stringify(m)).join('\n') + '\n';
  const out = mf.run(['mcp'], input).trim().split('\n').map(l => JSON.parse(l));
  assert.equal(out.length, 4);
  assert.ok(out[1].result.tools.some(t => t.name === 'make_snapshot'));
  assert.equal(JSON.parse(out[2].result.content[0].text).level, 23);
  assert.deepEqual(JSON.parse(out[3].result.content[0].text).map(r => r.mf), ['completed', 'in_log', 'open']);
});

test('addon fixture from the WFSync repo (quest IDs 1..n stay IDs)', () => {
  const fixture = new URL('../../tests/fixtures/SavedVariables/WFSync.lua', import.meta.url).pathname;
  if (!fs.existsSync(fixture)) return;
  const lois = setup('lois');
  fs.copyFileSync(fixture, lois.svFile);
  const st = JSON.parse(lois.run(['status']));
  assert.equal(st.char, 'Lois-Forever');
  assert.equal(st.quests_completed, 2);
  assert.deepEqual(st.quest_log.map(q => q.id), [102]);
  const snap = lois.run(['snapshot']);
  assert.match(snap, /"completed":\[1,2\]/);
});

test('ingest with author rejects spoofed handles', () => {
  const mf = setup('mf');
  const lois = setup('lois');
  fs.writeFileSync(mf.svFile, fixtureDb());
  const post = mf.run(['snapshot']);
  assert.equal(JSON.parse(lois.run(['ingest', '--author', 'eve'], post))[0].status, 'rejected');
  assert.equal(JSON.parse(lois.run(['ingest', '--author', 'wow-forever-builder@mf'], post))[0].status, 'full');
});

test('WFSync_Data.toc follows the WFSync Interface number', () => {
  const mf = setup('mf');
  const lois = setup('lois');
  fs.writeFileSync(mf.svFile, fixtureDb());
  const main = path.join(lois.wow, 'Interface', 'AddOns', 'WFSync');
  fs.mkdirSync(main, { recursive: true });
  fs.writeFileSync(path.join(main, 'WFSync.toc'), '## Interface: 11508\n## Title: WFSync\n');
  lois.run(['ingest'], mf.run(['snapshot']));
  const toc = path.join(lois.wow, 'Interface', 'AddOns', 'WFSync_Data', 'WFSync_Data.toc');
  assert.match(fs.readFileSync(toc, 'utf8'), /## Interface: 11508/);
  fs.writeFileSync(path.join(main, 'WFSync.toc'), '## Interface: 11600\r\n## Title: WFSync\r\n');
  lois.run(['remote']);
  assert.match(fs.readFileSync(toc, 'utf8'), /## Interface: 11600\n/, 'CRLF TOC is read too');
});

test('sync through a shared folder, newest updated wins, quests add up', () => {
  const shared = fs.mkdtempSync(path.join(os.tmpdir(), 'wfsync-shared-'));
  const mf = setup('mf');
  const lois = setup('lois');
  fs.writeFileSync(mf.svFile, fixtureDb({ level: 23, completed: [100, 101] }));
  fs.writeFileSync(lois.svFile, fixtureDb({ level: 30 }));

  const a = JSON.parse(mf.run(['sync', '--dir', shared]));
  assert.equal(a.own, 'written');
  assert.deepEqual(a.players, []);
  assert.equal(JSON.parse(mf.run(['sync'])).own, 'unchanged', '--dir is remembered');

  const b = JSON.parse(lois.run(['sync', '--dir', shared]));
  assert.deepEqual(b.players.map(p => [p.handle, p.status, p.level]), [['mf', 'updated', 23]]);
  const remote = fs.readFileSync(path.join(lois.wow, 'Interface', 'AddOns', 'WFSync_Data', 'Remote.lua'), 'utf8');
  assert.match(remote, /\tmf = \{/);
  assert.equal(JSON.parse(lois.run(['status', 'mf'])).level, 23);

  // A newer room snapshot beats an older file; the file's quests still count.
  const post = mf.run(['snapshot', '--full', '--peek']).replace('"updated":1793000000', '"updated":1793009999')
    .replace('"level":23', '"level":24').replace('"completed":[100,101]', '"completed":[100,102]');
  lois.run(['ingest'], post);
  const c = JSON.parse(lois.run(['sync']));
  assert.equal(c.players[0].status, 'kept newer');
  assert.equal(JSON.parse(lois.run(['status', 'mf'])).level, 24);
  assert.equal(JSON.parse(lois.run(['status', 'mf'])).quests_completed, 3);
});

test('sync ignores files whose handle does not match the name', () => {
  const shared = fs.mkdtempSync(path.join(os.tmpdir(), 'wfsync-shared-'));
  const lois = setup('lois');
  fs.writeFileSync(lois.svFile, fixtureDb());
  fs.writeFileSync(path.join(shared, 'eve.json'), JSON.stringify({ v: 1, handle: 'mf', full: true, level: 60 }));
  const r = JSON.parse(lois.run(['sync', '--dir', shared]));
  assert.deepEqual(r.players.map(p => [p.handle, p.status]), [['eve', 'ignored']]);
});

test('sync pulls and pushes a git checkout', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wfsync-git-'));
  const g = (...a) => execFileSync('git', a, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  g('init', '-q', '--bare', '-b', 'main', path.join(root, 'hub.git'));
  for (const who of ['mf', 'lois']) {
    g('clone', '-q', path.join(root, 'hub.git'), path.join(root, who));
    g('-C', path.join(root, who), 'config', 'user.name', who);
    g('-C', path.join(root, who), 'config', 'user.email', `${who}@example.com`);
  }
  const mf = setup('mf');
  const lois = setup('lois');
  fs.writeFileSync(mf.svFile, fixtureDb({ level: 23 }));
  fs.writeFileSync(lois.svFile, fixtureDb({ level: 30 }));
  const a = JSON.parse(mf.run(['sync', '--dir', path.join(root, 'mf')]));
  assert.equal(a.git.push, 'ok');
  const b = JSON.parse(lois.run(['sync', '--dir', path.join(root, 'lois')]));
  assert.equal(b.git.pull, 'ok');
  assert.equal(b.git.push, 'ok');
  assert.deepEqual(b.players.map(p => [p.handle, p.level]), [['mf', 23]]);
  const c = JSON.parse(mf.run(['sync']));
  assert.deepEqual(c.players.map(p => [p.handle, p.level]), [['lois', 30]]);

  // A failed push is retried on the next run, although the file is unchanged by then.
  fs.writeFileSync(mf.svFile, fixtureDb({ level: 24 }));
  g('-C', path.join(root, 'mf'), 'remote', 'set-url', 'origin', path.join(root, 'gone.git'));
  const d = JSON.parse(mf.run(['sync']));
  assert.equal(d.own, 'written');
  assert.match(d.git.push, /^failed/);
  g('-C', path.join(root, 'mf'), 'remote', 'set-url', 'origin', path.join(root, 'hub.git'));
  const e = JSON.parse(mf.run(['sync']));
  assert.equal(e.own, 'unchanged');
  assert.equal(e.git.push, 'ok');
  assert.equal(JSON.parse(lois.run(['sync'])).players[0].level, 24);
});

test('sync handle must not be . or ..', () => {
  const shared = fs.mkdtempSync(path.join(os.tmpdir(), 'wfsync-shared-'));
  const mf = setup('mf');
  fs.writeFileSync(mf.svFile, fixtureDb());
  assert.throws(() => mf.run(['sync', '--dir', shared, '--handle', '..'], undefined), /not a plain name/);
});

test('flavor folder: newest WFSync.lua wins, beta folders included, ranked last otherwise', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wfsync-root-'));
  const acc = flavor => path.join(root, flavor, 'WTF', 'Account', 'ACC1', 'SavedVariables');
  for (const f of ['_classic_era_', '_classic_beta_']) fs.mkdirSync(acc(f), { recursive: true });
  const env = { ...process.env, WFSYNC_WOW_ROOT: root, WFSYNC_HOME: path.join(root, 'state') };
  delete env.WFSYNC_WOW_DIR;
  const wow = () => JSON.parse(execFileSync('node', [BIN, 'paths'], { env, encoding: 'utf8' })).wow;
  assert.equal(path.basename(wow()), '_classic_era_', 'no WFSync.lua anywhere: beta ranks last');
  fs.writeFileSync(path.join(acc('_classic_era_'), 'WFSync.lua'), fixtureDb());
  const old = new Date(Date.now() - 60000);
  fs.utimesSync(path.join(acc('_classic_era_'), 'WFSync.lua'), old, old);
  fs.writeFileSync(path.join(acc('_classic_beta_'), 'WFSync.lua'), fixtureDb());
  assert.equal(path.basename(wow()), '_classic_beta_', 'the folder WFSync wrote last wins');
});

test('suggest: quests together, quests to pick up, friends nearby, gaps, dungeons', () => {
  const fresh = Math.floor(Date.now() / 1000) - 600;
  const q = (id, title, level) => `[${id}] = { ["title"] = "${title}", ["level"] = ${level} }`;
  const mf = setup('mf');
  const lois = setup('lois');
  const bob = setup('bob');
  fs.writeFileSync(mf.svFile, fixtureDb({ level: 23, updated: fresh, log: [q(1250, 'Bounty', 24), q(1300, 'Owls', 22)].join(', ') }));
  fs.writeFileSync(lois.svFile, fixtureDb({
    level: 25, updated: fresh, completed: [100],
    log: [q(1250, 'Bounty', 24), q(1400, 'Naga', 24), q(1500, 'Too high', 30), q(101, 'Done already', 20)].join(', '),
    events: '{ ["t"] = 1792999600, ["type"] = "quest_accept", ["id"] = 1400, ["title"] = "Naga", ["zone"] = "Ashenvale" },',
  }));
  fs.writeFileSync(bob.svFile, fixtureDb({ level: 17, updated: fresh, zone: 'Durotar', log: '' }));
  mf.run(['ingest'], lois.run(['snapshot']));
  mf.run(['ingest'], bob.run(['snapshot']));

  const s = JSON.parse(mf.run(['suggest']));
  assert.deepEqual(s.together.map(x => [x.id, x.with]), [[1250, ['lois']]]);
  assert.deepEqual(s.pick_up.map(x => [x.id, x.zone, x.on]), [[1400, 'Ashenvale', ['lois']]], 'too high and already done are left out');
  assert.deepEqual(s.nearby.map(x => x.handle), ['lois']);
  assert.deepEqual(s.behind, [{ handle: 'bob', level: 17, behind: 8 }]);
  assert.deepEqual(s.dungeons.party, ['mf', 'lois']);
  assert.deepEqual(s.dungeons.ideas.map(d => d.name), ['The Deadmines', 'Shadowfang Keep', 'Blackfathom Deeps']);
});

test('suggest leaves out the other faction and stale players', () => {
  const fresh = Math.floor(Date.now() / 1000) - 600;
  const mf = setup('mf');
  const eve = setup('eve');
  const old = setup('old');
  fs.writeFileSync(mf.svFile, fixtureDb({ updated: fresh }));
  fs.writeFileSync(eve.svFile, fixtureDb({ updated: fresh, faction: 'Alliance' }));
  fs.writeFileSync(old.svFile, fixtureDb({ updated: fresh - 30 * 86400 }));
  mf.run(['ingest'], eve.run(['snapshot']));
  mf.run(['ingest'], old.run(['snapshot']));
  const s = JSON.parse(mf.run(['suggest']));
  assert.deepEqual(s.together, []);
  assert.deepEqual(s.nearby, []);
  assert.deepEqual(s.dungeons.party, ['mf']);
});
