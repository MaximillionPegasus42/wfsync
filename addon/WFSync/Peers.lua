-- WFSync Peers: führt den Stand der Mitspieler aus zwei Quellen zusammen:
--   1) WFSync_Remote (Datei vom Companion, Add-on WFSync_Data) – auch wenn jemand offline ist
--   2) ns.db.peers   (live per Addon-Message gesehen, in den SavedVariables gemerkt)
local ADDON, ns = ...

local ONLINE_WINDOW = 300 -- Sekunden ohne Nachricht, bis jemand als offline gilt

local STATUS_FIELDS = {
  "char", "class", "race", "faction", "level", "xp", "xpMax", "rested",
  "zone", "subzone", "mapID", "pos", "money", "guild", "updated",
}

local function remotePlayers()
  local remote = WFSync_Remote
  if type(remote) ~= "table" or type(remote.players) ~= "table" then return {} end
  return remote.players
end

local function lastQuestFrom(recent)
  if type(recent) ~= "table" then return nil end
  local best
  for _, evt in ipairs(recent) do
    if type(evt) == "table" and evt.type == "quest_turnin" and (not best or (evt.t or 0) >= (best.t or 0)) then
      best = evt
    end
  end
  return best
end

-- Liefert eine Liste von Personen:
-- { name, handle?, char, level, xp, xpMax, zone, subzone, updated, online,
--   completedSets = {set...}, log?, lastQuest = {title, t}? }
function ns.People()
  local selfKey = ns.key or ns.PlayerKey()
  local people, byChar = {}, {}

  for handle, p in pairs(remotePlayers()) do
    if type(p) == "table" and p.char ~= selfKey then
      local person = { name = handle, handle = handle, completedSets = {}, source = "remote" }
      for _, f in ipairs(STATUS_FIELDS) do person[f] = p[f] end
      if type(p.completed) == "table" then table.insert(person.completedSets, p.completed) end
      if type(p.log) == "table" then person.log = p.log end
      person.lastQuest = lastQuestFrom(p.recent)
      people[#people + 1] = person
      if p.char then byChar[p.char] = person end
    end
  end

  local now = time()
  for charKey, live in pairs(ns.db and ns.db.peers or {}) do
    if charKey ~= selfKey then
      local person = byChar[charKey]
      if not person then
        person = { name = ns.ShortName(charKey), char = charKey, completedSets = {}, source = "live" }
        people[#people + 1] = person
        byChar[charKey] = person
      end
      if (live.updated or 0) >= (person.updated or 0) then
        for _, f in ipairs(STATUS_FIELDS) do
          if live[f] ~= nil then person[f] = live[f] end
        end
      end
      if live.completed then table.insert(person.completedSets, live.completed) end
      if live.lastQuest and (not person.lastQuest or (live.lastQuest.t or 0) > (person.lastQuest.t or 0)) then
        person.lastQuest = live.lastQuest
      end
      person.online = (now - (live.lastSeen or 0)) < ONLINE_WINDOW
    end
  end

  table.sort(people, function(a, b)
    if (a.online and 1 or 0) ~= (b.online and 1 or 0) then return a.online and true or false end
    return (a.name or "") < (b.name or "")
  end)
  return people
end

function ns.HasCompleted(person, questID)
  for _, set in ipairs(person.completedSets or {}) do
    if set[questID] or set[tostring(questID)] then return true end
  end
  return false
end

-- "done" | "active" | "open"
function ns.QuestStatusOf(person, questID)
  if ns.HasCompleted(person, questID) then return "done" end
  if person.log and (person.log[questID] or person.log[tostring(questID)]) then return "active" end
  return "open"
end

function ns.QuestStatus(questID)
  local out = {}
  for _, person in ipairs(ns.People()) do
    out[#out + 1] = { person = person, status = ns.QuestStatusOf(person, questID) }
  end
  return out
end

-- Live-Daten eines Mitspielers aktualisieren (aus Sync.lua)
function ns.UpdatePeer(charKey, fields)
  if not ns.db then return nil end
  local peer = ns.db.peers[charKey]
  if not peer then
    peer = { char = charKey }
    ns.db.peers[charKey] = peer
  end
  for k, v in pairs(fields) do peer[k] = v end
  peer.lastSeen = time()
  ns.Fire("PEERS_CHANGED", charKey)
  return peer
end
