--[[
DisenchantValue
---------------
Adds a tooltip line with the expected disenchant value of weapons/armor.

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

local MAX_ILVL = 30

local function IsDisenchantable(classID, quality)
  return (classID == ITEMCLASS_WEAPON or classID == ITEMCLASS_ARMOR)
    and quality and quality >= 2 and quality <= 3 -- uncommon and rare only
end

---------------------------------------------------------------------------
-- Era (Vanilla) disenchant table, item level 1-30, uncommon and rare.
-- Source: https://warcraft.wiki.gg/wiki/Disenchanting_tables
-- Rows: { minIlvl, maxIlvl, { chance%, minQty, maxQty, itemID }, ... }
---------------------------------------------------------------------------

local STRANGE_DUST, SOUL_DUST = 10940, 11083
local LESSER_MAGIC, GREATER_MAGIC = 10938, 10939
local LESSER_ASTRAL, GREATER_ASTRAL = 10998, 11082
local SMALL_GLIMMERING, LARGE_GLIMMERING = 10978, 11084

local ERA = {
  [ITEMCLASS_ARMOR] = {
    [2] = {
      { 1, 15, { 80, 1, 2, STRANGE_DUST }, { 20, 1, 2, LESSER_MAGIC } },
      { 16, 20, { 75, 2, 3, STRANGE_DUST }, { 20, 1, 2, GREATER_MAGIC }, { 5, 1, 1, SMALL_GLIMMERING } },
      { 21, 25, { 75, 4, 6, STRANGE_DUST }, { 15, 1, 2, LESSER_ASTRAL }, { 10, 1, 1, SMALL_GLIMMERING } },
      { 26, 30, { 75, 1, 2, SOUL_DUST }, { 20, 1, 2, GREATER_ASTRAL }, { 5, 1, 1, LARGE_GLIMMERING } },
    },
  },
  [ITEMCLASS_WEAPON] = {
    [2] = {
      { 1, 15, { 20, 1, 2, STRANGE_DUST }, { 80, 1, 2, LESSER_MAGIC } },
      { 16, 20, { 20, 2, 3, STRANGE_DUST }, { 75, 1, 2, GREATER_MAGIC }, { 5, 1, 1, SMALL_GLIMMERING } },
      { 21, 25, { 15, 4, 6, STRANGE_DUST }, { 75, 1, 2, LESSER_ASTRAL }, { 10, 1, 1, SMALL_GLIMMERING } },
      { 26, 30, { 20, 1, 2, SOUL_DUST }, { 75, 1, 2, GREATER_ASTRAL }, { 5, 1, 1, LARGE_GLIMMERING } },
    },
  },
}
-- Rare items give a guaranteed shard, the same for armor and weapons.
local ERA_RARE = {
  { 1, 25, { 100, 1, 1, SMALL_GLIMMERING } },
  { 26, 30, { 100, 1, 1, LARGE_GLIMMERING } },
}
ERA[ITEMCLASS_ARMOR][3] = ERA_RARE
ERA[ITEMCLASS_WEAPON][3] = ERA_RARE

-- Returns classID, quality, bracket for an item link, or nil if not disenchantable.
local function Classify(link)
  if not link then return end
  local _, _, quality, _, _, _, _, _, _, _, _, classID = C_Item.GetItemInfo(link)
  if not classID then return end
  if not IsDisenchantable(classID, quality) then return end
  local ilvl = GetItemLevel(link)
  if not ilvl or ilvl <= 0 or ilvl > MAX_ILVL then return end
  return classID, quality, BracketFor(ilvl), ilvl
end

local function Key(classID, quality, bracket)
  return classID .. ":" .. quality .. ":" .. bracket
end

---------------------------------------------------------------------------
-- Prices (Auctionator)
---------------------------------------------------------------------------

-- This client currently loses Auctionator's saved price database on every
-- reload, so keep our own copy of the prices we use. Whenever Auctionator has
-- fresh data for an item it is merged into db.prices (per day: lowest and
-- highest price seen), and all lookups read from that copy.
local KEEP_DAYS = 30

local function ScanDays()
  local days, today
  pcall(function()
    days = Auctionator.Config.Get(Auctionator.Config.Options.AUCTION_MEAN_DAYS_LIMIT)
    today = math.floor((time() - Auctionator.Constants.SCAN_DAY_0) / 86400)
  end)
  return days, today
end

local function GetEntry(itemID)
  local key = tostring(itemID)
  local entry = db.prices[key]

  local adb = Auctionator and Auctionator.Database and Auctionator.Database.db
  local live = adb and adb[key]
  if type(live) == "table" and type(live.h) == "table" and live.m and live.m > 0 then
    if not entry then
      entry = { m = 0, h = {}, l = {} }
      db.prices[key] = entry
    end
    entry.m = live.m
    local function Observe(day, value)
      if not value then return end
      entry.h[day] = math.max(entry.h[day] or value, value)
      entry.l[day] = math.min(entry.l[day] or value, value)
    end
    for day, v in pairs(live.h) do Observe(day, v) end
    for day, v in pairs(live.l or {}) do Observe(day, v) end

    local _, today = ScanDays()
    if today then
      for day in pairs(entry.h) do
        local d = tonumber(day)
        if d and d <= today - KEEP_DAYS then entry.h[day], entry.l[day] = nil, nil end
      end
    end
  end
  return entry
end

-- Mean of the stored daily prices over Auctionator's "mean days" window.
-- (Auctionator's own GetMeanPrice ignores days with a single scan.)
-- Per day: the midpoint of the lowest and highest price seen that day.
function ns.HistoryMean(itemID)
  local entry = GetEntry(itemID)
  if not entry then return end

  local days, today = ScanDays()
  local total, count = 0, 0
  for day, high in pairs(entry.h) do
    local d = tonumber(day)
    if d and (not (days and today) or (d > today - days and d <= today)) then
      total = total + ((entry.l[day] or high) + high) / 2
      count = count + 1
    end
  end
  if count > 0 then return math.floor(total / count) end
end

local function GetPrice(itemID)
  if db.priceMode == "mean" then
    local mean = ns.HistoryMean(itemID)
    if mean and mean > 0 then return mean end
  end

  local entry = GetEntry(itemID)
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
  -- Era disenchant table value only (the tooltip's "Disenchant value (era)").
  GetEraValue = function(item)
    if not db or not item then return end
    local value = ns.GetEraValue(item)
    if value and value > 0 then return value end
  end,
}

-- Coin icons like Auctionator's tooltip lines: "3 [silver] 77 [copper]".
-- Built by hand so it does not depend on any particular client function.
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
  if s > 0 then parts[#parts + 1] = s .. COIN_ICON:format("Silver") end
  if c > 0 or #parts == 0 then parts[#parts + 1] = c .. COIN_ICON:format("Copper") end
  return table.concat(parts, " ")
end

local function FormatMoney(value, approx, partial)
  local text = value > 0 and CoinString(value) or "?"
  if approx then text = "~" .. text end
  if partial then text = text .. "*" end
  return WHITE_FONT_COLOR:WrapTextInColorCode(text)
end

local function AddTooltipLine(tooltip, link)
  if not db or not link then return end

  -- Actual item level for any weapon or armor, unless the tooltip already shows it.
  local classID = select(6, C_Item.GetItemInfoInstant(link))
  if classID == ITEMCLASS_WEAPON or classID == ITEMCLASS_ARMOR then
    local ilvl = GetItemLevel(link)
    if ilvl and ilvl > 0 then
      local pattern = ((ITEM_LEVEL or "Item Level %d"):gsub("%%d", "%%d+"))
      local found = false
      for i = 2, tooltip:NumLines() do
        local fs = tooltip["TextLeft" .. i]
        local text = fs and fs:GetText()
        if text and text:find(pattern) then found = true break end
      end
      if not found then
        tooltip:AddDoubleLine("Item level:", WHITE_FONT_COLOR:WrapTextInColorCode(tostring(ilvl)))
      end
    end
  end

  local eraValue, eraPartial = ns.GetEraValue(link)
  if not eraValue then return end -- not a covered item (1-30, uncommon/rare weapon or armor)

  tooltip:AddDoubleLine("Disenchant value (era):", FormatMoney(eraValue, false, eraPartial))

  local value, samples, approx, partial = ns.GetDisenchantValue(link)
  if value then
    tooltip:AddDoubleLine("Actual:", FormatMoney(value, approx, partial) ..
      GRAY_FONT_COLOR:WrapTextInColorCode(" (" .. samples .. ")"))
  else
    tooltip:AddDoubleLine("Actual:", GRAY_FONT_COLOR:WrapTextInColorCode("no data yet"))
  end
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


---------------------------------------------------------------------------
-- Hex wrapper for Auctionator's binary price strings (see ADDON_LOADED)
---------------------------------------------------------------------------

local HEX_TAG = "DVHEX:"

local function ToHex(str)
  return (str:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function FromHex(hex)
  return (hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end

-- Runs at logout, after Auctionator has serialized its database into a binary string.
local function EncodeAuctionatorStrings()
  local sv = _G.AUCTIONATOR_PRICE_DATABASE
  if type(sv) ~= "table" then return end
  for k, v in pairs(sv) do
    if type(v) == "string" and v:sub(1, #HEX_TAG) ~= HEX_TAG then
      sv[k] = HEX_TAG .. ToHex(v)
    end
  end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("UNIT_SPELLCAST_SENT")
frame:RegisterEvent("UNIT_SPELLCAST_FAILED")
frame:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("PLAYER_LOGIN")

frame:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" then
    if (...) ~= ADDON then return end
    DisenchantValueDB = DisenchantValueDB or {}
    db = DisenchantValueDB
    db.buckets = db.buckets or {}
    db.prices = db.prices or {}
    for key, seed in pairs(_G.DV_SEED or {}) do
      if not db.prices[key] then db.prices[key] = seed end
    end

    -- Persistence experiment: what does this client keep in a saved-variables
    -- file? Compare what the previous session wrote with what we got back.
    local function Len(v) return type(v) == "string" and #v or type(v) end
    if db.probeWritten then
      ns.probeReport = ("previous save: marker=%s, small binary=%s, large binary=%s, learned buckets kept=%s"):format(
        tostring(db.probeMarker), Len(db.probeSmall), Len(db.probeLarge), tostring(next(db.buckets) ~= nil))
    else
      ns.probeReport = "persistence probe not written yet (log out once, then check again)"
    end

    -- Record what the game handed over at login, so it can be read from this
    -- addon's saved file after the next logout.
    local parts = {}
    for _, name in ipairs({ "AUCTIONATOR_PRICE_DATABASE", "AUCTIONATOR_POSTING_HISTORY",
      "AUCTIONATOR_VENDOR_PRICE_CACHE", "AUCTIONATOR_CONFIG", "AUCTIONATOR_SAVEDVARS" }) do
      local v = _G[name]
      local n = 0
      if type(v) == "table" then for _ in pairs(v) do n = n + 1 end end
      parts[#parts + 1] = ("%s=%s(%d)"):format(name:gsub("AUCTIONATOR_", ""), type(v), n)
    end
    local sv = _G.AUCTIONATOR_PRICE_DATABASE
    if type(sv) == "table" then
      for k, v in pairs(sv) do
        if k ~= "__dbversion" then
          parts[#parts + 1] = ("realm %s=%s"):format(tostring(k), type(v) == "string" and ("string:" .. #v) or type(v))
        end
      end
    end
    db.log = db.log or {}
    local entry = { time = date("%Y-%m-%d %H:%M:%S"), hexDecoded = ns.decodedCount, probe = ns.probeReport, atSavedVarsLoad = table.concat(parts, "; ") }
    table.insert(db.log, 1, entry)
    while #db.log > 6 do table.remove(db.log) end
    C_Timer.After(5, function()
      local adb = Auctionator and Auctionator.Database and Auctionator.Database.db
      local n = 0
      if adb then for _ in pairs(adb) do n = n + 1 end end
      entry.auctionatorItemsAfterLogin = n
    end)
    db.priceMode = db.priceMode or "mean"
    frame:UnregisterEvent("ADDON_LOADED")

    -- WORKAROUND: this client discards a whole saved-variables file when it
    -- contains Auctionator's binary price string. We store that string as hex
    -- text (see EncodeAuctionatorStrings) and turn it back here, before
    -- Auctionator reads it at PLAYER_LOGIN.
    ns.decodedCount = 0
    if type(_G.AUCTIONATOR_PRICE_DATABASE) == "table" then
      for k, v in pairs(_G.AUCTIONATOR_PRICE_DATABASE) do
        if type(v) == "string" and v:sub(1, #HEX_TAG) == HEX_TAG then
          _G.AUCTIONATOR_PRICE_DATABASE[k] = FromHex(v:sub(#HEX_TAG + 1))
          ns.decodedCount = ns.decodedCount + 1
        end
      end
    end

    -- Auctionator only deserializes its price data at PLAYER_LOGIN, so at this
    -- point the raw saved string is still there. Keep it for /dv debug.
    local sv = _G.AUCTIONATOR_PRICE_DATABASE
    if type(sv) == "table" then
      for k, v in pairs(sv) do
        if type(v) == "string" then ns.rawKey, ns.raw = k, v end
      end
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

  elseif event == "PLAYER_LOGIN" then
    -- Registered now so our logout handler runs after Auctionator's own.
    local late = CreateFrame("Frame")
    late:RegisterEvent("PLAYER_LOGOUT")
    late:SetScript("OnEvent", EncodeAuctionatorStrings)

  elseif event == "PLAYER_LOGOUT" then
    if db then
      db.probeMarker = "ascii-ok"
      db.probeWritten = true
      db.probeSmall, db.probeLarge = nil, nil
    end

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
  if cmd == "mean" or cmd == "latest" then
    db.priceMode = cmd
    Print("price mode: " .. cmd)
  elseif cmd == "reset" then
    wipe(db.buckets)
    Print("learned data cleared")
  elseif cmd == "debug" then
    local adb = Auctionator and Auctionator.Database and Auctionator.Database.db
    local n = 0
    if adb then for _ in pairs(adb) do n = n + 1 end end
    Print(("Auctionator loaded: %s, database: %s, items in db: %d"):format(
      tostring(Auctionator ~= nil), tostring(adb ~= nil), n))
    for _, id in ipairs({ 10940, 10938, 10939, 10978, 11084, 11083, 10998, 11082 }) do
      local latest = Auctionator and Auctionator.API and Auctionator.API.v1
        and Auctionator.API.v1.GetAuctionPriceByItemID(CALLER_ID, id)
      Print(("item %d: latest=%s mean=%s"):format(id, tostring(latest), tostring((ns.HistoryMean(id)))))
    end

    -- Was the saved price data readable when the game handed it to Auctionator?
    Print("Auctionator realm key: " .. tostring(Auctionator and Auctionator.State and Auctionator.State.CurrentRealm))
    local sv = _G.AUCTIONATOR_PRICE_DATABASE
    if type(sv) == "table" then
      for k, v in pairs(sv) do
        Print(("saved variable entry %s: %s%s"):format(tostring(k), type(v), type(v) == "string" and (" len " .. #v) or ""))
      end
    end
    if ns.raw then
      local ok, res = pcall(C_EncodingUtil.DeserializeCBOR, ns.raw)
      local cnt = 0
      if ok and type(res) == "table" then for _ in pairs(res) do cnt = cnt + 1 end end
      Print(("raw string captured at load: key=%s len=%d, deserialize ok=%s, entries=%d, result=%s"):format(
        tostring(ns.rawKey), #ns.raw, tostring(ok), cnt, ok and type(res) or tostring(res)))
    else
      Print("no serialized price string was present at addon load")
    end
    Print(ns.probeReport or "no persistence report yet")
  elseif cmd == "stats" then
    local buckets, casts = 0, 0
    for _, rec in pairs(db.buckets) do
      buckets = buckets + 1
      casts = casts + rec.n
    end
    Print(("%d disenchants recorded in %d buckets, price mode: %s"):format(casts, buckets, db.priceMode))
  elseif ns.ButtonSlash and ns.ButtonSlash(msg) then
    -- handled by the disenchant button (button, list, ignore, unignore, ahcheck)
  else
    Print("/dv stats | /dv mean | /dv latest | /dv reset")
    Print("/dv button | /dv list | /dv ignore [link] | /dv unignore [link] | /dv ahcheck on|off | /dv attach on|off")
    Print("mean = Auctionator average over its mean-days setting, latest = most recent scan price")
  end
end
