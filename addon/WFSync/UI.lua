-- WFSync UI: Quest-Status der Mitspieler (Questlog, Quest-Dialog, Quest-Links), /wf-Fenster, Login-Hinweis.
local ADDON, ns = ...

local ICON_DONE = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t"
local ICON_ACTIVE = "|TInterface\\RaidFrame\\ReadyCheck-Waiting:0|t"
local ICON_OPEN = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:0|t"
local STATUS_TEXT = {
  done = ICON_DONE .. " %s |cff888888erledigt|r",
  active = ICON_ACTIVE .. " %s |cff888888im Questlog|r",
  open = ICON_OPEN .. " %s |cff888888offen|r",
}

function ns.QuestStatusLines(questID)
  local lines = {}
  if not questID or questID == 0 then return lines end
  for _, entry in ipairs(ns.QuestStatus(questID)) do
    lines[#lines + 1] = string.format(STATUS_TEXT[entry.status], entry.person.name)
  end
  return lines
end

---------------------------------------------------------------------------
-- Seitenpanel am Questlog / Quest-Dialog
---------------------------------------------------------------------------
local panels = {}

local function makePanel(key)
  local p = CreateFrame("Frame", "WFSyncQuestPanel" .. key, UIParent,
    BackdropTemplateMixin and "BackdropTemplate" or nil)
  p:SetSize(180, 40)
  p:SetFrameStrata("HIGH")
  if p.SetBackdrop then
    p:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    p:SetBackdropColor(0, 0, 0, 0.85)
  end
  p.title = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  p.title:SetPoint("TOPLEFT", 10, -9)
  p.title:SetText("Mitspieler")
  p.text = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  p.text:SetPoint("TOPLEFT", p.title, "BOTTOMLEFT", 0, -5)
  p.text:SetJustifyH("LEFT")
  p:Hide()
  return p
end

local function showPanel(key, anchor, questID, x, y)
  local p = panels[key] or makePanel(key)
  panels[key] = p
  local lines = ns.QuestStatusLines(questID)
  if not anchor or not anchor:IsShown() or #lines == 0 then
    p:Hide()
    return
  end
  p:ClearAllPoints()
  p:SetPoint("TOPLEFT", anchor, "TOPRIGHT", x or 0, y or 0)
  p.text:SetText(table.concat(lines, "\n"))
  p:SetHeight((p.text:GetStringHeight() or 12) + 30)
  p.questID = questID
  p:Show()
end

local function hidePanel(key)
  if panels[key] then panels[key]:Hide() end
end

-- Questlog (Classic: QuestLogFrame)
local function selectedLogQuestID()
  if not (GetQuestLogSelection and GetQuestLogTitle) then return nil end
  local index = GetQuestLogSelection()
  if not index or index == 0 then return nil end
  return select(8, GetQuestLogTitle(index))
end

local function updateQuestLogPanel()
  if QuestLogFrame and QuestLogFrame:IsShown() then
    showPanel("Log", QuestLogFrame, selectedLogQuestID(), -32, -12)
  else
    hidePanel("Log")
  end
end
ns.UpdateQuestLogPanel = updateQuestLogPanel

-- Quest-Dialog beim NPC (QuestFrame)
local function updateQuestFramePanel()
  if QuestFrame and QuestFrame:IsShown() and GetQuestID then
    showPanel("NPC", QuestFrame, GetQuestID(), -32, -12)
  else
    hidePanel("NPC")
  end
end

local function hookUI()
  if QuestLog_SetSelection then
    hooksecurefunc("QuestLog_SetSelection", updateQuestLogPanel)
  end
  if QuestLogFrame then
    QuestLogFrame:HookScript("OnShow", updateQuestLogPanel)
    QuestLogFrame:HookScript("OnHide", function() hidePanel("Log") end)
  end
  if QuestFrame then
    QuestFrame:HookScript("OnHide", function() hidePanel("NPC") end)
  end

  -- Quest-Links im Chat
  local function onHyperlink(tooltip, link)
    local questID = link and tonumber(link:match("quest:(%d+)"))
    if not questID then return end
    local lines = ns.QuestStatusLines(questID)
    if #lines == 0 then return end
    tooltip:AddLine(" ")
    tooltip:AddLine("Mitspieler:")
    for _, line in ipairs(lines) do tooltip:AddLine(line, 1, 1, 1) end
    tooltip:Show()
  end
  if GameTooltip then hooksecurefunc(GameTooltip, "SetHyperlink", onHyperlink) end
  if ItemRefTooltip then hooksecurefunc(ItemRefTooltip, "SetHyperlink", onHyperlink) end
end

ns.On("QUEST_DETAIL", updateQuestFramePanel)
ns.On("QUEST_PROGRESS", updateQuestFramePanel)
ns.On("QUEST_COMPLETE", updateQuestFramePanel)
ns.On("QUEST_FINISHED", function() hidePanel("NPC") end)
ns.Listen("PEERS_CHANGED", function()
  updateQuestLogPanel()
  if panels.NPC and panels.NPC:IsShown() then updateQuestFramePanel() end
end)

---------------------------------------------------------------------------
-- /wf-Fenster
---------------------------------------------------------------------------
local MAX_ROWS = 10
local window

local function personLines(p)
  local loc = p.zone or "?"
  if p.subzone and p.subzone ~= "" and p.subzone ~= p.zone then loc = loc .. ", " .. p.subzone end
  local line1 = string.format("|cffffd100%s|r  Lvl %s (%d%%)  ·  %s",
    p.name, tostring(p.level or "?"), ns.XPPercent(p.xp, p.xpMax), loc)
  local when = p.online and "|cff40ff40online|r" or ("|cff888888" .. ns.Ago(p.updated) .. "|r")
  local line2 = "   " .. when
  if p.lastQuest and p.lastQuest.title then
    line2 = line2 .. "|cff888888  ·  zuletzt: " .. p.lastQuest.title .. "|r"
  end
  return line1, line2
end
ns.PersonLines = personLines

local function createWindow()
  local ok, w = pcall(CreateFrame, "Frame", "WFSyncWindow", UIParent, "BasicFrameTemplateWithInset")
  if not ok or not w then
    w = CreateFrame("Frame", "WFSyncWindow", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  end
  w:SetSize(420, 70 + MAX_ROWS * 34)
  w:SetPoint("CENTER")
  w:SetFrameStrata("DIALOG")
  w:SetMovable(true)
  w:EnableMouse(true)
  w:RegisterForDrag("LeftButton")
  w:SetScript("OnDragStart", w.StartMoving)
  w:SetScript("OnDragStop", w.StopMovingOrSizing)
  tinsert(UISpecialFrames, "WFSyncWindow") -- ESC schließt

  w.title = w:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  w.title:SetPoint("TOP", 0, -6)
  w.title:SetText("WFSync – Mitspieler")

  w.rows = {}
  for i = 1, MAX_ROWS do
    local a = w:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    a:SetPoint("TOPLEFT", 16, -32 - (i - 1) * 34)
    a:SetJustifyH("LEFT")
    local b = w:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b:SetPoint("TOPLEFT", a, "BOTTOMLEFT", 0, -2)
    b:SetJustifyH("LEFT")
    w.rows[i] = { a, b }
  end
  w.empty = w:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  w.empty:SetPoint("CENTER")
  w.empty:SetText("Noch keine Mitspieler bekannt.\nGruppe/Gilde mit WFSync oder Companion-Daten nötig.")
  w:Hide()
  return w
end

function ns.RefreshWindow()
  if not window or not window:IsShown() then return end
  local people = ns.People()
  for i = 1, MAX_ROWS do
    local row, p = window.rows[i], people[i]
    if p then
      local l1, l2 = personLines(p)
      row[1]:SetText(l1)
      row[2]:SetText(l2)
    else
      row[1]:SetText("")
      row[2]:SetText("")
    end
  end
  if #people == 0 then window.empty:Show() else window.empty:Hide() end
end

function ns.ToggleWindow()
  window = window or createWindow()
  if window:IsShown() then
    window:Hide()
  else
    window:Show()
    ns.RefreshWindow()
  end
end

ns.Listen("PEERS_CHANGED", function() ns.RefreshWindow() end)

---------------------------------------------------------------------------
-- Hinweis beim Login: was haben die anderen seit dem letzten Mal gemacht?
---------------------------------------------------------------------------
function ns.LoginDigest()
  local seen = ns.db.seen
  local lines = {}
  for _, p in ipairs(ns.People()) do
    if p.handle then
      local last = seen[p.handle]
      if last and (p.updated or 0) > (last.updated or 0) then
        local parts = {}
        if p.level and last.level and p.level > last.level then
          parts[#parts + 1] = string.format("Level %d → %d", last.level, p.level)
        end
        if p.zone then parts[#parts + 1] = "zuletzt in " .. p.zone end
        parts[#parts + 1] = "(" .. ns.Ago(p.updated) .. ")"
        lines[#lines + 1] = p.name .. ": " .. table.concat(parts, ", ")
      end
      seen[p.handle] = { level = p.level, updated = p.updated }
    end
  end
  return lines
end

ns.Listen("LOGIN", function()
  hookUI()
  C_Timer.After(8, function()
    for _, line in ipairs(ns.LoginDigest()) do ns.Print(line) end
  end)
end)

---------------------------------------------------------------------------
-- Slash-Befehle
---------------------------------------------------------------------------
SLASH_WFSYNC1 = "/wf"
SLASH_WFSYNC2 = "/wfsync"
SlashCmdList["WFSYNC"] = function(msg)
  local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
  cmd = (cmd or ""):lower()
  if cmd == "" then
    ns.ToggleWindow()
  elseif cmd == "sync" then
    ns.SendHello(true)
    ns.Print("Sync angestoßen.")
  elseif cmd == "status" then
    local c = ns.char
    ns.Print("%s: Lvl %d (%d%%), %s, %d Quests erledigt, %d im Log",
      ns.key, c.level or 0, ns.XPPercent(c.xp, c.xpMax), c.zone or "?",
      ns.CountKeys(c.completed), ns.CountKeys(c.log))
  elseif cmd == "quest" then
    local id = tonumber(rest)
    if not id then ns.Print("Nutzung: /wf quest <questID>") return end
    local lines = ns.QuestStatusLines(id)
    if #lines == 0 then ns.Print("Keine Mitspieler bekannt.") end
    for _, line in ipairs(lines) do ns.Print(line) end
  elseif cmd == "debug" then
    ns.db.settings.debug = not ns.db.settings.debug
    ns.Print("Debug %s", ns.db.settings.debug and "an" or "aus")
  else
    ns.Print("/wf – Fenster · /wf sync · /wf status · /wf quest <id> · /wf debug")
  end
end
