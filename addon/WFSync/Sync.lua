-- WFSync Sync: Live-Austausch zwischen den Add-ons per Addon-Message (Party/Raid/Gilde/Whisper).
--
-- Protokoll v1, Felder getrennt durch "^", jede Nachricht <= 255 Byte:
--   H^1                                   Hallo: bitte schick mir deinen Status
--   S^1^lvl^xp^xpMax^mapID^x^y^updated^completedCount^zone^subzone
--   R^1                                   bitte schick mir deine abgeschlossenen Quests
--   C^1^seq^i^n^id,id,id                  Teil i von n der abgeschlossenen Quests
--   T^1^questID^title                     Quest gerade abgegeben
local ADDON, ns = ...

local PREFIX = "WFSync"
local PROTO = "1"
local MAX_LEN = 255
local SEND_INTERVAL = 0.2
local STATUS_DEBOUNCE = 10
local HELLO_COOLDOWN = 30
local REQUEST_COOLDOWN = 60

ns.PREFIX = PREFIX

local function clean(s, max)
  s = tostring(s or ""):gsub("[%^\r\n]", " ")
  if #s > max then
    s = s:sub(1, max):gsub("[\192-\255][\128-\191]*$", "")
  end
  return s
end

---------------------------------------------------------------------------
-- Senden mit Drosselung
---------------------------------------------------------------------------
local queue = {}
local pump = CreateFrame("Frame")
pump:Hide()
local elapsed = 0
pump:SetScript("OnUpdate", function(self, dt)
  elapsed = elapsed + dt
  if elapsed < SEND_INTERVAL then return end
  elapsed = 0
  local msg = table.remove(queue, 1)
  if msg then
    C_ChatInfo.SendAddonMessage(PREFIX, msg.text, msg.channel, msg.target)
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

local function broadcastChannels()
  local channels = {}
  if IsInRaid and IsInRaid() then
    channels[#channels + 1] = "RAID"
  elseif IsInGroup and IsInGroup() then
    channels[#channels + 1] = "PARTY"
  end
  if IsInGuild and IsInGuild() then
    channels[#channels + 1] = "GUILD"
  end
  return channels
end

local function broadcast(text)
  for _, channel in ipairs(broadcastChannels()) do send(text, channel) end
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
  }, "^")
end

local function sendCompleted(target)
  local c = ns.char
  if not c then return end
  local ids = {}
  for id in pairs(c.completed) do ids[#ids + 1] = tonumber(id) end
  table.sort(ids)

  local chunks, current = {}, {}
  local currentLen = 0
  local budget = MAX_LEN - 40 -- Platz für "C^1^seq^i^n^"
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

  local seq = tostring(time() % 100000)
  for i, chunk in ipairs(chunks) do
    send(table.concat({ "C", PROTO, seq, i, #chunks, chunk }, "^"), "WHISPER", target)
  end
end

---------------------------------------------------------------------------
-- Empfangen
---------------------------------------------------------------------------
local lastHelloReply = {}
local lastRequest = {}
local incoming = {} -- [charKey] = {seq, n, parts = {}}

local handlersByType = {}

handlersByType.H = function(sender)
  local now = time()
  if lastHelloReply[sender] and now - lastHelloReply[sender] < 5 then return end
  lastHelloReply[sender] = now
  local msg = statusMessage()
  if msg then send(msg, "WHISPER", sender) end
end

handlersByType.S = function(sender, f, charKey)
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
  })
  local theirCount = tonumber(f[10]) or 0
  local known = peer.completed and ns.CountKeys(peer.completed) or -1
  if theirCount ~= known then
    local now = time()
    if not lastRequest[charKey] or now - lastRequest[charKey] >= REQUEST_COOLDOWN then
      lastRequest[charKey] = now
      send("R^" .. PROTO, "WHISPER", sender)
    end
  end
end

handlersByType.R = function(sender)
  sendCompleted(sender)
end

handlersByType.C = function(sender, f, charKey)
  local seq, i, n = f[3], tonumber(f[4]), tonumber(f[5])
  if not (seq and i and n) then return end
  local t = incoming[charKey]
  if not t or t.seq ~= seq then
    t = { seq = seq, n = n, parts = {}, got = 0 }
    incoming[charKey] = t
  end
  if not t.parts[i] then
    t.parts[i] = f[6] or ""
    t.got = t.got + 1
  end
  if t.got >= t.n then
    local set = {}
    for k = 1, t.n do
      for id in (t.parts[k] or ""):gmatch("%d+") do set[tonumber(id)] = true end
    end
    incoming[charKey] = nil
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

ns.On("CHAT_MSG_ADDON", function(_, prefix, text, channel, sender)
  if prefix ~= PREFIX or not text or not sender then return end
  local charKey = ns.NormalizeName(sender)
  if not ns.char or charKey == ns.key then return end
  local f = ns.Split(text, "^", 12)
  if f[2] ~= PROTO then return end
  local handler = handlersByType[f[1]]
  if handler then handler(sender, f, charKey) end
end)

---------------------------------------------------------------------------
-- Auslöser
---------------------------------------------------------------------------
local lastHello = 0
function ns.SendHello(force)
  local now = time()
  if not force and now - lastHello < HELLO_COOLDOWN then return end
  lastHello = now
  broadcast("H^" .. PROTO)
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

local rosterPending = false
ns.On("GROUP_ROSTER_UPDATE", function()
  if rosterPending or not ns.char then return end
  rosterPending = true
  C_Timer.After(3, function()
    rosterPending = false
    ns.SendHello()
  end)
end)
