-- WFSync Sync: Live-Austausch zwischen den Add-ons per Addon-Message (Party/Raid/Gilde/Whisper).
--
-- Protokoll v1, Felder getrennt durch "^", jede Nachricht <= 255 Byte:
--   H^1                                   Hallo: bitte schick mir deinen Status
--   S^1^lvl^xp^xpMax^mapID^x^y^updated^completedCount^zone^subzone^share
--   R^1^g?                                bitte schick mir deine abgeschlossenen Quests
--                                         (g = dein Status kam bei mir über die Gilde an)
--   C^1^seq^i^n^id,id,id                  Teil i von n der abgeschlossenen Quests
--   T^1^questID^title                     Quest gerade abgegeben
-- Weitergabe (Stand von Spielern, die gerade offline sind):
--   P^1^char^share^seenAt^lvl^xp^xpMax^mapID^x^y^updated^completedCount^zone^subzone
--   Q^1^char                              bitte schick mir die Quests von char
--   K^1^char^seq^i^n^id,id,id             Teil i von n der Quests von char
--
-- share: "g" = darf über die Gilde weitergegeben werden, "p" = nur Gruppe.
local ADDON, ns = ...

local PREFIX = "WFSync"
local PROTO = "1"
local MAX_LEN = 255
local SEND_INTERVAL = 0.2
local STATUS_DEBOUNCE = 10
local HELLO_COOLDOWN = 30
local REQUEST_COOLDOWN = 60
local RELAY_COOLDOWN = 30
local RELAY_MAX = 15                -- höchstens so viele Spieler pro Hallo weitergeben
local RELAY_MAX_AGE = 30 * 86400    -- ältere Stände nicht mehr weitergeben
local MAX_CLOCK_SKEW = 3600         -- Zeitstempel weiter in der Zukunft gelten als falsch

-- Anzahl Felder pro Nachrichtentyp (das letzte Feld bekommt den Rest)
local FIELDS = { H = 2, S = 13, R = 3, C = 6, T = 4, P = 15, Q = 3, K = 7 }

ns.PREFIX = PREFIX

local function clean(s, max)
  s = tostring(s or ""):gsub("[%^\r\n]", " ")
  if #s > max then
    s = s:sub(1, max):gsub("[\192-\255][\128-\191]*$", "")
  end
  return s
end

---------------------------------------------------------------------------
-- Einstellung: mit wem wird geteilt?  guild (Standard) | group | off
---------------------------------------------------------------------------
ns.SHARE_MODES = { guild = true, group = true, off = true }

function ns.ShareMode()
  local mode = ns.db and ns.db.settings and ns.db.settings.share
  return ns.SHARE_MODES[mode] and mode or "guild"
end

local function shareFlag()
  return ns.ShareMode() == "guild" and "g" or "p"
end

local function inMyGroup(sender)
  local name = sender
  local short, realm = sender:match("^([^%-]+)%-(.+)$")
  if short and realm == ns.Realm() then name = short end
  if UnitInParty and UnitInParty(name) then return true end
  if UnitInRaid and UnitInRaid(name) then return true end
  return false
end

-- Darf ich diesem Spieler meine Daten schicken?
local function mayShareWith(sender, channel)
  local mode = ns.ShareMode()
  if mode == "off" then return false end
  if mode == "group" then
    return channel == "PARTY" or channel == "RAID" or inMyGroup(sender)
  end
  return true
end

---------------------------------------------------------------------------
-- Senden mit Drosselung
--
-- WoW erlaubt pro Prefix ein Kontingent von ca. 10 Nachrichten, das sich mit etwa
-- 1 pro Sekunde auffüllt; darüber wird still verworfen. Wir bleiben mit einem
-- eigenen Kontingent (8, +1/s) darunter und stellen gedrosselte Nachrichten
-- wieder vorne an, statt sie zu verlieren.
---------------------------------------------------------------------------
local BURST = 8
local REFILL_PER_SEC = 1
local MAX_TRIES = 5

local RESULT = Enum and Enum.SendAddonMessageResult or {}
local THROTTLED = {
  [RESULT.AddonMessageThrottle or 3] = true,
  [RESULT.ChannelThrottle or 8] = true,
}

local queue = {}
local tokens, lastRefill = BURST, nil
local pump = CreateFrame("Frame")
pump:Hide()
local elapsed = 0

-- true = gesendet oder endgültig verworfen, false = später nochmal
local function trySend(msg)
  local result = C_ChatInfo.SendAddonMessage(PREFIX, msg.text, msg.channel, msg.target)
  local retry
  if result == false then
    retry = true                          -- ältere Clients: nur true/false
  elseif type(result) == "number" and result ~= (RESULT.Success or 0) then
    retry = THROTTLED[result] or false    -- z. B. nicht in Gruppe: nicht wiederholen
    if not retry then ns.Debug("Senden fehlgeschlagen (%d): %s", result, msg.text:sub(1, 20)) end
  end
  if not retry then return true end
  msg.tries = (msg.tries or 0) + 1
  if msg.tries >= MAX_TRIES then
    ns.Debug("Gedrosselt, verworfen: %s", msg.text:sub(1, 20))
    return true
  end
  return false
end

pump:SetScript("OnUpdate", function(self, dt)
  local now = GetTime()
  tokens = math.min(BURST, tokens + (now - (lastRefill or now)) * REFILL_PER_SEC)
  lastRefill = now
  elapsed = elapsed + dt
  if elapsed < SEND_INTERVAL or tokens < 1 then return end
  elapsed = 0
  local msg = queue[1]
  if msg then
    if trySend(msg) then
      table.remove(queue, 1)
      tokens = tokens - 1
    else
      tokens = 0 -- vom Client gedrosselt: Kontingent abwarten
    end
  end
  if #queue == 0 then self:Hide() end
end)

local function send(text, channel, target)
  if #text > MAX_LEN then
    ns.Debug("Nachricht zu lang (%d), verworfen", #text)
    return
  end
  queue[#queue + 1] = { text = text, channel = channel, target = target }
  pump:Show()
end
ns.SendQueueLength = function() return #queue end

-- withGuild=false: nur Gruppe/Raid
local function broadcastChannels(withGuild)
  local channels = {}
  if IsInRaid and IsInRaid() then
    channels[#channels + 1] = "RAID"
  elseif IsInGroup and IsInGroup() then
    channels[#channels + 1] = "PARTY"
  end
  if withGuild and IsInGuild and IsInGuild() then
    channels[#channels + 1] = "GUILD"
  end
  return channels
end

-- Eigene Daten: nur dorthin, wo die Einstellung es erlaubt
local function broadcast(text)
  local mode = ns.ShareMode()
  if mode == "off" then return end
  for _, channel in ipairs(broadcastChannels(mode == "guild")) do send(text, channel) end
end

---------------------------------------------------------------------------
-- Nachrichten bauen
---------------------------------------------------------------------------
local function statusMessage()
  local c = ns.char
  if not c then return nil end
  local x = c.pos and c.pos.x or ""
  local y = c.pos and c.pos.y or ""
  return table.concat({
    "S", PROTO,
    c.level or 0, c.xp or 0, c.xpMax or 0,
    c.mapID or "", x, y,
    c.updated or time(),
    ns.CountKeys(c.completed),
    clean(c.zone, 60), clean(c.subzone, 60),
    shareFlag(),
  }, "^")
end

local function relayMessage(charKey, p)
  local x = p.pos and p.pos.x or ""
  local y = p.pos and p.pos.y or ""
  return table.concat({
    "P", PROTO,
    clean(charKey, 48), "g", p.seenAt or p.lastSeen or "",
    p.level or 0, p.xp or 0, p.xpMax or 0,
    p.mapID or "", x, y,
    p.updated or 0,
    ns.CountKeys(p.completed),
    clean(p.zone, 40), clean(p.subzone, 40),
  }, "^")
end

-- Quest-IDs in Teile zerlegen, die mit dem Kopf zusammen in eine Nachricht passen
local function idChunks(set, budget)
  local ids = {}
  for id in pairs(set or {}) do ids[#ids + 1] = tonumber(id) end
  table.sort(ids)
  local chunks, current, currentLen = {}, {}, 0
  for _, id in ipairs(ids) do
    local s = tostring(id)
    if currentLen + #s + 1 > budget then
      chunks[#chunks + 1] = table.concat(current, ",")
      current, currentLen = {}, 0
    end
    current[#current + 1] = s
    currentLen = currentLen + #s + 1
  end
  chunks[#chunks + 1] = table.concat(current, ",")
  return chunks
end

-- channel: "WHISPER" (an target) oder "GUILD" (an alle)
local function sendCompleted(channel, target)
  local c = ns.char
  if not c then return end
  local chunks = idChunks(c.completed, MAX_LEN - 40) -- Platz für "C^1^seq^i^n^"
  local seq = tostring(time() % 100000)
  for i, chunk in ipairs(chunks) do
    send(table.concat({ "C", PROTO, seq, i, #chunks, chunk }, "^"), channel, target)
  end
end

local function sendRelayedCompleted(target, charKey, set)
  local chunks = idChunks(set, MAX_LEN - 40 - #charKey) -- Platz für "K^1^char^seq^i^n^"
  local seq = tostring(time() % 100000)
  for i, chunk in ipairs(chunks) do
    send(table.concat({ "K", PROTO, charKey, seq, i, #chunks, chunk }, "^"), "WHISPER", target)
  end
end

-- Stand der Spieler weitergeben, die der Neue vielleicht noch nicht kennt
local function relayTo(target, targetKey)
  if ns.ShareMode() ~= "guild" then return end
  local now = time()
  local list = {}
  for charKey, p in pairs(ns.db.peers) do
    if charKey ~= targetKey and charKey ~= ns.key and p.share == "g"
      and p.updated and now - p.updated < RELAY_MAX_AGE then
      list[#list + 1] = { key = charKey, p = p }
    end
  end
  table.sort(list, function(a, b) return a.p.updated > b.p.updated end)
  for i = 1, math.min(#list, RELAY_MAX) do
    send(relayMessage(list[i].key, list[i].p), "WHISPER", target)
  end
  if #list > 0 then ns.Debug("%d Spieler an %s weitergegeben", math.min(#list, RELAY_MAX), target) end
end

---------------------------------------------------------------------------
-- Empfangen
---------------------------------------------------------------------------
local lastHelloReply = {}
local lastRelay = {}
local lastRequest = {}
local lastRelayAnswer = {}
local incoming = {} -- [Absender|Spieler] = {seq, n, parts = {}}

local function assemble(key, seq, i, n, part)
  local t = incoming[key]
  if not t or t.seq ~= seq then
    t = { seq = seq, n = n, parts = {}, got = 0 }
    incoming[key] = t
  end
  if not t.parts[i] then
    t.parts[i] = part or ""
    t.got = t.got + 1
  end
  if t.got < t.n then return nil end
  local set = {}
  for k = 1, t.n do
    for id in (t.parts[k] or ""):gmatch("%d+") do set[tonumber(id)] = true end
  end
  incoming[key] = nil
  return set
end

local function cooledDown(store, key, seconds)
  local now = time()
  if store[key] and now - store[key] < seconds then return false end
  store[key] = now
  return true
end

local handlersByType = {}

handlersByType.H = function(sender, f, charKey, channel)
  if not mayShareWith(sender, channel) then return end
  if cooledDown(lastHelloReply, sender, 5) then
    local msg = statusMessage()
    if msg then send(msg, "WHISPER", sender) end
  end
  if channel == "GUILD" and cooledDown(lastRelay, sender, RELAY_COOLDOWN) then
    -- kleine Zufallsverzögerung, damit nicht alle Gildenmitglieder gleichzeitig antworten
    C_Timer.After(1 + math.random() * 2, function() relayTo(sender, charKey) end)
  end
end

handlersByType.S = function(sender, f, charKey, channel)
  local x, y = tonumber(f[7]), tonumber(f[8])
  local peer = ns.UpdatePeer(charKey, {
    level = tonumber(f[3]),
    xp = tonumber(f[4]),
    xpMax = tonumber(f[5]),
    mapID = tonumber(f[6]),
    pos = (x and y) and { x = x, y = y } or nil,
    updated = tonumber(f[9]),
    zone = f[11] ~= "" and f[11] or nil,
    subzone = f[12] ~= "" and f[12] or nil,
    share = (f[13] == "g" or f[13] == "p") and f[13] or nil,
    via = false,
  })
  local theirCount = tonumber(f[10]) or 0
  local known = peer.completed and ns.CountKeys(peer.completed) or -1
  if theirCount ~= known and cooledDown(lastRequest, charKey, REQUEST_COOLDOWN) then
    send("R^" .. PROTO .. (channel == "GUILD" and "^g" or ""), "WHISPER", sender)
  end
end

-- Anfragen kurz sammeln: Loggt jemand ein, fragen oft mehrere Gildenmitglieder
-- gleichzeitig. Dann einmal über die Gilde senden statt jedem einzeln.
local REQUEST_WINDOW = 3
local pendingRequests -- { [sender] = viaGuild }

local function flushRequests()
  local requests = pendingRequests
  pendingRequests = nil
  local guildCount = 0
  for _, viaGuild in pairs(requests) do if viaGuild then guildCount = guildCount + 1 end end
  local useGuild = guildCount >= 2 and ns.ShareMode() == "guild" and IsInGuild and IsInGuild()
  if useGuild then sendCompleted("GUILD") end
  for sender, viaGuild in pairs(requests) do
    if not (useGuild and viaGuild) then sendCompleted("WHISPER", sender) end
  end
end

handlersByType.R = function(sender, f, charKey, channel)
  if not mayShareWith(sender, channel) then return end
  if not pendingRequests then
    pendingRequests = {}
    C_Timer.After(REQUEST_WINDOW, flushRequests)
  end
  pendingRequests[sender] = pendingRequests[sender] or f[3] == "g"
end

handlersByType.C = function(sender, f, charKey)
  local seq, i, n = f[3], tonumber(f[4]), tonumber(f[5])
  if not (seq and i and n) then return end
  local set = assemble(charKey, seq, i, n, f[6])
  if set then
    ns.UpdatePeer(charKey, { completed = set })
    ns.Debug("%s: %d abgeschlossene Quests empfangen", charKey, ns.CountKeys(set))
  end
end

handlersByType.T = function(sender, f, charKey)
  local id = tonumber(f[3])
  if not id then return end
  local peer = ns.db.peers[charKey]
  local completed = peer and peer.completed or {}
  completed[id] = true
  ns.UpdatePeer(charKey, {
    completed = completed,
    lastQuest = { id = id, title = f[4] ~= "" and f[4] or nil, t = time() },
  })
end

-- Weitergegebener Stand: nur übernehmen, wenn er neuer ist als alles, was ich habe,
-- und der Spieler nicht gerade selbst online ist.
handlersByType.P = function(sender, f, charKey)
  local subject = ns.NormalizeName(f[3])
  local updated = tonumber(f[12])
  if not subject or subject == ns.key or subject == charKey then return end
  if f[4] ~= "g" or not updated or updated > time() + MAX_CLOCK_SKEW then return end
  local peer = ns.db.peers[subject]
  if peer and (ns.IsOnline(peer) or (peer.updated or 0) >= updated) then return end

  local x, y = tonumber(f[10]), tonumber(f[11])
  peer = ns.UpdatePeer(subject, {
    level = tonumber(f[6]),
    xp = tonumber(f[7]),
    xpMax = tonumber(f[8]),
    mapID = tonumber(f[9]),
    pos = (x and y) and { x = x, y = y } or nil,
    updated = updated,
    zone = f[14] ~= "" and f[14] or nil,
    subzone = f[15] ~= "" and f[15] or nil,
    share = "g",
    seenAt = tonumber(f[5]),
    via = charKey,
  }, true)
  ns.Debug("%s über %s: Lvl %s", subject, charKey, tostring(peer.level))

  local theirCount = tonumber(f[13]) or 0
  local known = peer.completed and ns.CountKeys(peer.completed) or -1
  if theirCount > 0 and theirCount ~= known and cooledDown(lastRequest, subject, REQUEST_COOLDOWN) then
    send("Q^" .. PROTO .. "^" .. subject, "WHISPER", sender)
  end
end

handlersByType.Q = function(sender, f, charKey)
  if ns.ShareMode() ~= "guild" then return end
  local subject = ns.NormalizeName(f[3])
  local peer = subject and ns.db.peers[subject]
  if not peer or peer.share ~= "g" or not peer.completed or subject == charKey then return end
  if cooledDown(lastRelayAnswer, sender .. "|" .. subject, REQUEST_COOLDOWN) then
    sendRelayedCompleted(sender, subject, peer.completed)
  end
end

handlersByType.K = function(sender, f, charKey)
  local subject = ns.NormalizeName(f[3])
  local seq, i, n = f[4], tonumber(f[5]), tonumber(f[6])
  if not (subject and seq and i and n) then return end
  -- nur von dem annehmen, dessen Stand ich gerade übernommen habe
  local peer = ns.db.peers[subject]
  if not peer or peer.via ~= charKey then return end
  local set = assemble(charKey .. "|" .. subject, seq, i, n, f[7])
  if set then
    -- abgeschlossene Quests addieren sich, nichts geht verloren
    for id in pairs(peer.completed or {}) do set[tonumber(id) or id] = true end
    ns.UpdatePeer(subject, { completed = set }, true)
    ns.Debug("%s: %d Quests über %s", subject, ns.CountKeys(set), charKey)
  end
end

ns.On("CHAT_MSG_ADDON", function(_, prefix, text, channel, sender)
  if prefix ~= PREFIX or not text or not sender then return end
  local charKey = ns.NormalizeName(sender)
  if not ns.char or charKey == ns.key then return end
  local kind = text:match("^(%u)%^")
  local handler = kind and handlersByType[kind]
  if not handler then return end
  local f = ns.Split(text, "^", FIELDS[kind])
  if f[2] ~= PROTO then return end
  handler(sender, f, charKey, channel)
end)

---------------------------------------------------------------------------
-- Auslöser
---------------------------------------------------------------------------
local lastHello = 0
function ns.SendHello(force)
  local now = time()
  if not force and now - lastHello < HELLO_COOLDOWN then return end
  lastHello = now
  -- Hallo geht immer an Gruppe und Gilde (verrät nichts außer „ich bin da“),
  -- der eigene Status nur dorthin, wo die Einstellung es erlaubt.
  for _, channel in ipairs(broadcastChannels(true)) do send("H^" .. PROTO, channel) end
  local msg = statusMessage()
  if msg then broadcast(msg) end
end

local statusPending = false
ns.Listen("SELF_CHANGED", function()
  if statusPending then return end
  statusPending = true
  C_Timer.After(STATUS_DEBOUNCE, function()
    statusPending = false
    local msg = statusMessage()
    if msg then broadcast(msg) end
  end)
end)

ns.Listen("QUEST_DONE", function(questID, title)
  broadcast(table.concat({ "T", PROTO, questID, clean(title, 120) }, "^"))
end)

ns.Listen("LOGIN", function()
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
  end
  C_Timer.After(5, function() ns.SendHello(true) end)
end)

-- Nach einem Dungeon (dort ist Addon-Kommunikation evtl. gesperrt) einmal nachziehen
ns.Listen("EVENT_ADDED", function(evt)
  if evt and evt.type == "dungeon_leave" then
    C_Timer.After(3, function() ns.SendHello(true) end)
  end
end)

local rosterPending = false
ns.On("GROUP_ROSTER_UPDATE", function()
  if rosterPending or not ns.char then return end
  rosterPending = true
  C_Timer.After(3, function()
    rosterPending = false
    ns.SendHello()
  end)
end)
