--[[
Disenchant button
-----------------
A small button that disenchants the next uncommon (green) weapon or armor piece
in your bags each time you press it. WoW only allows one spell cast per click
or key press, so it works through the items one press at a time.

	* The button sits under your backpack window and only shows while it is
		open; this works with Blizzard's bags and bag addons (Bagnon,
		Baganator, AdiBags, ArkInventory, ElvUI). Alt-drag it to move it: drop
		it on any window to attach it there, or anywhere on the screen. It still
		only shows while the bags are open. /dv attach puts it back under the bags.
	* Bind a key: Game Menu > Options > Keybindings > AddOns > Disenchant Value.
	* Items skipped: ignored items (/dv ignore [item link]) and, with the auction
		house check on, items whose auction price is higher than their expected
		disenchant value.
	* Turn on auto loot (/console autoLootDefault 1) so results are picked up
		without clicking the loot window.

Slash commands: /dv button, /dv list, /dv ignore [link], /dv unignore [link],
/dv ahcheck on|off, /dv attach [off]
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

-- Expected disenchant value in copper (see ns.GetExpectedValue in the main file).
local function ExpectedValue(link)
	return ns.GetExpectedValue and ns.GetExpectedValue(link)
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
				if (classID == ITEMCLASS_WEAPON or classID == ITEMCLASS_ARMOR)
					and not (ns.CannotDisenchant and ns.CannotDisenchant(info.itemID)) then
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
	-- Created in a hidden holder: it only becomes visible once it is attached
	-- to the bags (see "Attaching to the bags").
	local holder = CreateFrame("Frame")
	holder:Hide()
	local ok, b = pcall(CreateFrame, "Button", "DisenchantValueButton", holder,
		"UIPanelButtonTemplate, SecureActionButtonTemplate")
	if ok then
		button = b
	else
		button = CreateFrame("Button", "DisenchantValueButton", holder, "SecureActionButtonTemplate")
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
button:SetAttribute("type1", "macro")
button:SetAttribute("macrotext1", "")
button:SetText("Disenchant")
button:Hide()

local current, count, skippedCount = nil, 0, 0
local bagFrame -- the backpack window the button belongs to; it shows and hides with it
local dragged = false -- set while Alt-dragging: the click that ends a drag must not disenchant
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
	if dragged or Busy() then
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
	GameTooltip:AddLine("Press repeatedly to disenchant one item per press.", 0.7, 0.7, 0.7)
	GameTooltip:AddLine("Alt-drag to move it, or drop it on another window to attach it there.", 0.7, 0.7, 0.7)
	GameTooltip:Show()
end)
button:SetScript("OnLeave", function() GameTooltip:Hide() end)

---------------------------------------------------------------------------
-- Attaching to the bags
-- Visibility and position are separate:
--	* The button is always parented to the backpack window, so it only shows
--		while the bags are open. That is whichever backpack window is open:
--		Blizzard's or a bag addon's (Bagnon, Baganator, AdiBags, ArkInventory,
--		ElvUI, ...).
--	* Its position is under the bags by default. Alt-dragging it drops it onto
--		any window, where it then sits (saved by frame name), or onto empty
--		screen, where it stays put. Either way it still only shows with the bags.
-- Saved offsets are in screen pixels, so they hold whatever the scale of the
-- bag window it is parented to.
---------------------------------------------------------------------------

-- Backpack windows of bag addons, by frame name.
local BAG_ADDON_FRAMES = {
	"Baganator_SingleViewBackpackViewFrame",
	"Baganator_CategoryViewBackpackViewFrame",
	"AdiBagsContainer1",
	"ARKINV_Frame1",
	"ElvUI_ContainerFrame",
}
-- Bag addons with generated frame names (Bagnon, Combuctor) register their
-- windows in UISpecialFrames; their inventory window is the one whose name
-- starts with one of these and is not a bank, guild bank or settings window.
local BAG_ADDON_PREFIXES = { "bagnon", "combuctor" }
local NOT_INVENTORY = { "bank", "guild", "vault", "config", "option", "setting", "keyring" }

local function FrameBagID(frame)
	local ok, id = pcall(function()
		if frame.GetBagID then return frame:GetBagID() end
		return frame:GetID()
	end)
	return ok and id or nil
end

local function IsInventoryName(name)
	local lower = name:lower()
	for _, word in ipairs(NOT_INVENTORY) do
		if lower:find(word, 1, true) then return false end
	end
	for _, prefix in ipairs(BAG_ADDON_PREFIXES) do
		if lower:sub(1, #prefix) == prefix then return true end
	end
	return false
end

-- Blizzard's backpack window: the combined bags frame, or the one showing bag 0.
local function BlizzardBackpack(shownOnly)
	local combined = _G.ContainerFrameCombinedBags
	local manager = _G.ContainerFrameSettingsManager
	if combined and manager and manager.IsUsingCombinedBags and manager:IsUsingCombinedBags() then
		if not shownOnly or combined:IsShown() then return combined end
	end
	for i = 1, 13 do
		local f = _G["ContainerFrame" .. i]
		if f and f:IsShown() and FrameBagID(f) == 0 then return f end
	end
	if not shownOnly then return _G.ContainerFrame1 end
end

-- The backpack window that is open right now, bag addons first.
local function FindOpenBagFrame()
	for _, name in ipairs(BAG_ADDON_FRAMES) do
		local f = _G[name]
		if f and f.IsVisible and f:IsVisible() then return f end
	end
	for _, name in ipairs(UISpecialFrames or {}) do
		local f = _G[name]
		if f and f.IsVisible and f:IsVisible() and IsInventoryName(name) then return f end
	end
	return BlizzardBackpack(true)
end

-- Positions the button: on a saved window, at a saved screen spot, or under the bags.
local function Place(d)
	button:ClearAllPoints()
	local s = button:GetEffectiveScale()
	local anchor = d.anchor
	local target = anchor and anchor.name and _G[anchor.name]
	if d.attach == false and d.screenPos then
		button:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", d.screenPos.x / s, d.screenPos.y / s)
	elseif d.attach == false and d.buttonPos and d.buttonPos.point then
		-- Position saved by older versions, in UIParent units.
		local p, f = d.buttonPos, UIParent:GetEffectiveScale() / s
		button:SetPoint(p.point, UIParent, p.relPoint or p.point, (p.x or 0) * f, (p.y or 0) * f)
	elseif d.attach ~= false and type(target) == "table" and target.GetObjectType then
		button:SetPoint("TOPLEFT", target, "TOPLEFT", anchor.x / s, anchor.y / s)
	else
		-- Default, and a saved window that does not exist yet (bag addons often
		-- create theirs on first use): under the bags. Every bag opening tries again.
		button:SetPoint("TOPLEFT", bagFrame, "BOTTOMLEFT", 8, 2)
	end
end

local attachPending = false

local function Attach()
	local d = DB()
	if not d then return end
	-- A secure button cannot be re-parented or moved in combat.
	if InCombatLockdown() then attachPending = true return end
	attachPending = false

	-- Stay with the last backpack window while the bags are closed.
	local frame = FindOpenBagFrame() or bagFrame or BlizzardBackpack(false)
	if not frame then return end
	if button:GetParent() ~= frame then button:SetParent(frame) end
	bagFrame = frame
	button:SetFrameStrata("HIGH")
	button:SetFrameLevel(frame:GetFrameLevel() + 20)
	Place(d)
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

-- Called at login, after every addon is loaded, so bag addons that replace
-- these functions are hooked too.
local function HookBagOpening()
	for _, fn in ipairs({ "ToggleBackpack", "OpenBackpack", "ToggleAllBags", "OpenAllBags", "OpenBag", "ToggleBag" }) do
		if type(_G[fn]) == "function" then hooksecurefunc(fn, QueueAttach) end
	end
	local frames = { _G.ContainerFrameCombinedBags }
	for i = 1, 13 do frames[#frames + 1] = _G["ContainerFrame" .. i] end
	for _, name in ipairs(BAG_ADDON_FRAMES) do frames[#frames + 1] = _G[name] end
	for _, f in pairs(frames) do
		if f and f.HookScript then f:HookScript("OnShow", QueueAttach) end
	end
end

---------------------------------------------------------------------------
-- Alt-drag to move the button and attach it to whatever it is dropped on
---------------------------------------------------------------------------

-- The window under the cursor: the top-level named frame that contains the
-- frame the mouse is over, or nil over empty screen.
local function WindowUnderCursor()
	local foci = GetMouseFoci and GetMouseFoci() or { GetMouseFocus and GetMouseFocus() }
	local f = foci and foci[1]
	while f and f ~= UIParent and f ~= WorldFrame do
		local parent = f:GetParent()
		if (not parent or parent == UIParent) and f:GetName() then return f end
		f = parent
	end
end

local function Drop()
	local d = DB()
	if not d then return end
	local s = button:GetEffectiveScale()
	local left, top = button:GetLeft() * s, button:GetTop() * s
	local target = WindowUnderCursor()
	if target and target ~= button then
		local ts = target:GetEffectiveScale()
		d.attach = true
		d.anchor = { name = target:GetName(), x = left - target:GetLeft() * ts, y = top - target:GetTop() * ts }
		d.screenPos, d.buttonPos = nil, nil
		Print("button attached to " .. target:GetName() .. ". It still only shows while your bags are open. /dv attach puts it back under the bags.")
	else
		d.attach = false
		d.anchor, d.buttonPos = nil, nil
		d.screenPos = { x = left, y = top }
		Print("button moved. It only shows while your bags are open. /dv attach puts it back under the bags.")
	end
	Attach()
end

button:RegisterForDrag("LeftButton", "RightButton")
button:SetScript("OnDragStart", function(self)
	if InCombatLockdown() or not IsAltKeyDown() then return end
	dragged = true
	-- Move on the screen while dragging, so the old window does not carry it along.
	local left, top = self:GetLeft() * self:GetEffectiveScale(), self:GetTop() * self:GetEffectiveScale()
	self:SetParent(UIParent)
	self:SetFrameStrata("TOOLTIP")
	self:ClearAllPoints()
	local s = self:GetEffectiveScale()
	self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left / s, top / s)
	self:StartMoving()
end)
button:SetScript("OnDragStop", function(self)
	if not dragged then return end
	self:StopMovingOrSizing()
	if self.SetUserPlaced then pcall(self.SetUserPlaced, self, false) end
	-- Let the mouse look through the button to find the window under it.
	self:EnableMouse(false)
	C_Timer.After(0.05, function()
		Drop()
		self:EnableMouse(true)
		dragged = false
	end)
end)

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("BAG_UPDATE_DELAYED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("SPELLS_CHANGED")
events:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
events:RegisterEvent("GET_ITEM_INFO_RECEIVED")
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
		HookBagOpening()
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
		-- Back under the bags. ("off" from older versions: leave it where it is on screen.)
		d.attach = (rest:lower() ~= "off")
		d.anchor = nil
		if d.attach then d.screenPos, d.buttonPos = nil, nil end
		Print(d.attach and "button is back under your bags" or "button stays where it is; Alt-drag it to move")
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
