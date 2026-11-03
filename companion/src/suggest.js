// What should we do next? Built only from our own data (logs, levels, zones, recent
// events), no external quest database. The dungeon table holds Classic Era level
// ranges as a rough guide; WoW Forever may differ.
import { allPlayers } from './query.js';
import { myHandle } from './paths.js';

// [name, min, max, faction or null]
export const DUNGEONS = [
  ['Ragefire Chasm', 13, 18, 'Horde'],
  ['Wailing Caverns', 17, 24, null],
  ['The Deadmines', 17, 26, null],
  ['Shadowfang Keep', 22, 30, null],
  ['Blackfathom Deeps', 24, 32, null],
  ['The Stockade', 24, 32, 'Alliance'],
  ['Gnomeregan', 29, 38, null],
  ['Razorfen Kraul', 29, 38, null],
  ['Scarlet Monastery: Graveyard', 30, 37, null],
  ['Scarlet Monastery: Library', 33, 40, null],
  ['Scarlet Monastery: Armory', 35, 42, null],
  ['Scarlet Monastery: Cathedral', 36, 45, null],
  ['Razorfen Downs', 37, 46, null],
  ['Uldaman', 41, 51, null],
  ["Zul'Farrak", 44, 54, null],
  ['Maraudon', 46, 55, null],
  ['Sunken Temple', 50, 56, null],
  ['Blackrock Depths', 52, 60, null],
  ['Lower Blackrock Spire', 55, 60, null],
  ['Dire Maul', 55, 60, null],
  ['Scholomance', 58, 60, null],
  ['Stratholme', 58, 60, null],
  ['Upper Blackrock Spire', 58, 60, null],
];

const NEARBY_LEVELS = 5;      // close enough in level to quest together
const NEARBY_FRESH = 2 * 3600; // zone older than this is not "right now"
const ACTIVE = 7 * 86400;     // players not updated for a week are left out
const BEHIND = 4;             // levels behind the group's top before we call it a gap

const now = () => Math.floor(Date.now() / 1000);

// Zone where a quest was picked up, from anyone's quest_accept events.
function questZones(players) {
  const zones = {};
  for (const p of players) {
    for (const e of p.recent ?? []) if (e.type === 'quest_accept' && e.zone) zones[e.id] = e.zone;
  }
  return zones;
}

function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.floor((s.length - 1) / 2)];
}

// Dungeons the whole group can do: every level inside [min - 2, max], same faction
// rules, ranked by how close the group's median sits to the middle of the range.
export function dungeonsFor(levels, faction, limit = 3) {
  if (levels.length === 0) return [];
  const lo = Math.min(...levels);
  const hi = Math.max(...levels);
  const mid = median(levels);
  return DUNGEONS
    .filter(([, min, max, f]) => (!f || !faction || f === faction) && lo >= min - 2 && hi <= max)
    .map(([name, min, max]) => ({ name, levels: `${min}-${max}`, fit: Math.abs(mid - (min + max) / 2) }))
    .sort((a, b) => a.fit - b.fit)
    .slice(0, limit)
    .map(({ name, levels: l }) => ({ name, levels: l }));
}

export function suggest(handle = myHandle(), { with: only } = {}) {
  const all = allPlayers();
  const me = all[handle];
  if (!me) throw new Error(`unknown player ${handle}; known: ${Object.keys(all).join(', ')}`);
  if (me.error) throw new Error(me.error);
  const t = now();
  const others = Object.entries(all)
    .filter(([h, p]) => h !== handle && !p.error && (!only || only.includes(h)))
    .filter(([, p]) => !p.updated || t - p.updated < ACTIVE)
    .filter(([, p]) => !me.faction || !p.faction || p.faction === me.faction)
    .map(([h, p]) => ({ handle: h, ...p }));
  const zones = questZones([me, ...others]);
  const done = p => new Set(p.completed ?? []);
  const mine = done(me);

  // Quests in my log that friends have too: do them together.
  const together = Object.entries(me.log ?? {}).map(([id, q]) => ({
    id: Number(id), title: q.title, level: q.level, zone: zones[id],
    with: others.filter(p => p.log?.[id]).map(p => p.handle),
  })).filter(q => q.with.length > 0).sort((a, b) => b.with.length - a.with.length);

  // Quests friends are on that I have neither done nor picked up, at my level.
  const pickUp = new Map();
  for (const p of others) {
    for (const [id, q] of Object.entries(p.log ?? {})) {
      if (mine.has(Number(id)) || me.log?.[id]) continue;
      if (q.level && me.level && q.level > me.level + 2) continue;
      const e = pickUp.get(id) ?? { id: Number(id), title: q.title, level: q.level, zone: zones[id], on: [] };
      e.on.push(p.handle);
      pickUp.set(id, e);
    }
  }

  // Friends in my zone right now, close enough in level.
  const nearby = others
    .filter(p => p.zone && p.zone === me.zone && (!p.updated || t - p.updated < NEARBY_FRESH))
    .filter(p => !me.level || !p.level || Math.abs(p.level - me.level) <= NEARBY_LEVELS)
    .map(p => ({ handle: p.handle, char: p.char, level: p.level, subzone: p.subzone }));

  const group = [{ handle, ...me }, ...others].filter(p => Number.isFinite(p.level));
  const top = Math.max(...group.map(p => p.level));
  const behind = group.filter(p => top - p.level >= BEHIND)
    .map(p => ({ handle: p.handle, level: p.level, behind: top - p.level }));

  // Dungeons for me plus everyone within reach of my level.
  const party = group.filter(p => !me.level || Math.abs(p.level - me.level) <= NEARBY_LEVELS);
  const lastDungeons = [me, ...others].flatMap(p => (p.recent ?? [])
    .filter(e => e.type === 'dungeon_enter').map(e => ({ handle: p.handle ?? handle, name: e.name ?? e.zone, at: e.t })));

  return {
    handle,
    level: me.level,
    zone: me.zone,
    together,
    pick_up: [...pickUp.values()].sort((a, b) => b.on.length - a.on.length || (a.level ?? 0) - (b.level ?? 0)).slice(0, 10),
    nearby,
    behind,
    dungeons: {
      party: party.map(p => p.handle),
      ideas: dungeonsFor(party.map(p => p.level), me.faction),
      recent: lastDungeons.sort((a, b) => (b.at ?? 0) - (a.at ?? 0)).slice(0, 5),
    },
    note: 'Dungeon level ranges are Classic Era guide values. Quest zones come from quest_accept events and may be missing.',
  };
}
