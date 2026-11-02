-- Tests für WFSync ohne WoW. Ausführen aus dem Repo-Root:  luajit tests/run.lua
package.path = "./tests/?.lua;" .. package.path
local mock = require("mock_wow")

local ADDON_DIR = "addon/WFSync"
local FILES = { "Core.lua", "Collect.lua", "Peers.lua", "Sync.lua", "UI.lua" }
local REMOTE = "tests/fixtures/WFSync_Data/Remote.lua"

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("  ok   " .. name)
  else
    failed = failed + 1
    print("  FAIL " .. name .. "\n       " .. tostring(err))
  end
end
local function eq(a, b, msg)
  if a ~= b then error((msg or "") .. " erwartet " .. tostring(b) .. ", bekommen " .. tostring(a), 2) end
end
local function has(haystack, needle, msg)
  if not tostring(haystack):find(needle, 1, true) then
    error((msg or "") .. " '" .. needle .. "' fehlt in: " .. tostring(haystack), 2)
  end
end

local function manyCompleted(n, start)
  local t = {}
  for i = 0, n - 1 do t[start + i] = true end
  return t
end

---------------------------------------------------------------------------
-- Aufbau: zwei Spieler in Gruppe und Gilde, lois hat zusätzlich Companion-Daten
---------------------------------------------------------------------------
local bus = mock.NewBus()
local lois = mock.NewClient(bus, "Lois", {
  level = 20, xp = 4000, xpMax = 8000, rested = 500, money = 12345,
  zone = "Brachland", subzone = "Crossroads", mapID = 1413, x = 0.5123, y = 0.3011,
  guild = "Horde Helden", group = "g1",
  completed = { [1] = true, [2] = true },
  questLog = {
    { title = "Brachland", isHeader = true },
    { title = "Plünderer", level = 18, id = 102 },
  },
})
local mf = mock.NewClient(bus, "Mf", {
  level = 22, xp = 3000, xpMax = 9000,
  zone = "Silberwald", subzone = "Grabesmoor", mapID = 1421, x = 0.4, y = 0.6,
  guild = "Horde Helden", group = "g1",
  completed = manyCompleted(300, 1000), -- erzwingt mehrere C-Teile
  questLog = {},
})

local loisNS = mock.LoadAddon(lois, ADDON_DIR, FILES, REMOTE)
local mfNS = mock.LoadAddon(mf, ADDON_DIR, FILES)
mock.Login(lois, nil)
mock.Login(mf, nil)

print("WFSync Tests")

test("Eigener Stand wird bei Login gesammelt", function()
  local c = loisNS.char
  eq(loisNS.key, "Lois-Forever", "key")
  eq(c.level, 20, "level")
  eq(c.xp, 4000, "xp")
  eq(c.zone, "Brachland", "zone")
  eq(c.subzone, "Crossroads", "subzone")
  eq(c.pos.x, 0.512, "pos.x gerundet")
  eq(c.guild, "Horde Helden", "guild")
  eq(c.class, "WARRIOR", "class")
  eq(c.completed[1], true, "completed")
  eq(c.log[102].title, "Plünderer", "questlog")
  eq(#c.sessions, 1, "session")
  eq(c.events[1].type, "login", "login-event")
end)

bus:advance(20)

test("Live-Sync: Status und alle abgeschlossenen Quests kommen an", function()
  local peer = lois.env.WFSync_DB.peers["Mf-Forever"]
  assert(peer, "peer fehlt")
  eq(peer.level, 22, "level")
  eq(peer.zone, "Silberwald", "zone")
  eq(loisNS.CountKeys(peer.completed), 300, "completed")
  local back = mf.env.WFSync_DB.peers["Lois-Forever"]
  assert(back, "Rückrichtung fehlt")
  eq(loisNS.CountKeys(back.completed), 2, "completed lois")
end)

test("Alle Addon-Messages <= 255 Byte und mehrteilig bei vielen Quests", function()
  local chunks = 0
  for _, m in ipairs(bus.sent) do
    assert(#m.text <= 255)
    if m.text:sub(1, 2) == "C^" and m.from == "Mf" then chunks = chunks + 1 end
  end
  assert(chunks >= 2, "erwartet mehrere C-Teile, bekommen " .. chunks)
end)

test("Remote- und Live-Daten werden zu einer Person zusammengeführt", function()
  local people = loisNS.People()
  eq(#people, 1, "Anzahl Personen (lois selbst ausgeschlossen)")
  eq(people[1].name, "mf", "Name aus Remote-Handle")
  eq(people[1].online, true, "online")
  eq(people[1].level, 22, "level")
end)

test("Quest-Abgabe wird live übertragen", function()
  mf.world.completed[500] = true
  mf:fire("QUEST_TURNED_IN", 500, 1200, 0)
  bus:advance(1)
  local peer = lois.env.WFSync_DB.peers["Mf-Forever"]
  eq(peer.completed[500], true, "completed 500")
  eq(mfNS.char.events[#mfNS.char.events].type, "quest_turnin", "eigenes Event")
end)

test("Quest-Status: erledigt / im Questlog / offen", function()
  has(table.concat(loisNS.QuestStatusLines(500), "\n"), "erledigt")
  has(table.concat(loisNS.QuestStatusLines(100), "\n"), "erledigt") -- nur aus Remote.lua
  has(table.concat(loisNS.QuestStatusLines(102), "\n"), "im Questlog")
  has(table.concat(loisNS.QuestStatusLines(999), "\n"), "offen")
end)

test("Tooltip von Quest-Links zeigt Mitspieler", function()
  lois.env.GameTooltip:SetHyperlink("quest:500:23")
  has(table.concat(lois.env.GameTooltip.lines, "\n"), "mf")
end)

test("Panel am Questlog zeigt Status der ausgewählten Quest", function()
  lois.world.selected = 2
  lois.env.QuestLogFrame:Show()
  local panel = lois.env.WFSyncQuestPanelLog
  assert(panel and panel.shown, "Panel nicht sichtbar")
  has(panel.text.text, "im Questlog")
  lois.env.QuestLogFrame:Hide()
  eq(panel.shown, false, "Panel versteckt")
end)

test("Panel am Quest-Dialog", function()
  lois.world.npcQuest = 500
  lois.env.QuestFrame:Show()
  lois:fire("QUEST_DETAIL")
  has(lois.env.WFSyncQuestPanelNPC.text.text, "erledigt")
  lois:fire("QUEST_FINISHED")
  eq(lois.env.WFSyncQuestPanelNPC.shown, false)
end)

test("Levelaufstieg und XP kommen nach Entprellung an", function()
  mf.world.level, mf.world.xp, mf.world.xpMax = 23, 500, 9800
  mf:fire("PLAYER_LEVEL_UP", 23)
  mf:fire("PLAYER_XP_UPDATE", "player")
  bus:advance(12)
  local peer = lois.env.WFSync_DB.peers["Mf-Forever"]
  eq(peer.level, 23, "level")
  eq(peer.xp, 500, "xp")
  eq(mfNS.session.levelTo, 23, "session levelTo")
  assert(mfNS.session.xpGained >= 6000, "xpGained " .. mfNS.session.xpGained)
end)

test("Quest annehmen (Classic-Argumente) wird geloggt", function()
  table.insert(lois.world.questLog, { title = "Kodo-Knochen", level = 21, id = 777 })
  lois:fire("QUEST_ACCEPTED", 3, 777)
  local evt = loisNS.char.events[#loisNS.char.events]
  eq(evt.type, "quest_accept")
  eq(evt.id, 777)
  eq(evt.title, "Kodo-Knochen")
  assert(loisNS.char.log[777].accepted, "accepted-Zeit")
end)

test("Quest abbrechen wird erkannt", function()
  lois:fire("QUEST_REMOVED", 777)
  table.remove(lois.world.questLog)
  bus:advance(2)
  local evt = loisNS.char.events[#loisNS.char.events]
  eq(evt.type, "quest_abandon")
  eq(loisNS.char.log[777], nil)
end)

test("Tod mit Verursacher aus dem Kampflog", function()
  lois.world.cleu = { 0, "SWING_DAMAGE", false, "Creature-1", "Kolkar-Klinge", 0, 0, "Player-1-Lois" }
  lois:fire("COMBAT_LOG_EVENT_UNFILTERED")
  lois:fire("PLAYER_DEAD")
  local evt = loisNS.char.events[#loisNS.char.events]
  eq(evt.type, "death")
  eq(evt.killer, "Kolkar-Klinge")
  eq(loisNS.session.deaths, 1)
end)

test("Dungeon betreten und verlassen", function()
  lois.world.instanceType, lois.world.instanceName = "party", "Höhlen des Wehklagens"
  lois.world.zone = "Höhlen des Wehklagens"
  lois:fire("ZONE_CHANGED_NEW_AREA")
  local n = #loisNS.char.events
  eq(loisNS.char.events[n - 1].type, "dungeon_enter")
  eq(loisNS.char.events[n - 1].name, "Höhlen des Wehklagens")
  eq(loisNS.char.events[n].type, "zone")
  lois.world.instanceType, lois.world.zone = nil, "Brachland"
  lois:fire("ZONE_CHANGED_NEW_AREA")
  eq(loisNS.char.events[#loisNS.char.events - 1].type, "dungeon_leave")
end)

test("/wf-Fenster listet Mitspieler", function()
  lois:slash("")
  local w = lois.env.WFSyncWindow
  assert(w and w.shown, "Fenster nicht offen")
  has(w.rows[1][1].text, "mf")
  has(w.rows[1][1].text, "Lvl 23")
  has(w.rows[1][2].text, "online")
end)

test("/wf quest und /wf status", function()
  lois.chat = {}
  lois:slash("quest 500")
  has(table.concat(lois.chat, "\n"), "mf")
  lois:slash("status")
  has(table.concat(lois.chat, "\n"), "Lois-Forever")
end)

test("Ereignis-Ringpuffer ist begrenzt", function()
  local real = loisNS.char.events
  loisNS.char.events = {}
  for i = 1, 600 do loisNS.AddEvent({ type = "test", i = i }) end
  eq(#loisNS.char.events, 500)
  eq(loisNS.char.events[500].i, 600)
  loisNS.char.events = real
end)

local savedText
test("Logout: SavedVariables sind serialisierbar und Schema v1", function()
  lois:fire("PLAYER_LOGOUT")
  savedText = mock.SerializeSV("WFSync_DB", lois.env.WFSync_DB)
  local env = {}
  local chunk = assert(loadstring(savedText))
  setfenv(chunk, env)
  chunk()
  local db = env.WFSync_DB
  eq(db.schema, 1)
  local c = db.chars["Lois-Forever"]
  assert(c, "char fehlt")
  eq(c.level, 20)
  assert(c.updated and c.sessions[1].stop, "updated/stop")
  assert(type(c.events) == "table" and #c.events > 0)
end)

test("Login-Hinweis zeigt Fortschritt seit dem letzten Mal", function()
  local db = lois.env.WFSync_DB
  db.seen.mf = { level = 20, updated = 1 }
  local lines = loisNS.LoginDigest()
  eq(#lines, 1)
  has(lines[1], "mf: Level 20 → 23")
  eq(#loisNS.LoginDigest(), 0, "zweiter Aufruf ohne Neues")
end)

-- Beispiel-Datei für den Companion schreiben
os.execute("mkdir -p tests/fixtures/SavedVariables")
local f = assert(io.open("tests/fixtures/SavedVariables/WFSync.lua", "w"))
f:write(savedText or "")
f:close()

print(string.format("\n%d ok, %d fehlgeschlagen", passed, failed))
os.exit(failed == 0 and 0 or 1)
