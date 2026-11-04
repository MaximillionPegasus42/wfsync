-- WFSync Core: Namespace, Event-Verteilung, Datenbank, Hilfsfunktionen.
local ADDON, ns = ...

ns.VERSION = "0.2.0"
ns.SCHEMA = 1
ns.MAX_EVENTS = 500
ns.MAX_SESSIONS = 100

---------------------------------------------------------------------------
-- WoW-Events
---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
ns.frame = frame
local handlers = {}

local function safeCall(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then
    local handler = geterrorhandler and geterrorhandler()
    if handler then handler(err) else print("WFSync error: " .. tostring(err)) end
  end
end

function ns.On(event, fn)
  local list = handlers[event]
  if not list then
    list = {}
    handlers[event] = list
    frame:RegisterEvent(event)
  end
  list[#list + 1] = fn
end

frame:SetScript("OnEvent", function(_, event, ...)
  local list = handlers[event]
  if not list then return end
  for i = 1, #list do safeCall(list[i], event, ...) end
end)

---------------------------------------------------------------------------
-- Interne Nachrichten (zwischen den Modulen)
---------------------------------------------------------------------------
local listeners = {}

function ns.Listen(message, fn)
  listeners[message] = listeners[message] or {}
  table.insert(listeners[message], fn)
end

function ns.Fire(message, ...)
  local list = listeners[message]
  if not list then return end
  for i = 1, #list do safeCall(list[i], ...) end
end

---------------------------------------------------------------------------
-- Hilfsfunktionen
---------------------------------------------------------------------------
function ns.Print(fmt, ...)
  local text = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ccffWFSync|r: " .. text)
end

function ns.Debug(fmt, ...)
  if ns.db and ns.db.settings and ns.db.settings.debug then
    ns.Print("|cff888888[debug]|r " .. fmt, ...)
  end
end

function ns.Realm()
  local realm = GetNormalizedRealmName and GetNormalizedRealmName()
  if not realm or realm == "" then
    realm = ((GetRealmName and GetRealmName()) or ""):gsub("[%s%-]", "")
  end
  return realm
end

function ns.PlayerKey()
  return (UnitName("player") or "?") .. "-" .. ns.Realm()
end

-- "Name" oder "Name-Realm" -> "Name-Realm"
function ns.NormalizeName(name)
  if not name or name == "" then return nil end
  if name:find("-", 1, true) then return name end
  return name .. "-" .. ns.Realm()
end

function ns.ShortName(charKey)
  return (charKey and charKey:match("^([^%-]+)")) or charKey
end

function ns.Split(text, sep, max)
  local out, start = {}, 1
  while true do
    if max and #out == max - 1 then
      out[#out + 1] = text:sub(start)
      break
    end
    local i = text:find(sep, start, true)
    if not i then
      out[#out + 1] = text:sub(start)
      break
    end
    out[#out + 1] = text:sub(start, i - 1)
    start = i + #sep
  end
  return out
end

function ns.Round(x, digits)
  local m = 10 ^ (digits or 0)
  return math.floor(x * m + 0.5) / m
end

function ns.Ago(ts)
  if not ts or ts == 0 then return "unbekannt" end
  local d = time() - ts
  if d < 90 then return "gerade eben" end
  if d < 3600 then return string.format("vor %d Min", math.floor(d / 60)) end
  if d < 86400 then return string.format("vor %d Std", math.floor(d / 3600)) end
  local days = math.floor(d / 86400)
  return days == 1 and "vor 1 Tag" or string.format("vor %d Tagen", days)
end

function ns.XPPercent(xp, xpMax)
  if not xp or not xpMax or xpMax <= 0 then return 0 end
  return math.floor(xp / xpMax * 100)
end

function ns.CountKeys(t)
  local n = 0
  if t then for _ in pairs(t) do n = n + 1 end end
  return n
end

---------------------------------------------------------------------------
-- Datenbank (SavedVariables WFSync_DB, Schema v1)
---------------------------------------------------------------------------
ns.On("ADDON_LOADED", function(_, name)
  if name ~= ADDON then return end
  WFSync_DB = type(WFSync_DB) == "table" and WFSync_DB or {}
  local db = WFSync_DB
  db.schema = ns.SCHEMA
  db.chars = db.chars or {}
  db.peers = db.peers or {}       -- live per Addon-Message gesehene Mitspieler
  db.seen = db.seen or {}         -- letzter bekannter Stand der Remote-Spieler (für Login-Hinweis)
  db.settings = db.settings or {}
  ns.db = db
  ns.Fire("DB_READY")
end)

ns.On("PLAYER_LOGIN", function()
  local key = ns.PlayerKey()
  local char = ns.db.chars[key] or {}
  ns.db.chars[key] = char
  char.completed = char.completed or {}
  char.log = char.log or {}
  char.events = char.events or {}
  char.sessions = char.sessions or {}
  ns.char = char
  ns.key = key
  ns.Fire("LOGIN", char)
end)
