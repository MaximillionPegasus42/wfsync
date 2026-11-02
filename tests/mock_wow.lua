-- Minimale WoW-API-Attrappe, um WFSync ohne Spiel zu testen.
-- Mehrere "Clients" teilen sich eine Uhr und einen Nachrichten-Bus (Addon-Messages).
local M = {}

local Bus = {}
Bus.__index = Bus

function M.NewBus()
  return setmetatable({ clock = 1793000000, clients = {}, sent = {} }, Bus)
end

function Bus:advance(seconds, step)
  step = step or 0.05
  local target = self.clock + seconds
  while self.clock < target do
    self.clock = self.clock + step
    for _, client in ipairs(self.clients) do client:tick(step) end
  end
end

function Bus:deliver(from, prefix, text, channel, target)
  assert(#text <= 255, "Addon-Message zu lang: " .. #text)
  assert(not text:find("\0", 1, true), "Nullbyte in Addon-Message")
  table.insert(self.sent, { from = from.name, text = text, channel = channel, target = target })
  for _, c in ipairs(self.clients) do
    if c ~= from and c.prefixes[prefix] then
      local ok = false
      if channel == "PARTY" or channel == "RAID" then
        ok = from.world.group ~= nil and c.world.group == from.world.group
      elseif channel == "GUILD" then
        ok = from.world.guild ~= nil and c.world.guild == from.world.guild
      elseif channel == "WHISPER" then
        ok = target == c.name or target == c.name .. "-" .. c.world.realm
      end
      if ok then
        c:fire("CHAT_MSG_ADDON", prefix, text, channel, from.name .. "-" .. from.world.realm)
      end
    end
  end
end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------
local function noop() end

local function newFontString()
  local fs = { text = "" }
  function fs:SetText(t) self.text = t or "" end
  function fs:GetText() return self.text end
  function fs:GetStringHeight() return 12 end
  return setmetatable(fs, { __index = function() return noop end })
end

local function newFrame(client, name)
  local f = { events = {}, scripts = {}, shown = true, name = name, hooks = {} }
  function f:RegisterEvent(e) self.events[e] = true end
  function f:UnregisterEvent(e) self.events[e] = nil end
  function f:SetScript(k, fn) self.scripts[k] = fn end
  function f:GetScript(k) return self.scripts[k] end
  function f:HookScript(k, fn)
    self.hooks[k] = self.hooks[k] or {}
    table.insert(self.hooks[k], fn)
  end
  function f:Show()
    local was = self.shown
    self.shown = true
    if not was then
      for _, h in ipairs(self.hooks.OnShow or {}) do h(self) end
    end
  end
  function f:Hide()
    local was = self.shown
    self.shown = false
    if was then
      for _, h in ipairs(self.hooks.OnHide or {}) do h(self) end
    end
  end
  function f:IsShown() return self.shown end
  function f:CreateFontString() return newFontString() end
  f.lines = {}
  function f:AddLine(t) table.insert(self.lines, t) end
  function f:SetHyperlink(link)
    self.lines = {}
    for _, h in ipairs(self.hooks.SetHyperlink or {}) do h(self, link) end
  end
  setmetatable(f, { __index = function() return noop end })
  table.insert(client.frames, f)
  if name then client.env[name] = f end
  return f
end

---------------------------------------------------------------------------
-- Client
---------------------------------------------------------------------------
local Client = {}
Client.__index = Client

function Client:fire(event, ...)
  for _, f in ipairs(self.frames) do
    if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
  end
end

function Client:tick(dt)
  local now = self.bus.clock
  local due = {}
  for i = #self.timers, 1, -1 do
    if self.timers[i].at <= now then
      table.insert(due, 1, table.remove(self.timers, i))
    end
  end
  for _, t in ipairs(due) do t.fn() end
  for _, f in ipairs(self.frames) do
    if f.shown and f.scripts.OnUpdate then f.scripts.OnUpdate(f, dt) end
  end
end

function Client:slash(msg)
  self.env.SlashCmdList.WFSYNC(msg)
end

function M.NewClient(bus, name, world)
  local c = setmetatable({ bus = bus, name = name, frames = {}, timers = {}, prefixes = {}, chat = {} }, Client)
  world.realm = world.realm or "Forever"
  world.completed = world.completed or {}
  world.questLog = world.questLog or {}
  world.selected = world.selected or 0
  c.world = world
  table.insert(bus.clients, c)

  local env = {}
  c.env = env
  for _, k in ipairs({
    "string", "table", "math", "pairs", "ipairs", "select", "type", "tostring", "tonumber",
    "pcall", "error", "assert", "next", "setmetatable", "getmetatable", "unpack", "rawget", "rawset",
  }) do env[k] = _G[k] end
  env.print = function(...) table.insert(c.chat, table.concat({ ... }, " ")) end
  env.geterrorhandler = function() return function(err) error(err, 0) end end
  env.tinsert = table.insert
  env.time = function() return math.floor(bus.clock) end
  env.GetTime = function() return bus.clock end
  env.UISpecialFrames = {}
  env.SlashCmdList = {}
  env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, t) table.insert(c.chat, t) end }

  env.CreateFrame = function(_, frameName) return newFrame(c, frameName) end
  env.UIParent = newFrame(c, "UIParent")
  env.GameTooltip = newFrame(c, "GameTooltip")
  env.ItemRefTooltip = newFrame(c, "ItemRefTooltip")
  env.QuestLogFrame = newFrame(c, "QuestLogFrame")
  env.QuestLogFrame.shown = false
  env.QuestFrame = newFrame(c, "QuestFrame")
  env.QuestFrame.shown = false
  env.hooksecurefunc = function(a, b, cfn)
    if type(a) == "table" then
      a.hooks[b] = a.hooks[b] or {}
      table.insert(a.hooks[b], cfn)
    else
      local orig = env[a]
      env[a] = function(...)
        local r = { orig(...) }
        b(...)
        return unpack(r)
      end
    end
  end

  env.C_Timer = {
    After = function(d, fn) table.insert(c.timers, { at = bus.clock + d, fn = fn }) end,
  }
  env.C_ChatInfo = {
    RegisterAddonMessagePrefix = function(p) c.prefixes[p] = true end,
    SendAddonMessage = function(p, text, channel, target) bus:deliver(c, p, text, channel, target) end,
  }
  env.C_Map = {
    GetBestMapForUnit = function() return world.mapID end,
    GetPlayerMapPosition = function()
      if not world.x then return nil end
      return { GetXY = function() return world.x, world.y end }
    end,
  }
  env.C_QuestLog = {}
  env.GetQuestsCompleted = function()
    local t = {}
    for id in pairs(world.completed) do t[id] = true end
    return t
  end
  env.GetNumQuestLogEntries = function() return #world.questLog, #world.questLog end
  env.GetQuestLogTitle = function(i)
    local q = world.questLog[i]
    if not q then return nil end
    return q.title, q.level, nil, q.isHeader, q.isCollapsed, q.isComplete, nil, q.id or 0
  end
  env.GetQuestLogSelection = function() return world.selected end
  env.QuestLog_SetSelection = function(i) world.selected = i end
  env.GetQuestID = function() return world.npcQuest or 0 end

  env.UnitName = function() return name end
  env.UnitGUID = function() return "Player-1-" .. name end
  env.UnitLevel = function() return world.level end
  env.UnitXP = function() return world.xp end
  env.UnitXPMax = function() return world.xpMax end
  env.GetXPExhaustion = function() return world.rested end
  env.UnitClass = function() return "Krieger", world.class or "WARRIOR" end
  env.UnitRace = function() return "Orc", world.race or "Orc" end
  env.UnitFactionGroup = function() return world.faction or "Horde" end
  env.GetMoney = function() return world.money or 0 end
  env.IsInGuild = function() return world.guild ~= nil end
  env.GetGuildInfo = function() return world.guild end
  env.IsInGroup = function() return world.group ~= nil end
  env.IsInRaid = function() return false end
  env.GetRealZoneText = function() return world.zone end
  env.GetSubZoneText = function() return world.subzone or "" end
  env.GetNormalizedRealmName = function() return world.realm end
  env.GetRealmName = function() return world.realm end
  env.IsInInstance = function() return world.instanceType ~= nil, world.instanceType or "none" end
  env.GetInstanceInfo = function() return world.instanceName end
  env.CombatLogGetCurrentEventInfo = function() return unpack(world.cleu or {}) end

  return c
end

function M.LoadAddon(client, dir, files, remoteFile)
  local env = client.env
  if remoteFile then
    local chunk = assert(loadfile(remoteFile))
    setfenv(chunk, env)
    chunk()
  end
  local ns = {}
  for _, file in ipairs(files) do
    local chunk = assert(loadfile(dir .. "/" .. file))
    setfenv(chunk, env)
    chunk("WFSync", ns)
  end
  client.ns = ns
  return ns
end

function M.Login(client, savedVariables)
  client.env.WFSync_DB = savedVariables
  client:fire("ADDON_LOADED", "WFSync")
  client:fire("PLAYER_LOGIN")
  client:fire("PLAYER_ENTERING_WORLD", true, false)
end

---------------------------------------------------------------------------
-- SavedVariables wie WoW schreiben (zum Prüfen der Serialisierbarkeit)
---------------------------------------------------------------------------
local function serialize(v, indent, out, seen)
  local t = type(v)
  if t == "string" then
    out[#out + 1] = string.format("%q", v)
  elseif t == "number" or t == "boolean" then
    out[#out + 1] = tostring(v)
  elseif t == "nil" then
    out[#out + 1] = "nil"
  elseif t == "table" then
    assert(not seen[v], "Zyklus in SavedVariables")
    seen[v] = true
    out[#out + 1] = "{\n"
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
      if type(a) == type(b) then return a < b end
      return type(a) == "number"
    end)
    for _, k in ipairs(keys) do
      out[#out + 1] = indent .. "\t"
      if type(k) == "string" then
        out[#out + 1] = string.format("[%q] = ", k)
      else
        out[#out + 1] = "[" .. tostring(k) .. "] = "
      end
      serialize(v[k], indent .. "\t", out, seen)
      out[#out + 1] = ",\n"
    end
    out[#out + 1] = indent .. "}"
    seen[v] = nil
  else
    error("Nicht speicherbarer Typ in SavedVariables: " .. t)
  end
end

function M.SerializeSV(name, value)
  local out = { "\n", name, " = " }
  serialize(value, "", out, {})
  out[#out + 1] = "\n"
  return table.concat(out)
end

return M
