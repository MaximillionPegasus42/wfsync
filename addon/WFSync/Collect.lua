-- WFSync Collect: sammelt den eigenen Stand in WFSync_DB.chars["Name-Realm"].
local ADDON, ns = ...

local char        -- ns.char, gesetzt bei LOGIN
local session     -- aktuelle Session (liegt auch in char.sessions)
local titleCache = {}
local lastAttacker
local lastZoneLogged
local inDungeon

---------------------------------------------------------------------------
-- Lesen aus der WoW-API (defensiv: Classic- und Retail-Varianten)
---------------------------------------------------------------------------
local function readCompletedQuestIDs()
  if C_QuestLog and C_QuestLog.GetAllCompletedQuestIDs then
    local list = C_QuestLog.GetAllCompletedQuestIDs()
    if type(list) == "table" then
      local set = {}
      for _, id in ipairs(list) do set[id] = true end
      return set
    end
  end
  if GetQuestsCompleted then
    local completed = GetQuestsCompleted()
    if type(completed) == "table" then
      local set = {}
      for id, done in pairs(completed) do
        if done then set[id] = true end
      end
      return set
    end
  end
  return nil
end

-- Liefert entries[questID] = {title, level, ready} und ob die Liste vollständig ist
-- (eingeklappte Überschriften verstecken Quests in der Classic-API).
local function readQuestLog()
  local entries, complete = {}, true
  if GetQuestLogTitle and GetNumQuestLogEntries then
    local n = GetNumQuestLogEntries() or 0
    for i = 1, n do
      local title, level, _, isHeader, isCollapsed, isComplete, _, questID = GetQuestLogTitle(i)
      if isHeader then
        if isCollapsed then complete = false end
      elseif title and questID and questID > 0 then
        entries[questID] = {
          title = title,
          level = level,
          ready = (isComplete == 1 or isComplete == true) or nil,
        }
      end
    end
  elseif C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
    for i = 1, C_QuestLog.GetNumQuestLogEntries() or 0 do
      local info = C_QuestLog.GetInfo(i)
      if info then
        if info.isHeader then
          if info.isCollapsed then complete = false end
        elseif info.questID and info.questID > 0 then
          entries[info.questID] = { title = info.title, level = info.level }
        end
      end
    end
  end
  return entries, complete
end

local function questTitle(questID)
  if titleCache[questID] then return titleCache[questID] end
  if char and char.log[questID] then return char.log[questID].title end
  if C_QuestLog and C_QuestLog.GetTitleForQuestID then
    local t = C_QuestLog.GetTitleForQuestID(questID)
    if t and t ~= "" then return t end
  end
  if C_QuestLog and C_QuestLog.GetQuestInfo then
    local t = C_QuestLog.GetQuestInfo(questID)
    if type(t) == "string" and t ~= "" then return t end
  end
  return nil
end

local function readPosition()
  if not (C_Map and C_Map.GetBestMapForUnit) then return nil, nil end
  local mapID = C_Map.GetBestMapForUnit("player")
  if not mapID then return nil, nil end
  local pos = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(mapID, "player")
  if pos then
    local x, y = pos:GetXY()
    if x and y then
      return mapID, { x = ns.Round(x, 3), y = ns.Round(y, 3) }
    end
  end
  return mapID, nil
end

---------------------------------------------------------------------------
-- Schreiben
---------------------------------------------------------------------------
function ns.AddEvent(evt)
  if not char then return end
  evt.t = evt.t or time()
  local events = char.events
  events[#events + 1] = evt
  while #events > ns.MAX_EVENTS do table.remove(events, 1) end
  ns.Debug("Event %s", evt.type)
  ns.Fire("EVENT_ADDED", evt)
end

local function refreshLocation()
  if not char then return end
  char.zone = GetRealZoneText and GetRealZoneText() or char.zone
  local sub = GetSubZoneText and GetSubZoneText() or ""
  char.subzone = sub ~= "" and sub or nil
  local mapID, pos = readPosition()
  char.mapID = mapID or char.mapID
  char.pos = pos  -- in Instanzen nil
end

local function refreshBasics()
  if not char then return end
  local _, classFile = UnitClass("player")
  local _, raceFile = UnitRace("player")
  char.class = classFile
  char.race = raceFile
  char.faction = UnitFactionGroup("player")
  char.level = UnitLevel("player")
  char.xp = UnitXP("player")
  char.xpMax = UnitXPMax("player")
  char.rested = GetXPExhaustion and GetXPExhaustion() or nil
  char.money = GetMoney()
  char.guild = IsInGuild and IsInGuild() and GetGuildInfo("player") or nil
  refreshLocation()
  char.updated = time()
end

local function scanQuestLog()
  if not char then return end
  local entries, complete = readQuestLog()
  local log = complete and {} or char.log
  for id, entry in pairs(entries) do
    local old = char.log[id]
    entry.accepted = old and old.accepted or nil
    log[id] = entry
    titleCache[id] = entry.title
  end
  char.log = log
end

local scanPending = false
local function scheduleQuestScan()
  if scanPending then return end
  scanPending = true
  C_Timer.After(1, function()
    scanPending = false
    scanQuestLog()
  end)
end

local selfChangedPending = false
local function selfChanged()
  if selfChangedPending then return end
  selfChangedPending = true
  C_Timer.After(0.5, function()
    selfChangedPending = false
    if char then char.updated = time() end
    ns.Fire("SELF_CHANGED", char)
  end)
end
ns.SelfChanged = selfChanged

local function checkInstance()
  local inInstance, instanceType = IsInInstance()
  local isDungeon = inInstance and (instanceType == "party" or instanceType == "raid")
  if isDungeon and not inDungeon then
    local name = GetInstanceInfo()
    inDungeon = name or true
    ns.AddEvent({ type = "dungeon_enter", name = name, kind = instanceType })
  elseif not isDungeon and inDungeon then
    ns.AddEvent({ type = "dungeon_leave", name = type(inDungeon) == "string" and inDungeon or nil })
    inDungeon = nil
  end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
ns.Listen("LOGIN", function(c)
  char = c
  refreshBasics()
  local completed = readCompletedQuestIDs()
  if completed then char.completed = completed end
  scanQuestLog()

  session = {
    start = time(),
    levelFrom = char.level,
    levelTo = char.level,
    xpGained = 0,
    quests = 0,
    deaths = 0,
  }
  local sessions = char.sessions
  sessions[#sessions + 1] = session
  while #sessions > ns.MAX_SESSIONS do table.remove(sessions, 1) end
  ns.session = session

  lastZoneLogged = char.zone
  ns.AddEvent({ type = "login", zone = char.zone, level = char.level })
  selfChanged()
end)

ns.On("PLAYER_ENTERING_WORLD", function()
  if not char then return end
  refreshLocation()
  checkInstance()
end)

local function onZoneChanged(event)
  if not char then return end
  refreshLocation()
  if event == "ZONE_CHANGED_NEW_AREA" then
    checkInstance()
    if char.zone and char.zone ~= "" and char.zone ~= lastZoneLogged then
      lastZoneLogged = char.zone
      ns.AddEvent({ type = "zone", zone = char.zone })
    end
  end
  selfChanged()
end
ns.On("ZONE_CHANGED_NEW_AREA", onZoneChanged)
ns.On("ZONE_CHANGED", onZoneChanged)
ns.On("ZONE_CHANGED_INDOORS", onZoneChanged)

ns.On("PLAYER_XP_UPDATE", function()
  if not char then return end
  local xp, xpMax, level = UnitXP("player"), UnitXPMax("player"), UnitLevel("player")
  if session and char.xp then
    local gained
    if level == char.level then
      gained = xp - char.xp
    else
      gained = ((char.xpMax or 0) - char.xp) + xp
    end
    if gained > 0 then session.xpGained = session.xpGained + gained end
  end
  char.xp, char.xpMax = xp, xpMax
  char.rested = GetXPExhaustion and GetXPExhaustion() or nil
  selfChanged()
end)

ns.On("PLAYER_LEVEL_UP", function(_, level)
  if not char then return end
  -- XP-Rest der alten Stufe noch der Session gutschreiben
  if session and char.xp and char.xpMax then
    session.xpGained = session.xpGained + math.max(0, char.xpMax - char.xp)
    char.xp = 0
  end
  char.level = level
  if session then session.levelTo = level end
  ns.AddEvent({ type = "levelup", level = level, zone = char.zone })
  selfChanged()
end)

ns.On("PLAYER_MONEY", function()
  if char then char.money = GetMoney() end
end)

ns.On("QUEST_LOG_UPDATE", scheduleQuestScan)

ns.On("QUEST_ACCEPTED", function(_, a, b)
  if not char then return end
  -- Classic: (questLogIndex, questID), Retail: (questID)
  local questID = b or a
  local title
  if b and GetQuestLogTitle then title = GetQuestLogTitle(a) end
  title = title or questTitle(questID)
  if title then titleCache[questID] = title end
  char.log[questID] = char.log[questID] or {}
  char.log[questID].title = title or char.log[questID].title
  char.log[questID].accepted = time()
  ns.AddEvent({ type = "quest_accept", id = questID, title = title, zone = char.zone })
  scheduleQuestScan()
end)

ns.On("QUEST_TURNED_IN", function(_, questID, xpReward)
  if not char then return end
  local title = questTitle(questID)
  char.completed[questID] = true
  char.log[questID] = nil
  if session then session.quests = session.quests + 1 end
  ns.AddEvent({ type = "quest_turnin", id = questID, title = title, zone = char.zone, xp = xpReward })
  ns.Fire("QUEST_DONE", questID, title)
  selfChanged()
end)

ns.On("QUEST_REMOVED", function(_, questID)
  if not char or not questID then return end
  local entry = char.log[questID]
  -- QUEST_REMOVED kommt auch beim Abgeben; kurz warten, ob QUEST_TURNED_IN folgt
  C_Timer.After(1, function()
    if char.completed[questID] then return end
    if char.log[questID] == entry then char.log[questID] = nil end
    ns.AddEvent({ type = "quest_abandon", id = questID, title = entry and entry.title or questTitle(questID) })
  end)
end)

ns.On("COMBAT_LOG_EVENT_UNFILTERED", function()
  if not CombatLogGetCurrentEventInfo then return end
  local _, sub, _, _, sourceName, _, _, destGUID = CombatLogGetCurrentEventInfo()
  if destGUID == UnitGUID("player") and sourceName and sub and sub:find("_DAMAGE$") then
    lastAttacker = sourceName
  end
end)

ns.On("PLAYER_DEAD", function()
  if not char then return end
  refreshLocation()
  if session then session.deaths = session.deaths + 1 end
  ns.AddEvent({
    type = "death",
    zone = char.zone,
    subzone = char.subzone,
    level = char.level,
    killer = lastAttacker,
  })
  lastAttacker = nil
  selfChanged()
end)

ns.On("PLAYER_LOGOUT", function()
  if not char then return end
  refreshBasics()
  if session then
    session.stop = time()
    session.levelTo = char.level
  end
end)
