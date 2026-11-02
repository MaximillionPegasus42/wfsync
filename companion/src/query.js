import { readDb, myChar, asList, completedIds, loadPlayers, xpPercent } from './sync.js';
import { myHandle } from './paths.js';

// One view over everybody: own character from SavedVariables, others from players.json.
export function allPlayers() {
  const out = {};
  try {
    const c = myChar(readDb());
    const { name, events, sessions, completed, ...rest } = c;
    out[myHandle()] = { char: name, ...rest, recent: asList(events), sessions: asList(sessions), completed: completedIds(c), self: true };
  } catch (e) {
    out[myHandle()] = { error: e.message, self: true };
  }
  for (const [handle, p] of Object.entries(loadPlayers())) {
    out[handle] = { ...p.entry, completed: p.completed, seq: p.seq, received: new Date(p.updated).toISOString() };
  }
  return out;
}

function pick(handle) {
  const all = allPlayers();
  const h = handle ?? myHandle();
  if (!all[h]) throw new Error(`unknown player ${h}; known: ${Object.keys(all).join(', ')}`);
  if (all[h].error) throw new Error(all[h].error);
  return [h, all[h]];
}

const iso = t => (t ? new Date(t * 1000).toISOString() : null);

export function status(handle) {
  const [h, p] = pick(handle);
  return {
    handle: h, char: p.char, class: p.class, race: p.race, faction: p.faction,
    level: p.level, xp_percent: xpPercent(p), rested: p.rested,
    zone: p.zone, subzone: p.subzone, pos: p.pos, money: p.money, guild: p.guild,
    quests_completed: p.completed.length,
    quest_log: Object.entries(p.log ?? {}).map(([id, q]) => ({ id: Number(id), title: q.title })),
    updated: iso(p.updated),
  };
}

export function recentEvents(handle, { limit = 20, type } = {}) {
  const [h, p] = pick(handle);
  let ev = p.recent ?? [];
  if (type) ev = ev.filter(e => e.type === type);
  return { handle: h, events: ev.slice(-limit).map(e => ({ ...e, at: iso(e.t) })) };
}

export function completed(handle) {
  const [h, p] = pick(handle);
  return { handle: h, count: p.completed.length, ids: p.completed };
}

export function sessions() {
  const [h, p] = pick();
  return { handle: h, sessions: (p.sessions ?? []).map(s => ({ ...s, start: iso(s.start), stop: iso(s.stop) })) };
}

export function questStatus(ids) {
  const all = allPlayers();
  return ids.map(id => {
    const row = { id };
    for (const [h, p] of Object.entries(all)) {
      if (p.error) continue;
      row[h] = p.completed.includes(id) ? 'completed' : p.log?.[id] ? 'in_log' : 'open';
    }
    return row;
  });
}

export function overview() {
  const all = Object.entries(allPlayers()).filter(([, p]) => !p.error);
  const players = all.map(([h, p]) => ({
    handle: h, char: p.char, level: p.level, xp_percent: xpPercent(p), zone: p.zone, updated: iso(p.updated),
  }));
  const levels = players.map(p => p.level).filter(Number.isFinite);
  // Quests sitting in at least two quest logs right now: easy to do together.
  const inLog = new Map();
  for (const [h, p] of all) {
    for (const [id, q] of Object.entries(p.log ?? {})) {
      const e = inLog.get(id) ?? { id: Number(id), title: q.title, players: [] };
      e.players.push(h);
      inLog.set(id, e);
    }
  }
  return {
    players,
    level_range: levels.length ? [Math.min(...levels), Math.max(...levels)] : null,
    shared_quests: [...inLog.values()].filter(q => q.players.length > 1),
  };
}
