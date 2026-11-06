--[[
DisenchantValue
---------------
Adds a tooltip line with the expected disenchant value of uncommon, rare and
epic weapons/armor of any item level.

How it works
	* WoW has no API for disenchant loot tables, so this addon LEARNS them: every
		time you disenchant an item it records what dropped, bucketed by
		item class / quality / item level bracket.
	* Expected value = sum(average quantity dropped * Auctionator price of the material).
		Prices are read live from Auctionator, so the value follows your latest scans.
	* If the exact bucket has no samples yet, the nearest bucket (same class and
		quality, within two brackets) is used and the value is shown with "~".
]]

local ADDON, ns = ...

local DISENCHANT_SPELL_ID = 13262
local CALLER_ID = "DisenchantValue"
local BRACKET_SIZE = 5
local MAX_BRACKET_DISTANCE = 2 -- in brackets, for the nearest-bucket fallback
local PENDING_TIMEOUT = 15

local ITEMCLASS_WEAPON = (Enum and Enum.ItemClass and Enum.ItemClass.Weapon) or 2
local ITEMCLASS_ARMOR = (Enum and Enum.ItemClass and Enum.ItemClass.Armor) or 4

local db -- = DisenchantValueDB

local function Print(msg)
	print("|cff33ff99DisenchantValue|r: " .. msg)
end

---------------------------------------------------------------------------
-- Bucketing
---------------------------------------------------------------------------

local function GetItemLevel(link)
	local fn = (C_Item and C_Item.GetDetailedItemLevelInfo) or GetDetailedItemLevelInfo
	return fn and fn(link) or nil
end

local function BracketFor(ilvl)
	if ilvl <= 15 then return 15 end
	return math.ceil(ilvl / BRACKET_SIZE) * BRACKET_SIZE
end

-- Weapons and armor that cannot be disenchanted: the wands enchanters craft.
local NOT_DISENCHANTABLE = {
	[11287] = true, -- Lesser Magic Wand
	[11288] = true, -- Greater Magic Wand
	[11289] = true, -- Lesser Mystic Wand
	[11290] = true, -- Greater Mystic Wand
}

-- Also used by the disenchant button, so it skips them too.
function ns.CannotDisenchant(itemID)
	return itemID and NOT_DISENCHANTABLE[itemID] or false
end

local function IsDisenchantable(classID, quality)
	return (classID == ITEMCLASS_WEAPON or classID == ITEMCLASS_ARMOR)
		and quality and quality >= 2 and quality <= 4 -- uncommon, rare and epic
end

---------------------------------------------------------------------------
-- Era (Vanilla) disenchant table, all item levels, uncommon/rare/epic.
-- Source: https://warcraft.wiki.gg/wiki/Disenchanting_tables
-- Rows: { minIlvl, maxIlvl, { chance%, minQty, maxQty, itemID }, ... }
---------------------------------------------------------------------------

local STRANGE_DUST, SOUL_DUST, VISION_DUST, DREAM_DUST, ILLUSION_DUST = 10940, 11083, 11137, 11176, 16204
local LESSER_MAGIC, GREATER_MAGIC = 10938, 10939
local LESSER_ASTRAL, GREATER_ASTRAL = 10998, 11082
local LESSER_MYSTIC, GREATER_MYSTIC = 11134, 11135
local LESSER_NETHER, GREATER_NETHER = 11174, 11175
local LESSER_ETERNAL, GREATER_ETERNAL = 16202, 16203
local SMALL_GLIMMERING, LARGE_GLIMMERING = 10978, 11084
local SMALL_GLOWING, LARGE_GLOWING = 11138, 11139
local SMALL_RADIANT, LARGE_RADIANT = 11177, 11178
local SMALL_BRILLIANT, LARGE_BRILLIANT = 14343, 14344
local NEXUS_CRYSTAL = 20725

-- Every material the tables can give (used by /dv debug).
local ERA_MATERIALS = {
	STRANGE_DUST, SOUL_DUST, VISION_DUST, DREAM_DUST, ILLUSION_DUST,
	LESSER_MAGIC, GREATER_MAGIC, LESSER_ASTRAL, GREATER_ASTRAL, LESSER_MYSTIC, GREATER_MYSTIC,
	LESSER_NETHER, GREATER_NETHER, LESSER_ETERNAL, GREATER_ETERNAL,
	SMALL_GLIMMERING, LARGE_GLIMMERING, SMALL_GLOWING, LARGE_GLOWING,
	SMALL_RADIANT, LARGE_RADIANT, SMALL_BRILLIANT, LARGE_BRILLIANT, NEXUS_CRYSTAL,
}

-- Uncommon: armor gives mostly dust, weapons mostly essence (the dust and
-- essence chances are swapped), plus a small chance of a shard.
-- { minIlvl, maxIlvl, dust%, essence%, shard%, dust, dustMin, dustMax, essence, essMin, essMax, shard }
local UNCOMMON = {
	{ 1, 15, 80, 20, 0, STRANGE_DUST, 1, 2, LESSER_MAGIC, 1, 2 },
	{ 16, 20, 75, 20, 5, STRANGE_DUST, 2, 3, GREATER_MAGIC, 1, 2, SMALL_GLIMMERING },
	{ 21, 25, 75, 15, 10, STRANGE_DUST, 4, 6, LESSER_ASTRAL, 1, 2, SMALL_GLIMMERING },
	{ 26, 30, 75, 20, 5, SOUL_DUST, 1, 2, GREATER_ASTRAL, 1, 2, LARGE_GLIMMERING },
	{ 31, 35, 75, 20, 5, SOUL_DUST, 2, 5, LESSER_MYSTIC, 1, 2, SMALL_GLOWING },
	{ 36, 40, 75, 20, 5, VISION_DUST, 1, 2, GREATER_MYSTIC, 1, 2, LARGE_GLOWING },
	{ 41, 45, 75, 20, 5, VISION_DUST, 2, 5, LESSER_NETHER, 1, 2, SMALL_RADIANT },
	{ 46, 50, 75, 20, 5, DREAM_DUST, 1, 2, GREATER_NETHER, 1, 2, LARGE_RADIANT },
	{ 51, 55, 75, 20, 5, DREAM_DUST, 2, 5, LESSER_ETERNAL, 1, 2, SMALL_BRILLIANT },
	{ 56, 60, 75, 20, 5, ILLUSION_DUST, 1, 2, GREATER_ETERNAL, 1, 2, LARGE_BRILLIANT },
	{ 61, 999, 75, 20, 5, ILLUSION_DUST, 2, 5, GREATER_ETERNAL, 2, 3, LARGE_BRILLIANT },
}

-- The item level brackets above with the dust, essence and shard each gives,
-- for the auction house scanner's bracket filters.
ns.DISENCHANT_BRACKETS = {}
for _, u in ipairs(UNCOMMON) do
	ns.DISENCHANT_BRACKETS[#ns.DISENCHANT_BRACKETS + 1] = { min = u[1], max = u[2], materials = { u[6], u[9], u[12] } }
end

local function BuildUncommon(isWeapon)
	local rows = {}
	for _, u in ipairs(UNCOMMON) do
		local dustChance, essChance = u[3], u[4]
		if isWeapon then dustChance, essChance = essChance, dustChance end
		local row = { u[1], u[2], { dustChance, u[7], u[8], u[6] }, { essChance, u[10], u[11], u[9] } }
		if u[5] > 0 then row[#row + 1] = { u[5], 1, 1, u[12] } end
		rows[#rows + 1] = row
	end
	return rows
end

-- Rare and epic items give shards (or Nexus Crystals), the same for armor and weapons.
local ERA_RARE = {
	{ 1, 25, { 100, 1, 1, SMALL_GLIMMERING } },
	{ 26, 30, { 100, 1, 1, LARGE_GLIMMERING } },
	{ 31, 35, { 100, 1, 1, SMALL_GLOWING } },
	{ 36, 40, { 100, 1, 1, LARGE_GLOWING } },
	{ 41, 45, { 100, 1, 1, SMALL_RADIANT } },
	{ 46, 50, { 100, 1, 1, LARGE_RADIANT } },
	{ 51, 55, { 100, 1, 1, SMALL_BRILLIANT } },
	{ 56, 999, { 99.5, 1, 1, LARGE_BRILLIANT }, { 0.5, 1, 1, NEXUS_CRYSTAL } },
}
local ERA_EPIC = {
	{ 1, 45, { 100, 2, 4, SMALL_RADIANT } },
	{ 46, 50, { 100, 2, 4, LARGE_RADIANT } },
	{ 51, 55, { 100, 2, 4, SMALL_BRILLIANT } },
	{ 56, 60, { 100, 1, 1, NEXUS_CRYSTAL } },
	{ 61, 999, { 100, 1, 2, NEXUS_CRYSTAL } },
}

local ERA = {
	[ITEMCLASS_ARMOR] = { [2] = BuildUncommon(false), [3] = ERA_RARE, [4] = ERA_EPIC },
	[ITEMCLASS_WEAPON] = { [2] = BuildUncommon(true), [3] = ERA_RARE, [4] = ERA_EPIC },
}

-- Returns classID, quality, bracket for an item link, or nil if not disenchantable.
local function Classify(link)
	if not link then return end
	local _, _, quality, _, _, _, _, _, _, _, _, classID = C_Item.GetItemInfo(link)
	if not classID then return end
	if not IsDisenchantable(classID, quality) then return end
	if ns.CannotDisenchant(C_Item.GetItemInfoInstant(link)) then return end
	local ilvl = GetItemLevel(link)
	if not ilvl or ilvl <= 0 then return end
	return classID, quality, BracketFor(ilvl), ilvl
end

local function Key(classID, quality, bracket)
	return classID .. ":" .. quality .. ":" .. bracket
end

---------------------------------------------------------------------------
-- Prices (Auctionator)
---------------------------------------------------------------------------

-- Prices are Auctionator's last scan price. We keep our own copy (db.prices)
-- so a price stays available when Auctionator has none for an item.
local function GetPrice(itemID)
	local key = tostring(itemID)
	local adb = Auctionator and Auctionator.Database and Auctionator.Database.db
	local live = adb and adb[key]
	if type(live) == "table" and live.m and live.m > 0 then
		db.prices[key] = { m = live.m }
	end

	local entry = db.prices[key]
	if entry and entry.m and entry.m > 0 then return entry.m end
end

---------------------------------------------------------------------------
-- Value computation
---------------------------------------------------------------------------

local function FindBucket(classID, quality, bracket)
	local exact = db.buckets[Key(classID, quality, bracket)]
	if exact and exact.n > 0 then return exact, false end

	local best, bestDist, bestBracket
	local prefix = classID .. ":" .. quality .. ":"
	for k, rec in pairs(db.buckets) do
		if rec.n > 0 and k:sub(1, #prefix) == prefix then
			local b = tonumber(k:sub(#prefix + 1))
			local dist = b and math.abs(b - bracket)
			if dist and dist <= MAX_BRACKET_DISTANCE * BRACKET_SIZE
				and (not bestDist or dist < bestDist or (dist == bestDist and b < bestBracket)) then
				best, bestDist, bestBracket = rec, dist, b
			end
		end
	end
	return best, best ~= nil
end

-- Returns value (copper), sampleCount, isApproximate, isPartial
function ns.GetDisenchantValue(link)
	local classID, quality, bracket = Classify(link)
	if not classID then return end
	local rec, approx = FindBucket(classID, quality, bracket)
	if not rec then return end

	local total, partial = 0, false
	for itemID, qty in pairs(rec.items) do
		local price = GetPrice(itemID)
		if price then
			total = total + (qty / rec.n) * price
		else
			partial = true
		end
	end
	return math.floor(total), rec.n, approx, partial
end

---------------------------------------------------------------------------
-- Tooltip
---------------------------------------------------------------------------

-- Expected value (copper) of the era table for this item, or nil if not covered.
function ns.GetEraValue(link)
	local classID, quality, _, ilvl = Classify(link)
	if not classID then return end
	local rows = ERA[classID] and ERA[classID][quality]
	if not rows then return end
	for _, row in ipairs(rows) do
		if ilvl >= row[1] and ilvl <= row[2] then
			local total, partial = 0, false
			for i = 3, #row do
				local chance, minQty, maxQty, itemID = unpack(row[i])
				local price = GetPrice(itemID)
				if price then
					total = total + (chance / 100) * ((minQty + maxQty) / 2) * price
				else
					partial = true
				end
			end
			return math.floor(total), partial
		end
	end
end

-- Expected disenchant value in copper: the average worth of what the item
-- disenchants into, from the disenchant table, with every possible result
-- weighted by its chance and average quantity and priced at its latest
-- auction house scan price. Your own disenchant results are not used here
-- (they are still recorded, see /dv stats). Used by the tooltip, the disenchant
-- button and the auction house scanner.
function ns.GetExpectedValue(link)
	if not db or not link then return end
	local era = ns.GetEraValue(link)
	if era and era > 0 then return era end
end

-- Public API for other addons (Auctionator's "DE Value" column uses it).
-- Accepts an item link or item ID. Returns the learned value when there are
-- samples, otherwise the era table value; nil if not disenchantable or unpriced.
DisenchantValueAPI = {
	GetValue = function(item)
		if not db or not item then return end
		local value = ns.GetDisenchantValue(item)
		if not value or value <= 0 then
			value = ns.GetEraValue(item)
		end
		if value and value > 0 then return value end
	end,
	-- Disenchant table value only (the tooltip's "Disenchant value").
	GetEraValue = function(item)
		if not db or not item then return end
		local value = ns.GetEraValue(item)
		if value and value > 0 then return value end
	end,
}

-- Coin icons like Auctionator's tooltip lines: "3 [silver] 77 [copper]".
-- Built by hand so it does not depend on any particular client function.
-- Every denomination below the largest one is shown, even when it is 0:
-- "1 [gold] 0 [silver] 0 [copper]", "1 [silver] 0 [copper]".
local COIN_ICON = "|TInterface\\MoneyFrame\\UI-%sIcon:14:14:2:0|t"

local function CoinString(copper)
	copper = math.floor(copper)
	local g = math.floor(copper / 10000)
	local s = math.floor((copper % 10000) / 100)
	local c = copper % 100
	local parts = {}
	if g > 0 then
		parts[#parts + 1] = (BreakUpLargeNumbers and BreakUpLargeNumbers(g) or tostring(g)) .. COIN_ICON:format("Gold")
	end
	if s > 0 or #parts > 0 then parts[#parts + 1] = s .. COIN_ICON:format("Silver") end
	parts[#parts + 1] = c .. COIN_ICON:format("Copper")
	return table.concat(parts, " ")
end

ns.CoinString = CoinString

local function FormatMoney(value, approx, partial)
	local text = value > 0 and CoinString(value) or "?"
	if approx then text = "~" .. text end
	if partial then text = text .. "*" end
	return WHITE_FONT_COLOR:WrapTextInColorCode(text)
end

local function AddTooltipLine(tooltip, link)
	if not db or not link then return end

	-- The same value as the auction house scanner's "DE value" column.
	local value, partial = ns.GetEraValue(link)
	if not value then return end -- not a disenchantable item (uncommon/rare/epic weapon or armor)

	tooltip:AddDoubleLine("Disenchant value:", FormatMoney(value, false, partial))
end

local function OnTooltipItem(tooltip, data)
	if tooltip.IsForbidden and tooltip:IsForbidden() then return end
	local link
	if tooltip.GetItem then
		local _, l = tooltip:GetItem()
		link = l
	end
	link = link or (data and data.hyperlink)
	AddTooltipLine(tooltip, link)
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnTooltipItem)
else
	for _, name in ipairs({ "GameTooltip", "ItemRefTooltip", "ShoppingTooltip1", "ShoppingTooltip2" }) do
		local tt = _G[name]
		if tt and tt.HookScript then
			tt:HookScript("OnTooltipSetItem", function(self)
				local _, link = self:GetItem()
				AddTooltipLine(self, link)
			end)
		end
	end
end

---------------------------------------------------------------------------
-- Learning from disenchants
---------------------------------------------------------------------------

local lastClicked -- { link=, time= } most recent bag item "used" (the DE target click)
local pending     -- { link=, time= } a disenchant cast in progress

-- Called by the disenchant button so its casts are learned like manual ones
-- (a macro's /use does not go through the container hook below).
function ns.NoteTarget(link)
	lastClicked = link and { link = link, time = GetTime() } or nil
end

local function RememberClick(bag, slot)
	local link = C_Container and C_Container.GetContainerItemLink(bag, slot)
	lastClicked = link and { link = link, time = GetTime() } or nil
end

if C_Container and C_Container.UseContainerItem then
	hooksecurefunc(C_Container, "UseContainerItem", RememberClick)
end
if _G.UseContainerItem then
	hooksecurefunc("UseContainerItem", RememberClick)
end

local function Record(link)
	local classID, quality, bracket = Classify(link)
	if not classID then return end

	local drops = {}
	local any = false
	for i = 1, GetNumLootItems() do
		local slotLink = GetLootSlotLink(i)
		if slotLink then
			local itemID = C_Item.GetItemInfoInstant(slotLink)
			local _, _, qty = GetLootSlotInfo(i)
			if itemID then
				drops[itemID] = (drops[itemID] or 0) + (qty or 1)
				any = true
			end
		end
	end
	if not any then return end

	local k = Key(classID, quality, bracket)
	local rec = db.buckets[k]
	if not rec then
		rec = { n = 0, items = {} }
		db.buckets[k] = rec
	end
	rec.n = rec.n + 1
	for itemID, qty in pairs(drops) do
		rec.items[itemID] = (rec.items[itemID] or 0) + qty
	end
end


local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("UNIT_SPELLCAST_SENT")
frame:RegisterEvent("UNIT_SPELLCAST_FAILED")
frame:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
frame:RegisterEvent("LOOT_OPENED")

frame:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		if (...) ~= ADDON then return end
		DisenchantValueDB = DisenchantValueDB or {}
		db = DisenchantValueDB
		db.buckets = db.buckets or {}
		db.prices = db.prices or {}
		frame:UnregisterEvent("ADDON_LOADED")

		-- Leftovers from the saved-variables workaround, no longer used.
		db.log, db.probeMarker, db.probeWritten, db.probeSmall, db.probeLarge = nil, nil, nil, nil, nil
		-- Leftovers from the "mean" price mode and its per-day price history, no longer used.
		db.priceMode = nil
		for key, entry in pairs(db.prices) do
			db.prices[key] = { m = entry.m }
		end

	elseif event == "UNIT_SPELLCAST_SENT" then
		local unit, target, _, spellID = ...
		if unit ~= "player" or spellID ~= DISENCHANT_SPELL_ID then return end
		pending = nil
		if lastClicked and GetTime() - lastClicked.time < 2 then
			local name = C_Item.GetItemInfo(lastClicked.link)
			if not (name and target and target ~= "" and name ~= target) then
				pending = { link = lastClicked.link, time = GetTime() }
			end
		end

	elseif event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED" then
		local unit, _, spellID = ...
		if unit == "player" and spellID == DISENCHANT_SPELL_ID then pending = nil end

	elseif event == "LOOT_OPENED" then
		if pending and GetTime() - pending.time < PENDING_TIMEOUT then
			Record(pending.link)
		end
		pending = nil
	end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

SLASH_DISENCHANTVALUE1 = "/dv"
SLASH_DISENCHANTVALUE2 = "/disenchantvalue"
SlashCmdList["DISENCHANTVALUE"] = function(msg)
	local cmd = (msg or ""):lower():match("^(%S*)")
	if cmd == "reset" then
		wipe(db.buckets)
		Print("learned data cleared")
	elseif cmd == "debug" then
		local adb = Auctionator and Auctionator.Database and Auctionator.Database.db
		local n = 0
		if adb then for _ in pairs(adb) do n = n + 1 end end
		Print(("Auctionator loaded: %s, database: %s, items in db: %d"):format(
			tostring(Auctionator ~= nil), tostring(adb ~= nil), n))
		for _, id in ipairs(ERA_MATERIALS) do
			local latest = Auctionator and Auctionator.API and Auctionator.API.v1
				and Auctionator.API.v1.GetAuctionPriceByItemID(CALLER_ID, id)
			Print(("item %d: latest=%s"):format(id, tostring(latest)))
		end
	elseif cmd == "stats" then
		local buckets, casts = 0, 0
		for _, rec in pairs(db.buckets) do
			buckets = buckets + 1
			casts = casts + rec.n
		end
		Print(("%d disenchants recorded in %d buckets"):format(casts, buckets))
	elseif ns.ButtonSlash and ns.ButtonSlash(msg) then
		-- handled by the disenchant button (button, list, ignore, unignore, ahcheck)
	elseif ns.AuctionSlash and ns.AuctionSlash(msg) then
		-- handled by the auction house scanner (ah)
	else
		Print("/dv stats | /dv reset | /dv ah")
		Print("/dv button | /dv list | /dv ignore [link] | /dv unignore [link] | /dv ahcheck on|off | /dv attach on|off")
	end
end
