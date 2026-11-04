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

---------------------------------------------------------------------------
-- Weitergabe über die Gilde: Anna ist offline, Bert hat sie gesehen, Carla loggt ein
---------------------------------------------------------------------------
local gbus = mock.NewBus()
local anna = mock.NewClient(gbus, "Anna", {
  level = 31, xp = 100, xpMax = 20000, zone = "Desolace", subzone = "Ghost Walker Post",
  mapID = 1443, x = 0.5, y = 0.6, guild = "Gilde",
  completed = manyCompleted(80, 2000), -- erzwingt mehrere K-Teile
})
local bert = mock.NewClient(gbus, "Bert", { level = 25, xp = 0, xpMax = 10000, zone = "Steinkrallen", guild = "Gilde", group = "g2" })
local ella = mock.NewClient(gbus, "Ella", { level = 26, xp = 0, xpMax = 10000, zone = "Steinkrallen", guild = "Gilde", group = "g2" })
local carla = mock.NewClient(gbus, "Carla", { level = 12, xp = 0, xpMax = 3000, zone = "Mulgore", guild = "Gilde" })
local annaNS = mock.LoadAddon(anna, ADDON_DIR, FILES)
local bertNS = mock.LoadAddon(bert, ADDON_DIR, FILES)
mock.LoadAddon(ella, ADDON_DIR, FILES)
local carlaNS = mock.LoadAddon(carla, ADDON_DIR, FILES)
mock.Login(anna, nil)
mock.Login(bert, nil)
mock.Login(ella, { settings = { share = "group" } })
gbus:advance(20)

test("Teilen nur mit Gruppe: Gildenmitglied außerhalb der Gruppe sieht nichts", function()
  local bertPeers = bert.env.WFSync_DB.peers
  eq(bertPeers["Ella-Forever"].share, "p", "Ella bei Bert (Gruppe)")
  eq(bertPeers["Anna-Forever"].share, "g", "Anna bei Bert")
  eq(anna.env.WFSync_DB.peers["Ella-Forever"], nil, "Ella bei Anna")
  for _, m in ipairs(gbus.sent) do
    if m.from == "Ella" and m.channel == "GUILD" then eq(m.text, "H^1", "Ella auf GUILD") end
  end
end)

anna.offline, ella.offline = true, true
gbus:advance(400)
mock.Login(carla, nil)
gbus:advance(20)

test("Weitergabe: Carla bekommt Annas Stand und Quests über Bert", function()
  local peer = carla.env.WFSync_DB.peers["Anna-Forever"]
  assert(peer, "Anna fehlt bei Carla")
  eq(peer.level, 31, "level")
  eq(peer.zone, "Desolace", "zone")
  eq(peer.via, "Bert-Forever", "via")
  eq(carlaNS.CountKeys(peer.completed), 80, "completed")
  has(table.concat(carlaNS.QuestStatusLines(2042), "\n"), "Anna")
  has(table.concat(carlaNS.QuestStatusLines(2042), "\n"), "erledigt")
  local k = 0
  for _, m in ipairs(gbus.sent) do
    assert(#m.text <= 255)
    if m.text:sub(1, 2) == "K^" then k = k + 1 end
  end
  assert(k >= 2, "erwartet mehrere K-Teile, bekommen " .. k)
end)

test("Weitergabe: nur Gilden-Teiler, Anzeige mit „über Bert“", function()
  eq(carla.env.WFSync_DB.peers["Ella-Forever"], nil, "Ella (nur Gruppe) darf nicht weitergegeben werden")
  local annaPerson
  for _, p in ipairs(carlaNS.People()) do if p.char == "Anna-Forever" then annaPerson = p end end
  assert(annaPerson, "Anna nicht in People()")
  eq(annaPerson.online, false, "online")
  local _, line2 = carlaNS.PersonLines(annaPerson)
  has(line2, "über Bert")
end)

local function inject(client, from, text)
  client:fire("CHAT_MSG_ADDON", "WFSync", text, "WHISPER", from)
end

test("Weitergabe: veraltete, eigene und fremde Daten werden abgelehnt", function()
  local peers = carla.env.WFSync_DB.peers
  inject(carla, "Mallory-Forever", "P^1^Anna-Forever^g^1^60^0^1^1^^^1^0^Alt^")
  eq(peers["Anna-Forever"].level, 31, "älterer Stand überschreibt nicht")
  inject(carla, "Mallory-Forever", "P^1^Carla-Forever^g^1^60^0^1^1^^^" .. (gbus.clock + 10) .. "^0^X^")
  eq(peers["Carla-Forever"], nil, "Stand über mich selbst")
  inject(carla, "Mallory-Forever", "P^1^Zoe-Forever^p^1^60^0^1^1^^^" .. (gbus.clock - 10) .. "^0^X^")
  eq(peers["Zoe-Forever"], nil, "nur-Gruppe-Stand")
  inject(carla, "Mallory-Forever", "K^1^Anna-Forever^1^1^1^1,2,3")
  eq(carlaNS.CountKeys(peers["Anna-Forever"].completed), 80, "Quests von jemand anderem als via")
end)

test("Weitergabe: K-Teile addieren sich zu bekannten Quests", function()
  inject(carla, "Bert-Forever", "K^1^Anna-Forever^777^1^1^9001")
  local done = carla.env.WFSync_DB.peers["Anna-Forever"].completed
  eq(carlaNS.CountKeys(done), 81, "80 + 1")
  eq(done[2042], true, "alte Quest noch da")
  eq(done[9001], true, "neue Quest")
end)

test("Direkter Kontakt ersetzt weitergegebenen Stand", function()
  anna.offline = false
  annaNS.SendHello(true)
  gbus:advance(5)
  local peer = carla.env.WFSync_DB.peers["Anna-Forever"]
  eq(peer.via, false, "via gelöscht")
  eq(carlaNS.IsOnline(peer), true, "online")
end)

test("/wf share off: nur noch Hallo, keine eigenen Daten", function()
  carla:slash("share aus")
  eq(carla.env.WFSync_DB.settings.share, "off")
  local before = #gbus.sent
  carlaNS.SendHello(true)
  inject(carla, "Bert-Forever", "R^1")
  gbus:advance(10)
  for i = before + 1, #gbus.sent do
    local m = gbus.sent[i]
    if m.from == "Carla" then eq(m.text, "H^1", "Carla sendet") end
  end
  carla:slash("share guild")
  eq(carlaNS.ShareMode(), "guild")
end)

test("/wf-Fenster blättert bei mehr als 10 Mitspielern", function()
  for i = 1, 14 do
    carlaNS.UpdatePeer(string.format("Gast%02d-Forever", i), { level = 10 + i, updated = gbus.clock - i }, true)
  end
  carla:slash("")
  local w = carla.env.WFSyncWindow
  assert(w and w.shown, "Fenster nicht offen")
  has(w.footer.text, "16 Mitspieler")
  has(w.footer.text, "Mausrad")
  local first = w.rows[1][1].text
  w.scripts.OnMouseWheel(w, -1)
  assert(w.rows[1][1].text ~= first, "erste Zeile nach dem Blättern unverändert")
  for _ = 1, 20 do w.scripts.OnMouseWheel(w, -1) end
  eq(w.offset, 6, "Offset am Ende begrenzt")
  has(w.rows[10][1].text, "Lvl")
end)

test("Instanz-Hinweis im /wf-Fenster", function()
  carla.world.instanceType = "party"
  carlaNS.RefreshWindow()
  has(carla.env.WFSyncWindow.footer.text, "Instanzen")
  carla.world.instanceType = nil
  carlaNS.RefreshWindow()
  assert(not carla.env.WFSyncWindow.footer.text:find("Instanzen"), "Hinweis bleibt nach Instanz")
end)

test("Drosselung: 1500 Quests in vielen Teilen kommen vollständig an, ohne Client-Drossel", function()
  gbus:advance(10) -- offene Nachrichten der anderen erst abarbeiten
  local dora = mock.NewClient(gbus, "Dora", {
    level = 40, xp = 0, xpMax = 50000, zone = "Tanaris", guild = "Gilde",
    completed = manyCompleted(1500, 5000),
  })
  local doraNS = mock.LoadAddon(dora, ADDON_DIR, FILES)
  mock.Login(dora, nil)
  gbus:advance(90)
  local peer = carla.env.WFSync_DB.peers["Dora-Forever"]
  assert(peer and peer.completed, "Dora fehlt bei Carla")
  eq(carlaNS.CountKeys(peer.completed), 1500, "alle Quests")
  eq(dora.throttled or 0, 0, "eigene Drossel bleibt unter dem Client-Kontingent")
  eq(doraNS.SendQueueLength(), 0, "Queue leer")
  local chunks, guildChunks = 0, 0
  for _, m in ipairs(gbus.sent) do
    if m.from == "Dora" and m.text:sub(1, 2) == "C^" then
      chunks = chunks + 1
      if m.channel == "GUILD" then guildChunks = guildChunks + 1 end
    end
  end
  eq(chunks, guildChunks, "mehrere Anfragen gleichzeitig: einmal über die Gilde statt pro Person")
  assert(chunks >= 20 and chunks <= 45, "Anzahl C-Teile " .. chunks)
  eq(bert.env.WFSync_DB.peers["Dora-Forever"] and bertNS.CountKeys(bert.env.WFSync_DB.peers["Dora-Forever"].completed), 1500, "Bert auch")

  -- Client drosselt trotzdem (z. B. anderes Add-on hat das Kontingent verbraucht): nichts geht verloren
  dora.allowance, dora.allowanceAt = 0, gbus.clock
  dora.world.completed[9999] = true
  dora:fire("QUEST_TURNED_IN", 9999, 0, 0)
  gbus:advance(5)
  assert((dora.throttled or 0) > 0, "Client-Drossel nicht ausgelöst")
  eq(carla.env.WFSync_DB.peers["Dora-Forever"].completed[9999], true, "T-Nachricht nach Drossel angekommen")
end)

-- Beispiel-Datei für den Companion schreiben
os.execute("mkdir -p tests/fixtures/SavedVariables")
local f = assert(io.open("tests/fixtures/SavedVariables/WFSync.lua", "w"))
f:write(savedText or "")
f:close()

print(string.format("\n%d ok, %d fehlgeschlagen", passed, failed))
os.exit(failed == 0 and 0 or 1)
