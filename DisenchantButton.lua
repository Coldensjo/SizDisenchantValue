--[[
Disenchant button
-----------------
A small button that disenchants the next uncommon (green) weapon or armor piece
in your bags each time you press it. WoW only allows one spell cast per click
or key press, so it works through the items one press at a time.

  * The button sits under the backpack (or combined bags) window. /dv attach off
    makes it free-floating instead; then right-drag it to move it.
  * Bind a key: Game Menu > Options > Keybindings > AddOns > Disenchant Value.
  * Items skipped: ignored items (/dv ignore [item link]) and, with the auction
    house check on, items whose auction price is higher than their expected
    disenchant value.
  * Turn on auto loot (/console autoLootDefault 1) so results are picked up
    without clicking the loot window.

Slash commands: /dv button, /dv list, /dv ignore [link], /dv unignore [link],
/dv ahcheck on|off, /dv attach on|off
]]

local ADDON, ns = ...

local DISENCHANT_SPELL_ID = 13262
local CALLER_ID = "DisenchantValue"
local ITEMCLASS_WEAPON = (Enum and Enum.ItemClass and Enum.ItemClass.Weapon) or 2
local ITEMCLASS_ARMOR = (Enum and Enum.ItemClass and Enum.ItemClass.Armor) or 4
local QUALITY_UNCOMMON = (Enum and Enum.ItemQuality and Enum.ItemQuality.Good) or 2
local LAST_BAG = NUM_BAG_SLOTS or 4

_G["BINDING_HEADER_DISENCHANTVALUE"] = "Disenchant Value"
_G["BINDING_NAME_CLICK DisenchantValueButton:LeftButton"] = "Disenchant next green item"

local function DB() return _G.DisenchantValueDB end

local function Print(msg)
  print("|cff33ff99DisenchantValue|r: " .. msg)
end

---------------------------------------------------------------------------
-- Spell helpers
---------------------------------------------------------------------------

local function SpellName()
  if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(DISENCHANT_SPELL_ID) end
  return (GetSpellInfo(DISENCHANT_SPELL_ID))
end

local function KnowsDisenchant()
  if IsPlayerSpell and IsPlayerSpell(DISENCHANT_SPELL_ID) then return true end
  if IsSpellKnown and IsSpellKnown(DISENCHANT_SPELL_ID) then return true end
  return false
end

---------------------------------------------------------------------------
-- Choosing what to disenchant
---------------------------------------------------------------------------

-- Expected disenchant value in copper: learned value if we have one, else era table.
local function ExpectedValue(link)
  local actual = ns.GetDisenchantValue and ns.GetDisenchantValue(link)
  if actual and actual > 0 then return actual end
  local era = ns.GetEraValue and ns.GetEraValue(link)
  if era and era > 0 then return era end
end

local function AuctionPrice(link)
  if not (Auctionator and Auctionator.API and Auctionator.API.v1) then return end
  local ok, price = pcall(Auctionator.API.v1.GetAuctionPriceByItemLink, CALLER_ID, link)
  if ok and price and price > 0 then return price end
end

local function SkipReason(link, itemID)
  local d = DB()
  if d.ignore[itemID] then return "on your ignore list" end
  if d.ahCheck then
    local ah, value = AuctionPrice(link), ExpectedValue(link)
    if ah and value and ah > value then return "sells for more on the auction house" end
  end
end

-- Returns list of { bag, slot, link } to disenchant and list of { link, reason } skipped.
local function Scan()
  local items, skipped = {}, {}
  for bag = 0, LAST_BAG do
    for slot = 1, C_Container.GetContainerNumSlots(bag) do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.quality == QUALITY_UNCOMMON and info.hyperlink and not info.isLocked then
        local classID = select(6, C_Item.GetItemInfoInstant(info.hyperlink))
        if classID == ITEMCLASS_WEAPON or classID == ITEMCLASS_ARMOR then
          local reason = SkipReason(info.hyperlink, info.itemID)
          if reason then
            skipped[#skipped + 1] = { link = info.hyperlink, reason = reason }
          else
            items[#items + 1] = { bag = bag, slot = slot, link = info.hyperlink }
          end
        end
      end
    end
  end
  return items, skipped
end

---------------------------------------------------------------------------
-- The button
---------------------------------------------------------------------------

local button
do
  local ok, b = pcall(CreateFrame, "Button", "DisenchantValueButton", UIParent,
    "UIPanelButtonTemplate, SecureActionButtonTemplate")
  if ok then
    button = b
  else
    button = CreateFrame("Button", "DisenchantValueButton", UIParent, "SecureActionButtonTemplate")
    button.bg = button:CreateTexture(nil, "BACKGROUND")
    button.bg:SetAllPoints()
    button.bg:SetColorTexture(0.1, 0.1, 0.1, 0.85)
    button:SetNormalFontObject("GameFontNormal")
  end
end

button:SetSize(150, 26)
button:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
button:SetMovable(true)
button:SetClampedToScreen(true)
-- Register for one edge only: with both, the macro runs twice per press and the
-- second /use (no longer targeting Disenchant) tries to equip the item.
local function RegisterClicks()
  local keyDown = GetCVarBool and GetCVarBool("ActionButtonUseKeyDown")
  button:RegisterForClicks(keyDown and "AnyDown" or "AnyUp")
end
RegisterClicks()
button:RegisterForDrag("RightButton")
button:SetAttribute("type1", "macro")
button:SetAttribute("macrotext1", "")
button:SetText("Disenchant")
button:Hide()

local current, count, skippedCount = nil, 0, 0
local attachedTo -- the bag frame the button is attached to, or nil when free-floating
local needsRefresh = false

local function Refresh()
  local d = DB()
  if not d or not d.ignore then return end
  if InCombatLockdown() then needsRefresh = true return end
  needsRefresh = false

  local name = SpellName()
  if d.showButton == false or not name or not KnowsDisenchant() then
    button:Hide()
    return
  end

  local items, skipped = Scan()
  count, skippedCount = #items, #skipped
  current = items[1]
  if current then
    button:SetAttribute("macrotext1", ("/cast %s\n/use %d %d"):format(name, current.bag, current.slot))
  else
    button:SetAttribute("macrotext1", "")
  end
  button:SetText(("Disenchant (%d)"):format(count))
  button:Show()
end

local queued = false
local function QueueRefresh()
  if queued then return end
  queued = true
  C_Timer.After(0.2, function()
    queued = false
    Refresh()
  end)
end

-- True while a cast is in progress or the target item is locked (e.g. by a
-- disenchant already underway). Clicking then would make /cast fail and leave
-- /use on its own, which tries to equip the item.
local function Busy()
  if UnitCastingInfo and UnitCastingInfo("player") then return true end
  if UnitChannelInfo and UnitChannelInfo("player") then return true end
  local info = current and C_Container.GetContainerItemInfo(current.bag, current.slot)
  return info and info.isLocked or false
end

local suppressed
button:SetScript("PreClick", function(self, mouseButton)
  if mouseButton ~= "LeftButton" or not current then return end
  if Busy() then
    -- Attributes can only be changed out of combat.
    if not InCombatLockdown() then
      suppressed = self:GetAttribute("macrotext1")
      self:SetAttribute("macrotext1", "")
    end
    return
  end
  -- Let the learning code in the main file know which item this click targets.
  if ns.NoteTarget then ns.NoteTarget(current.link) end
end)

button:SetScript("PostClick", function(self)
  if suppressed and not InCombatLockdown() then
    self:SetAttribute("macrotext1", suppressed)
  end
  suppressed = nil
end)

button:SetScript("OnDragStart", function(self)
  if not InCombatLockdown() and not attachedTo then self:StartMoving() end
end)
button:SetScript("OnDragStop", function(self)
  if attachedTo then return end
  self:StopMovingOrSizing()
  local point, _, relPoint, x, y = self:GetPoint()
  local d = DB()
  if d then d.buttonPos = { point = point, relPoint = relPoint, x = x, y = y } end
end)

button:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:AddLine("Disenchant Value")
  if current then
    GameTooltip:AddDoubleLine("Next:", current.link)
    GameTooltip:AddDoubleLine("Green items to disenchant:", tostring(count), 1, 1, 1, 1, 1, 1)
  else
    GameTooltip:AddLine("No green weapons or armor to disenchant.", 1, 1, 1)
  end
  if skippedCount > 0 then
    GameTooltip:AddLine(("%d skipped (ignored or worth more on the auction house). /dv list shows them."):format(skippedCount), 0.7, 0.7, 0.7, true)
  end
  GameTooltip:AddLine(attachedTo and "Press repeatedly. Attached to the backpack (/dv attach off to move it)." or "Press repeatedly. Right-drag to move.", 0.7, 0.7, 0.7)
  GameTooltip:Show()
end)
button:SetScript("OnLeave", function() GameTooltip:Hide() end)

---------------------------------------------------------------------------
-- Attaching to the backpack
---------------------------------------------------------------------------

local function FrameBagID(frame)
  local ok, id = pcall(function()
    if frame.GetBagID then return frame:GetBagID() end
    return frame:GetID()
  end)
  return ok and id or nil
end

-- The frame currently showing the backpack (bag 0), or the combined bags frame.
local function FindBackpackFrame()
  local combined = _G.ContainerFrameCombinedBags
  local manager = _G.ContainerFrameSettingsManager
  if combined and manager and manager.IsUsingCombinedBags and manager:IsUsingCombinedBags() then
    return combined
  end
  for i = 1, 13 do
    local f = _G["ContainerFrame" .. i]
    if f and f:IsShown() and FrameBagID(f) == 0 then return f end
  end
  return _G.ContainerFrame1
end

local attachPending = false

local function Attach()
  local d = DB()
  if not d then return end
  if InCombatLockdown() then attachPending = true return end
  attachPending = false

  local frame = d.attach ~= false and FindBackpackFrame() or nil
  if frame then
    if attachedTo ~= frame then
      button:SetParent(frame)
      button:ClearAllPoints()
      button:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 8, 2)
      button:SetFrameLevel(frame:GetFrameLevel() + 5)
      attachedTo = frame
    end
  else
    -- Free-floating: back on the screen at the saved (or default) position.
    if attachedTo or button:GetParent() ~= UIParent then
      button:SetParent(UIParent)
      attachedTo = nil
    end
    button:ClearAllPoints()
    local p = d.buttonPos
    if p and p.point then
      button:SetPoint(p.point, UIParent, p.relPoint or p.point, p.x or 0, p.y or 0)
    else
      button:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
    end
  end
end

local attachQueued = false
local function QueueAttach()
  if attachQueued then return end
  attachQueued = true
  C_Timer.After(0, function()
    attachQueued = false
    Attach()
  end)
end

local function HookBagFrames()
  local frames = { _G.ContainerFrameCombinedBags }
  for i = 1, 13 do frames[#frames + 1] = _G["ContainerFrame" .. i] end
  for _, f in pairs(frames) do
    if f and f.HookScript then f:HookScript("OnShow", QueueAttach) end
  end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("BAG_UPDATE_DELAYED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("SPELLS_CHANGED")
events:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
pcall(events.RegisterEvent, events, "USE_COMBINED_BAGS_CHANGED")
events:RegisterEvent("CVAR_UPDATE")
events:SetScript("OnEvent", function(_, event, unit, _, spellID)
  if event == "CVAR_UPDATE" then
    if not InCombatLockdown() then RegisterClicks() end
  elseif event == "PLAYER_LOGIN" then
    local d = DB()
    if not d then return end
    d.ignore = d.ignore or {}
    if d.ahCheck == nil then d.ahCheck = true end
    HookBagFrames()
    Attach()
    QueueRefresh()
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    -- Only disenchants matter here; bag changes are covered by BAG_UPDATE_DELAYED.
    if unit == "player" and spellID == DISENCHANT_SPELL_ID then QueueRefresh() end
  else
    if attachPending or event == "BAG_UPDATE_DELAYED" or event == "USE_COMBINED_BAGS_CHANGED" then
      QueueAttach()
    end
    QueueRefresh()
  end
end)

---------------------------------------------------------------------------
-- Slash commands (called from the main file's /dv handler)
---------------------------------------------------------------------------

local function ItemIDFrom(text)
  return tonumber(text:match("item:(%d+)")) or tonumber(text)
end

function ns.ButtonSlash(msg)
  local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)%s*$")
  cmd = cmd:lower()
  local d = DB()
  if not d or not d.ignore then return false end

  if cmd == "button" then
    d.showButton = (d.showButton == false)
    Print("disenchant button " .. (d.showButton and "shown" or "hidden"))
    Refresh()
  elseif cmd == "ignore" or cmd == "unignore" then
    local id = ItemIDFrom(rest)
    if not id then
      Print("usage: /dv " .. cmd .. " [shift-click an item into the chat box]")
    elseif cmd == "ignore" then
      d.ignore[id] = true
      Print("ignoring " .. rest)
      Refresh()
    else
      d.ignore[id] = nil
      Print("no longer ignoring " .. rest)
      Refresh()
    end
  elseif cmd == "attach" then
    d.attach = (rest:lower() ~= "off")
    Print(d.attach and "button attached to the backpack" or "button detached, right-drag it to move")
    Attach()
    Refresh()
  elseif cmd == "ahcheck" then
    d.ahCheck = (rest:lower() ~= "off")
    Print("auction house check " .. (d.ahCheck and "on" or "off"))
    Refresh()
  elseif cmd == "list" then
    local items, skipped = Scan()
    Print(("%d to disenchant, %d skipped"):format(#items, #skipped))
    for _, it in ipairs(items) do Print("  " .. it.link) end
    for _, it in ipairs(skipped) do Print(("  skipped %s: %s"):format(it.link, it.reason)) end
  else
    return false
  end
  return true
end
