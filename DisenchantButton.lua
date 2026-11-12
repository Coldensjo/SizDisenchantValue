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
		It hides in combat and comes back when combat ends.
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
	local id = DISENCHANT_SPELL_ID
	if IsPlayerSpell and IsPlayerSpell(id) then return true end
	if IsSpellKnown and IsSpellKnown(id) then return true end
	if IsSpellKnownOrOverridesKnown and IsSpellKnownOrOverridesKnown(id) then return true end
	if C_SpellBook then
		if C_SpellBook.IsSpellKnown and C_SpellBook.IsSpellKnown(id) then return true end
		if C_SpellBook.IsSpellInSpellBook and C_SpellBook.IsSpellInSpellBook(id) then return true end
	end
	-- Last resort: look the spell up by name in the spellbook.
	local name = SpellName()
	if name and C_SpellBook and C_SpellBook.FindSpellBookSlotForSpell then
		local ok, slot = pcall(C_SpellBook.FindSpellBookSlotForSpell, name)
		if ok and slot then return true end
	end
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
	-- Always parented to UIParent and never anchored to a bag window: a secure
	-- button makes any frame it is parented or anchored to protected, which
	-- stops bag addons from showing or hiding their windows in combat.
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
button:SetFrameStrata("DIALOG")
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
local available = false -- the button should show (with the bags) at all
local dragged = false -- set while Alt-dragging: the click that ends a drag must not disenchant
local needsRefresh = false
local UpdatePosition -- defined in "Following the bags"

local function Refresh()
	local d = DB()
	if not d or not d.ignore then return end
	if InCombatLockdown() then needsRefresh = true return end
	needsRefresh = false

	local name = SpellName()
	if d.showButton == false or not name or not KnowsDisenchant() then
		available = false
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
	available = true
	if UpdatePosition then UpdatePosition(true) end
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
-- Following the bags
-- The button stays parented to UIParent and is only ever anchored to UIParent.
-- Parenting or anchoring a secure button to a bag addon's window would make
-- that window protected, and the addon could then no longer show or hide it in
-- combat (bags that will not open, ESC that will not close them).
-- Instead a plain watcher frame checks, out of combat, which backpack window is
-- open (Blizzard's or a bag addon's: Bagnon, Baganator, AdiBags, ArkInventory,
-- ElvUI, Combuctor, ...) and shows the button at the matching screen spot.
--	* Default spot: under the backpack window.
--	* Alt-drag drops it onto any window, where it then sits (saved by frame name
--		and offset), or onto empty screen, where it stays put. Either way it
--		only shows while the bags are open.
-- In combat the button is hidden: a secure button cannot be shown, hidden or
-- moved then, so it could not follow the bags.
-- Saved offsets are in screen pixels, so they hold whatever the UI scale.
---------------------------------------------------------------------------

-- Backpack windows of bag addons with fixed frame names.
local BAG_ADDON_FRAMES = {
	"AdiBagsContainer1",
	"ARKINV_Frame1",
	"ElvUI_ContainerFrame",
}
-- Bag addons with generated frame names register their windows in
-- UISpecialFrames; their inventory window is the one whose name starts with one
-- of these (lower case) and is not a bank, guild bank or settings window.
local BAG_ADDON_PREFIXES = {
	"baganator_singleviewbackpackviewframe",
	"baganator_categoryviewbackpackviewframe",
	"bagnon",
	"combuctor",
}
local NOT_INVENTORY = { "bank", "guild", "vault", "config", "option", "setting", "keyring" }

local function FrameBagID(frame)
	local ok, id = pcall(function()
		if frame.GetBagID then return frame:GetBagID() end
		return frame:GetID()
	end)
	return ok and id or nil
end

local function IsInventoryName(name)
	if type(name) ~= "string" then return false end
	local lower = name:lower()
	for _, word in ipairs(NOT_INVENTORY) do
		if lower:find(word, 1, true) then return false end
	end
	for _, prefix in ipairs(BAG_ADDON_PREFIXES) do
		if lower:sub(1, #prefix) == prefix then return true end
	end
	return false
end

local function Visible(f)
	return type(f) == "table" and f.IsVisible and f:IsVisible() and f:GetLeft() ~= nil
end

-- Blizzard's backpack window: the combined bags frame, or the one showing bag 0.
local function BlizzardBackpack()
	local combined = _G.ContainerFrameCombinedBags
	if Visible(combined) then return combined end
	for i = 1, 13 do
		local f = _G["ContainerFrame" .. i]
		if Visible(f) and FrameBagID(f) == 0 then return f end
	end
end

-- The backpack window that is open right now, bag addons first.
local lastFound
local function FindOpenBagFrame()
	if Visible(lastFound) then return lastFound end
	lastFound = nil
	for _, name in ipairs(BAG_ADDON_FRAMES) do
		local f = _G[name]
		if Visible(f) then lastFound = f return f end
	end
	for _, name in ipairs(UISpecialFrames or {}) do
		if IsInventoryName(name) then
			local f = _G[name]
			if Visible(f) then lastFound = f return f end
		end
	end
	return BlizzardBackpack()
end

-- Screen position (pixels) of the button's top-left corner for this bag window.
local function TargetSpot(d, bagFrame)
	if d.attach == false and d.screenPos then
		return d.screenPos.x, d.screenPos.y
	end
	if d.attach == false and d.buttonPos and d.buttonPos.point then
		-- Position saved by older versions: convert once to a screen spot.
		local p = d.buttonPos
		button:ClearAllPoints()
		button:SetPoint(p.point, UIParent, p.relPoint or p.point, p.x or 0, p.y or 0)
		local left, top = button:GetLeft(), button:GetTop()
		if not (left and top) then return end
		local s = button:GetEffectiveScale()
		d.screenPos, d.buttonPos = { x = left * s, y = top * s }, nil
		return d.screenPos.x, d.screenPos.y
	end
	local anchor = d.anchor
	local target = anchor and anchor.name and _G[anchor.name]
	if d.attach ~= false and Visible(target) then
		local ts = target:GetEffectiveScale()
		return target:GetLeft() * ts + anchor.x, target:GetTop() * ts + anchor.y
	end
	-- Default, and a saved window that is not open: under the bags.
	local bs = bagFrame:GetEffectiveScale()
	return (bagFrame:GetLeft() + 8) * bs, (bagFrame:GetBottom() + 2) * bs
end

local placedX, placedY
-- Shows the button at its spot while the bags are open, hides it otherwise.
-- Out of combat only. force: move it even if the spot looks unchanged.
function UpdatePosition(force)
	if InCombatLockdown() or dragged then return end
	local d = DB()
	local bagFrame = available and d and FindOpenBagFrame()
	if not bagFrame then
		if button:IsShown() then button:Hide() end
		return
	end
	local x, y = TargetSpot(d, bagFrame)
	if not (x and y) then return end
	if force or not button:IsShown() or not placedX
		or math.abs(x - placedX) > 0.5 or math.abs(y - placedY) > 0.5 then
		placedX, placedY = x, y
		local s = button:GetEffectiveScale()
		button:ClearAllPoints()
		button:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / s, y / s)
	end
	if not button:IsShown() then button:Show() end
end

-- A plain (non-secure) frame that keeps the button with the bags. Its
-- OnUpdate only runs out of combat, a few times a second.
local watcher = CreateFrame("Frame", nil, UIParent)
local elapsedSince, ticks = 0, 0
watcher:SetScript("OnUpdate", function(_, elapsed)
	elapsedSince = elapsedSince + elapsed
	if elapsedSince < 0.1 then return end
	elapsedSince = 0
	ticks = ticks + 1
	UpdatePosition(false)
end)
watcher:Hide()

-- Also react right away when a bag window opens or closes (HookScript on
-- another addon's frame is harmless: it does not taint or protect it).
local hooked = {}
local function OnBagShowHide()
	C_Timer.After(0, function() UpdatePosition(true) end)
end
local function HookBagWindows()
	local frames = { _G.ContainerFrameCombinedBags }
	for i = 1, 13 do frames[#frames + 1] = _G["ContainerFrame" .. i] end
	for _, name in ipairs(BAG_ADDON_FRAMES) do frames[#frames + 1] = _G[name] end
	for _, name in ipairs(UISpecialFrames or {}) do
		if IsInventoryName(name) then frames[#frames + 1] = _G[name] end
	end
	for _, f in pairs(frames) do
		if type(f) == "table" and f.HookScript and not hooked[f] then
			hooked[f] = true
			f:HookScript("OnShow", OnBagShowHide)
			f:HookScript("OnHide", OnBagShowHide)
		end
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
	if target and target ~= button and target:GetLeft() then
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
end

button:RegisterForDrag("LeftButton", "RightButton")
button:SetScript("OnDragStart", function(self)
	if InCombatLockdown() or not IsAltKeyDown() then return end
	dragged = true
	self:StartMoving()
end)
button:SetScript("OnDragStop", function(self)
	if not dragged then return end
	self:StopMovingOrSizing()
	if self.SetUserPlaced then pcall(self.SetUserPlaced, self, false) end
	-- Let the mouse look through the button to find the window under it.
	self:EnableMouse(false)
	C_Timer.After(0.05, function()
		if not dragged then return end -- combat started; PLAYER_REGEN_DISABLED reset it
		Drop()
		self:EnableMouse(true)
		dragged = false
		UpdatePosition(true)
	end)
end)

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("BAG_UPDATE_DELAYED")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("SPELLS_CHANGED")
events:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
events:RegisterEvent("GET_ITEM_INFO_RECEIVED")
events:RegisterEvent("CVAR_UPDATE")
events:SetScript("OnEvent", function(_, event, unit, _, spellID)
	if event == "CVAR_UPDATE" then
		if not InCombatLockdown() then RegisterClicks() end
	elseif event == "PLAYER_LOGIN" then
		local d = DB()
		if not d then return end
		d.ignore = d.ignore or {}
		if d.ahCheck == nil then d.ahCheck = true end
		watcher:Show()
		HookBagWindows()
		QueueRefresh()
	elseif event == "PLAYER_REGEN_DISABLED" then
		-- Still allowed here, just before the combat lockdown starts.
		watcher:Hide()
		if dragged then
			button:StopMovingOrSizing()
			button:EnableMouse(true)
			dragged = false
		end
		button:Hide()
	elseif event == "PLAYER_REGEN_ENABLED" then
		watcher:Show()
		if needsRefresh then QueueRefresh() end
		UpdatePosition(true)
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		-- Only disenchants matter here; bag changes are covered by BAG_UPDATE_DELAYED.
		if unit == "player" and spellID == DISENCHANT_SPELL_ID then QueueRefresh() end
	else
		HookBagWindows() -- bag addons may create their windows after login
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
		if d.attach then
			d.screenPos, d.buttonPos = nil, nil
		elseif not d.screenPos and button:IsShown() and button:GetLeft() then
			local s = button:GetEffectiveScale()
			d.screenPos = { x = button:GetLeft() * s, y = button:GetTop() * s }
		end
		Print(d.attach and "button is back under your bags" or "button stays where it is; Alt-drag it to move")
		UpdatePosition(true)
		Refresh()
	elseif cmd == "ahcheck" then
		d.ahCheck = (rest:lower() ~= "off")
		Print("auction house check " .. (d.ahCheck and "on" or "off"))
		Refresh()
	elseif cmd == "status" then
		-- Why the button is or is not showing. Most important lines last, so
		-- they stay on screen in the chat box.
		local names = {}
		for _, n in ipairs(UISpecialFrames or {}) do
			if type(n) == "string" and n:lower():find("bag", 1, true) then
				local fr = _G[n]
				names[#names + 1] = n .. ((fr and fr.IsVisible and fr:IsVisible()) and " (open)" or "")
			end
		end
		Print("bag windows known: " .. (#names > 0 and table.concat(names, ", ") or "none"))
		Print(("attach: %s, anchor: %s, screenPos: %s"):format(tostring(d.attach),
			tostring(d.anchor and d.anchor.name), tostring(d.screenPos and (d.screenPos.x .. "," .. d.screenPos.y))))
		Print(("button shown: %s, visible: %s, at: %s, %s, strata %s"):format(tostring(button:IsShown()),
			tostring(button:IsVisible()), tostring(button:GetLeft()), tostring(button:GetTop()), button:GetFrameStrata()))
		local ok, f = pcall(FindOpenBagFrame)
		Print("open bag window: " .. (not ok and ("error: " .. tostring(f)) or (f and (f:GetName() or "(unnamed)") or "none found")))
		Print(("available: %s, in combat: %s, dragging: %s, watcher shown: %s, ticks: %d"):format(
			tostring(available), tostring(InCombatLockdown()), tostring(dragged), tostring(watcher:IsShown()), ticks))
		Print(("spell name: %s, knows Disenchant: %s, button setting: %s, IsPlayerSpell: %s"):format(
			tostring(SpellName()), tostring(KnowsDisenchant()), d.showButton == false and "hidden" or "shown",
			tostring(IsPlayerSpell and IsPlayerSpell(DISENCHANT_SPELL_ID))))
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
