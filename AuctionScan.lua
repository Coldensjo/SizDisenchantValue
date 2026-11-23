--[[
Auction house scanner
---------------------
A "Disenchant Deals" panel next to the auction house window. It searches the
auction house for uncommon, rare and epic weapons and armor, prices each item
by its expected disenchant value and shows them in a sortable list.

	* The "Disenchant" tab under the auction house shows or hides the panel.
	* Scan: one browse search for all weapons and armor (uncommon or better).
		The auction house groups the results per item, with the lowest buyout.
	* Click a column header to sort by it; click it again to reverse the order.
	* Bracket buttons filter by disenchant item level bracket (none ticked shows all).
	* Click a row to buy the cheapest one at once, with no prompt (quick buy).
		The row then shows the next cheapest; a price rise must be confirmed.
	* Right-click a row to open that item in the auction house's own buy view.
	* Shift-click a row to link the item in chat.
	* DE value is what the materials sell for after the 5% auction house cut
		(/dv ahcut off for the full price); profit is DE value less the buyout.
		A gray DE value uses a saved price: Auctionator has no current one.
	* Drag the panel by its title or any empty spot to move it anywhere on the
		screen; the title-bar reset button or /dv ahreset puts it back beside the
		auction house. The position is saved in DisenchantValueDB.ahPanelPos.
	* The title-bar minimize button (or /dv min) collapses it to the title bar
		so it does not cover the auction house. The panel stays shown, a scan
		keeps running, and results keep updating; restore shows the current
		list. This is not the same as the Disenchant tab, /dv deals, or close,
		which hide the window and stop a scan. Minimized state is saved.
	* The panel always draws on top of the auction house and Auctionator.

Uses the modern auction house API (C_AuctionHouse).

Slash commands: /dv deals or /dv ah (turn the panel on or off), /dv min
(collapse to the title bar or restore), /dv ahreset (back beside the auction
house, normal size), /dv ahscale 0.5-1.5 (panel size)
]]

local _, ns = ...

local ITEMCLASS_WEAPON = (Enum and Enum.ItemClass and Enum.ItemClass.Weapon) or 2
local ITEMCLASS_ARMOR = (Enum and Enum.ItemClass and Enum.ItemClass.Armor) or 4
local ROW_HEIGHT = 20

local function DB() return _G.DisenchantValueDB end

local function Print(msg)
	print("|cff33ff99DisenchantValue|r: " .. msg)
end

-- Index into ns.DISENCHANT_BRACKETS for an item level.
local function BracketIndex(ilvl)
	for i, b in ipairs(ns.DISENCHANT_BRACKETS) do
		if ilvl >= b.min and ilvl <= b.max then return i end
	end
end

---------------------------------------------------------------------------
-- Results
---------------------------------------------------------------------------

-- One entry per browse result:
-- { browse, itemKey, itemID, link, name, displayName, quality, ilvl, bracket, quantity, buyout, value, stale, profit }
local results = {}
local seen = {}       -- browse result key -> entry, so repeated events do not add duplicates
local sortKey, sortDesc = "profit", true
local onlyProfitable = false
local brackets = {}   -- bracket index -> true for the brackets shown; none ticked shows all
local view = {}       -- results after filtering, in display order

local function ResultKey(itemKey)
	return ("%d:%d:%d"):format(itemKey.itemID or 0, itemKey.itemLevel or 0, itemKey.itemSuffix or 0)
end

-- The name as the auction house shows it, with the random suffix ("of the
-- Eagle"): each suffix is its own browse result, so without it rows look like
-- duplicates. False while the item key data is not loaded yet
-- (ITEM_KEY_ITEM_INFO_RECEIVED arrives later).
local function ResolveName(r)
	if r.displayName then return true end
	local info = C_AuctionHouse.GetItemKeyInfo(r.itemKey)
	if not info then return false end
	r.name = info.itemName or r.name
	if AuctionHouseUtil and AuctionHouseUtil.GetItemDisplayTextFromItemKey then
		-- true: leave out the "(item level)" the browse list adds; we have a column for it.
		r.displayName = AuctionHouseUtil.GetItemDisplayTextFromItemKey(r.itemKey, info, true)
	else
		r.displayName = info.itemName
	end
	return true
end

-- Fills in link and value; false while the item data is not cached yet.
local function Evaluate(r)
	if not r.link then
		local name, link, quality = C_Item.GetItemInfo(r.itemID)
		if not link then
			if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(r.itemID) end
			return false
		end
		r.name, r.link, r.quality = r.name or name, link, quality
	end
	-- value is after the auction house cut, so profit is what reselling the materials nets.
	if ns.GetExpectedValue then
		r.value, r.stale = ns.GetExpectedValue(r.link)
	else
		r.value, r.stale = nil, nil
	end
	r.profit = r.value and r.buyout and (r.value - r.buyout) or nil
	return true
end

local function Compare(a, b)
	local x, y = a[sortKey], b[sortKey]
	if x == y then return (a.buyout or 0) < (b.buyout or 0) end
	-- Missing values (unpriced items) always go last.
	if x == nil then return false end
	if y == nil then return true end
	if sortDesc then return x > y end
	return x < y
end

local Update -- forward declaration, defined with the panel
local UpdateTitle -- title-bar text while minimized; defined with the panel

local function Rebuild()
	wipe(view)
	local anyBracket = next(brackets) ~= nil
	for _, r in ipairs(results) do
		if r.value and (not onlyProfitable or r.priceUp or (r.profit and r.profit > 0))
			and (not anyBracket or brackets[r.bracket]) then
			view[#view + 1] = r
		end
	end
	table.sort(view, Compare)
	if Update then Update() end
	if UpdateTitle then UpdateTitle() end
end

local rebuildQueued = false
local function QueueRebuild()
	if rebuildQueued then return end
	rebuildQueued = true
	C_Timer.After(0.2, function()
		rebuildQueued = false
		Rebuild()
	end)
end

local function AddResults(list)
	for _, b in ipairs(list or {}) do
		local itemKey = b.itemKey
		local k = itemKey and ResultKey(itemKey)
		if k and not seen[k] then
			local r = {
				browse = b,
				itemKey = itemKey,
				itemID = itemKey.itemID,
				ilvl = itemKey.itemLevel or 0,
				bracket = BracketIndex(itemKey.itemLevel or 0),
				quantity = b.totalQuantity or 0,
				buyout = (b.minPrice and b.minPrice > 0) and b.minPrice or nil,
			}
			seen[k] = r
			results[#results + 1] = r
			ResolveName(r)
			Evaluate(r)
		end
	end
end

---------------------------------------------------------------------------
-- Scanning
---------------------------------------------------------------------------

local scanning = false -- our search is running; browse results belong to it
local pending          -- "send" or "more": the request waiting for the throttle

local function SetStatus(text)
	if ns.auctionPanel then ns.auctionPanel.status:SetText(text or "") end
	if UpdateTitle then UpdateTitle() end
end

local function UpdateButtons()
	if ns.auctionPanel then ns.auctionPanel:UpdateButtons() end
end

local function StopScan(text)
	scanning, pending = false, nil
	SetStatus(text)
	UpdateButtons()
end

-- Sends the pending request once the auction house accepts one.
local function TrySend()
	if not pending then return end
	if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
		return -- AUCTION_HOUSE_THROTTLED_SYSTEM_READY calls again
	end
	local action = pending
	pending = nil
	if action == "more" then
		C_AuctionHouse.RequestMoreBrowseResults()
		return
	end
	local F = Enum.AuctionHouseFilter
	C_AuctionHouse.SendBrowseQuery({
		searchString = "",
		sorts = {},
		filters = { F.UncommonQuality, F.RareQuality, F.EpicQuality },
		itemClassFilters = { { classID = ITEMCLASS_WEAPON }, { classID = ITEMCLASS_ARMOR } },
	})
end

local function StartScan()
	if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then return end
	wipe(results)
	wipe(seen)
	scanning, pending = true, "send"
	Rebuild()
	SetStatus("Searching...")
	UpdateButtons()
	TrySend()
end

-- More results arrived: ask for the next batch until the list is complete.
local function OnResults(list)
	AddResults(list)
	QueueRebuild()
	if C_AuctionHouse.HasFullBrowseResults() then
		local priced = 0
		for _, r in ipairs(results) do
			if r.value then priced = priced + 1 end
		end
		StopScan(("Scan done: %d disenchantable items listed."):format(priced))
	else
		SetStatus(("Searching... %d items so far"):format(#results))
		pending = "more"
		TrySend()
	end
end

---------------------------------------------------------------------------
-- Quick buy
-- Clicking a row buys the cheapest auction of that item at once, without a
-- prompt. Buying (C_AuctionHouse.PlaceBid) only works inside the click itself,
-- so the cheapest auction is looked up beforehand: when the mouse rests on a
-- row, after a buy (to show the next one) and on a click that finds no
-- lookup yet. A click only ever buys at the exact price the row shows; when a
-- lookup finds a higher price than the list had, the row is marked "price went
-- up" and the next click only confirms the new price, like Auctionator.
---------------------------------------------------------------------------

local OFFER_TTL = 60      -- seconds a looked-up auction is trusted for a buy
local LOOKUP_TIMEOUT = 5  -- seconds to wait for search results before asking again
local LOOKUP_TRIES = 3
local SORT_BY_BUYOUT = { { sortOrder = (Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Buyout) or 4, reverseSort = false } }

local lookup        -- result whose cheapest auction is being looked up
local lookupSent    -- its search query went out
local lookupTries = 0
local lookupToken = 0
local bought = {}   -- auctionID -> true: never offered again after buying it
local hoveredRow    -- the list row under the mouse
local pendingOpen   -- result waiting to be opened in the auction house's buy view

local function Name(r)
	return r.displayName or r.name or "item"
end

local function RemoveResult(r)
	for i, x in ipairs(results) do
		if x == r then
			table.remove(results, i)
			break
		end
	end
	Rebuild()
end

local SendLookup

-- Ask again when a search goes unanswered (the API sometimes drops them).
local function WatchLookup()
	lookupToken = lookupToken + 1
	local token = lookupToken
	C_Timer.After(LOOKUP_TIMEOUT, function()
		if token ~= lookupToken or not (lookup and lookupSent) then return end
		lookupSent = false
		lookupTries = lookupTries + 1
		if lookupTries < LOOKUP_TRIES then
			SendLookup()
		else
			SetStatus("Could not get the current price of " .. Name(lookup) .. ". Click it to try again.")
			lookup = nil
		end
	end)
end

SendLookup = function()
	if not lookup or lookupSent or pendingOpen then return end
	if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
		lookup = nil
		return
	end
	if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
		return -- AUCTION_HOUSE_THROTTLED_SYSTEM_READY calls again
	end
	-- Searches for an item whose key data is not cached are ignored;
	-- ITEM_KEY_ITEM_INFO_RECEIVED calls again.
	if not C_AuctionHouse.GetItemKeyInfo(lookup.itemKey) then return end
	lookupSent = true
	C_AuctionHouse.SendSearchQuery(lookup.itemKey, SORT_BY_BUYOUT, false)
	WatchLookup()
end

local function LookUp(r)
	if lookup == r then return end -- already on its way
	lookup, lookupSent, lookupTries = r, false, 0
	SendLookup()
end

local function OfferReady(r)
	local offer = r.offer
	return offer and GetTime() - offer.at < OFFER_TTL and offer.price == r.buyout
end

local function RefreshTooltip(r)
	if hoveredRow and hoveredRow.result == r and hoveredRow:IsMouseOver() then
		hoveredRow:GetScript("OnEnter")(hoveredRow)
	end
end

-- Search results for the looked-up item: its cheapest auction becomes the offer.
local function OnItemResults(itemKey)
	local r = lookup
	if not (r and lookupSent and type(itemKey) == "table" and ResultKey(itemKey) == ResultKey(r.itemKey)) then return end

	local num = C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0
	-- An empty first answer can be wrong; ask again before calling the item gone.
	if num == 0 and not C_AuctionHouse.HasFullItemSearchResults(itemKey) and lookupTries + 1 < LOOKUP_TRIES then
		lookupSent = false
		lookupTries = lookupTries + 1
		SendLookup()
		return
	end
	lookup, lookupSent = nil, false
	lookupToken = lookupToken + 1

	local best, count = nil, 0
	for i = 1, num do
		local info = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
		if info and info.buyoutAmount and info.buyoutAmount > 0
			and not info.containsOwnerItem and not bought[info.auctionID] then
			count = count + (info.quantity or 1)
			if not best or info.buyoutAmount < best.buyoutAmount then best = info end
		end
	end

	if not best then
		RemoveResult(r)
		SetStatus(Name(r) .. " is no longer listed.")
		return
	end

	local old = r.buyout
	r.buyout = best.buyoutAmount
	r.quantity = count
	r.offer = { auctionID = best.auctionID, price = best.buyoutAmount, at = GetTime() }
	Evaluate(r)
	if old and best.buyoutAmount > old then
		r.priceUp, r.oldPrice = true, old
		SetStatus(("|cffff8000Price went up:|r %s now costs %s (was %s). Click it to confirm the new price.")
			:format(Name(r), ns.CoinString(r.buyout), ns.CoinString(old)))
	else
		SetStatus(("%s: click to buy for %s."):format(Name(r), ns.CoinString(r.buyout)))
	end
	Rebuild()
	RefreshTooltip(r)
end

local function QuickBuy(r)
	if r.priceUp then
		-- The first click after a price rise only confirms the new price.
		r.priceUp, r.oldPrice = nil, nil
		SetStatus(("Price confirmed: click %s again to buy for %s."):format(Name(r), ns.CoinString(r.buyout)))
		Rebuild()
		return
	end
	if not OfferReady(r) then
		SetStatus("Checking the current price of " .. Name(r) .. "...")
		LookUp(r)
		return
	end
	local offer = r.offer
	if GetMoney() < offer.price then
		SetStatus("Not enough gold to buy " .. Name(r) .. ".")
		return
	end
	C_AuctionHouse.PlaceBid(offer.auctionID, offer.price)
	bought[offer.auctionID] = true
	r.offer = nil
	SetStatus(("Bought %s for %s."):format(Name(r), ns.CoinString(offer.price)))
	-- Show the next cheapest one, so a further click never buys at a price the list did not show.
	LookUp(r)
end

-- Look the item up while the mouse rests on its row, so a click can buy at once.
-- Not while the auction house's own buy view is open: our search would
-- replace the one it is showing.
local function BuyViewShown()
	local f = AuctionHouseFrame and AuctionHouseFrame.ItemBuyFrame
	return f and f:IsShown()
end

local function Prefetch(row)
	local r = row.result
	if not r or OfferReady(r) or lookup == r or BuyViewShown() then return end
	C_Timer.After(0.2, function()
		if hoveredRow == row and row.result == r and row:IsMouseOver() then LookUp(r) end
	end)
end

---------------------------------------------------------------------------
-- Opening an item in the auction house's own buy view (right-click)
-- The buy view sends its item search straight away, and the server drops a
-- search that comes too soon after another one; the view then keeps showing
-- the previous item. So the open waits until the auction house accepts a
-- request, and our own price lookup is dropped so it cannot get in between.
---------------------------------------------------------------------------

local function TryOpen()
	local r = pendingOpen
	if not r then return end
	if not (AuctionHouseFrame and AuctionHouseFrame:IsShown() and AuctionHouseFrame.SelectBrowseResult) then
		pendingOpen = nil
		return
	end
	if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
		return -- AUCTION_HOUSE_THROTTLED_SYSTEM_READY calls again
	end
	pendingOpen = nil
	-- The buy view only searches for its item when it is shown. Already open,
	-- it would just swap in the new item and keep the old item's auctions, so
	-- then the search is started here, the way the view itself does it.
	local alreadyOpen = BuyViewShown()
	AuctionHouseFrame:SelectBrowseResult(r.browse)
	if alreadyOpen and AuctionHouseFrame.RefreshSearchResults and AuctionHouseSearchContext then
		AuctionHouseFrame:RefreshSearchResults(AuctionHouseSearchContext.BuyItems, r.itemKey)
	end
end

local function OpenInAuctionHouse(r)
	if not (AuctionHouseFrame and AuctionHouseFrame:IsShown() and AuctionHouseFrame.SelectBrowseResult) then return end
	if scanning then StopScan("Scan stopped.") end
	lookup, lookupSent = nil, false
	lookupToken = lookupToken + 1
	pendingOpen = r
	TryOpen()
end

local driver = CreateFrame("Frame")
driver:RegisterEvent("AUCTION_HOUSE_SHOW")
driver:RegisterEvent("AUCTION_HOUSE_CLOSED")
driver:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
driver:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
driver:RegisterEvent("AUCTION_HOUSE_BROWSE_FAILURE")
driver:RegisterEvent("GET_ITEM_INFO_RECEIVED")
driver:RegisterEvent("ITEM_KEY_ITEM_INFO_RECEIVED")
driver:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
pcall(driver.RegisterEvent, driver, "AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
driver:SetScript("OnEvent", function(_, event, ...)
	if event == "AUCTION_HOUSE_SHOW" then
		-- The auction house UI is load-on-demand; wait a frame so AuctionHouseFrame exists.
		C_Timer.After(0, ns.ShowAuctionPanel)
	elseif event == "AUCTION_HOUSE_CLOSED" then
		if scanning then StopScan() end
		lookup, lookupSent, pendingOpen = nil, false, nil
		if ns.auctionPanel then ns.auctionPanel:Hide() end
	elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
		TryOpen()
		TrySend()
		SendLookup()
	elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
		OnItemResults(...)
	elseif event == "GET_ITEM_INFO_RECEIVED" then
		local itemID = ...
		for _, r in ipairs(results) do
			if r.itemID == itemID and not r.link and Evaluate(r) then QueueRebuild() end
		end
	elseif event == "ITEM_KEY_ITEM_INFO_RECEIVED" then
		local itemID = ...
		for _, r in ipairs(results) do
			if r.itemID == itemID and not r.displayName and ResolveName(r) then QueueRebuild() end
		end
		SendLookup()
	elseif not scanning or pending == "send" then
		-- Browse results from someone else's search (Blizzard UI, Auctionator) are not ours.
		return
	elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
		OnResults(C_AuctionHouse.GetBrowseResults())
	elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
		OnResults(...)
	elseif event == "AUCTION_HOUSE_BROWSE_FAILURE" then
		StopScan("The auction house search failed. Try again.")
	end
end)

---------------------------------------------------------------------------
-- The panel
-- Built from the same Blizzard templates and art as the auction house, so it
-- looks like part of it: a ButtonFrame window, the Browse list's background,
-- column headers with the sort arrow and scroll bar, and a
-- tab under the auction house to show or hide it.
---------------------------------------------------------------------------

local PANEL_WIDTH = 680
-- Title bar only: tall enough for the close, minimize and reset buttons.
local MINIMIZED_HEIGHT = 32
local COLUMNS = {
	{ key = "name", label = "Item", width = 0, justify = "LEFT" }, -- takes the remaining width
	{ key = "ilvl", label = "iLvl", width = 40, justify = "RIGHT" },
	{ key = "quantity", label = "Qty", width = 36, justify = "RIGHT" },
	{ key = "buyout", label = "Lowest price", width = 130, justify = "RIGHT", money = true },
	{ key = "value", label = "DE value", width = 130, justify = "RIGHT", money = true },
	{ key = "profit", label = "Profit", width = 130, justify = "RIGHT", money = true },
}
local COLUMN_GAP = 0 -- headers touch, like the auction house's; cells have CELL_PADDING inside
-- Fonts of the auction house's list (Blizzard_AuctionHouseTableBuilder):
-- item names in Number14FontWhite, numbers and prices in PriceFontWhite.
local NAME_FONT = _G.Number14FontWhite and "Number14FontWhite" or "GameFontHighlight"
local NUMBER_FONT = _G.PriceFontWhite and "PriceFontWhite" or NAME_FONT
local CELL_PADDING = 6
-- Money cells are laid out like the auction house's MoneyDisplayFrame: one
-- slot per coin, 36 pixels apart, right-aligned, so the coins line up whatever
-- the numbers are. Each slot is the number with the coin icon right after it.
local COIN_SLOT = 36
local COIN_ICON_WIDTH = 13 -- the number ends this far left of the slot's right edge

local function CreateMoneyCell(row, right)
	local m = {}
	local x = right
	for _, coin in ipairs({ "Copper", "Silver", "Gold" }) do
		local icon = row:CreateTexture(nil, "ARTWORK")
		icon:SetAtlas("coin-" .. coin:lower())
		icon:SetSize(12, 14)
		icon:SetPoint("RIGHT", row, "LEFT", x, 0)
		local fs = row:CreateFontString(nil, "ARTWORK", NUMBER_FONT)
		fs:SetJustifyH("RIGHT")
		fs:SetWordWrap(false)
		fs:SetPoint("RIGHT", row, "LEFT", x - COIN_ICON_WIDTH, 0)
		m[coin] = { text = fs, icon = icon }
		x = x - COIN_SLOT
	end
	return m
end

-- Fills a money cell: every coin below the largest one is shown, even at 0;
-- a minus sign goes in front of the largest coin.
local function SetMoney(m, copper, r, g, b)
	for _, slot in pairs(m) do
		slot.text:SetText("")
		slot.text:SetTextColor(r or 1, g or 1, b or 1)
		slot.icon:Hide()
	end
	if not copper then
		m.Copper.text:SetText("-")
		return
	end
	local sign = copper < 0 and "-" or ""
	copper = math.floor(math.abs(copper))
	local gold = math.floor(copper / 10000)
	local silver = math.floor((copper % 10000) / 100)
	local function Show(slot, amount)
		slot.text:SetText(amount)
		slot.icon:Show()
	end
	Show(m.Copper, copper % 100)
	if gold > 0 or silver > 0 then Show(m.Silver, silver) end
	if gold > 0 then Show(m.Gold, BreakUpLargeNumbers and BreakUpLargeNumbers(gold) or gold) end
	local top = gold > 0 and m.Gold or silver > 0 and m.Silver or m.Copper
	top.text:SetText(sign .. top.text:GetText())
end

local panel, tab

local function IsPanelWanted()
	local d = DB()
	return not (d and d.ahPanel == false)
end

local function UpdateTab()
	if not tab then return end
	if panel and panel:IsShown() then
		-- SelectTab disables the tab; enable it again so a click can hide the panel.
		PanelTemplates_SelectTab(tab)
		tab:Enable()
	else
		PanelTemplates_DeselectTab(tab)
	end
end

local function SetPanelWanted(wanted)
	local d = DB()
	if d then d.ahPanel = wanted end
	if panel then panel:SetShown(wanted) end
	UpdateTab()
end

---------------------------------------------------------------------------
-- Panel position: beside the auction house until it is dragged somewhere
-- else. A dragged position is saved in DisenchantValueDB.ahPanelPos as the
-- top left corner in UIParent units (from the bottom left of the screen), so
-- it stays put when the panel's scale, the auction house's scale or the UI
-- scale changes. The panel is kept on screen once moved.
---------------------------------------------------------------------------

local MIN_SCALE, MAX_SCALE = 0.5, 1.5

-- Factor from UIParent units to the panel's own units.
local function UIToPanel()
	return UIParent:GetEffectiveScale() / panel:GetEffectiveScale()
end

local function ApplyPosition()
	if not panel then return end
	local d = DB()
	local scale = d and tonumber(d.ahPanelScale) or 1
	panel:SetScale(scale)
	panel:ClearAllPoints()
	local pos = d and d.ahPanelPos
	if pos and pos.ui ~= 1 then
		-- Saved by a test build in the panel's own units: start over beside the auction house.
		d.ahPanelPos, pos = nil, nil
	end
	local minimized = d and d.ahPanelMinimized
	-- Always anchored by the top, so collapsing to the title bar does not jump.
	if pos and pos.x and pos.y then
		local f = UIToPanel()
		panel:SetClampedToScreen(true)
		panel:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos.x * f, pos.y * f)
		if minimized then
			panel:SetHeight(MINIMIZED_HEIGHT)
		else
			-- As tall as the auction house looks on screen, whatever the two scales.
			panel:SetHeight(AuctionHouseFrame:GetHeight() * AuctionHouseFrame:GetEffectiveScale() / panel:GetEffectiveScale())
		end
	elseif minimized then
		-- Same default corner as below, but only the top point, so the height can shrink.
		panel:SetClampedToScreen(false)
		panel:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 0, 0)
		panel:SetHeight(MINIMIZED_HEIGHT)
	else
		-- The original placement: along the auction house's right edge.
		panel:SetClampedToScreen(false)
		panel:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 0, 0)
		panel:SetPoint("BOTTOMLEFT", AuctionHouseFrame, "BOTTOMRIGHT", 0, 0)
	end
end

local function ResetPanelPosition()
	local d = DB()
	if d then d.ahPanelPos, d.ahPanelScale = nil, nil end
	ApplyPosition()
end

local function SavePosition()
	local d = DB()
	local left, top = panel:GetLeft(), panel:GetTop()
	if d and left and top then
		local f = UIToPanel()
		d.ahPanelPos = { x = left / f, y = top / f, ui = 1 }
	end
	ApplyPosition()
end

local function SetScaleSaved(scale)
	local d = DB()
	if not d then return end
	-- The saved corner is in UIParent units, so it stays where it is on screen.
	d.ahPanelScale = (scale ~= 1) and scale or nil
	ApplyPosition()
end

local function SetTitle(frame, text)
	if frame.SetTitle then
		frame:SetTitle(text)
	else
		local fs = frame.TitleText or (frame.TitleContainer and frame.TitleContainer.TitleText)
		if fs then fs:SetText(text) end
	end
end

local function IsMinimized()
	local d = DB()
	return d and d.ahPanelMinimized and true or false
end

local function SolidPaint(tex)
	-- Gold, like the default title text. SetColorTexture on newer clients;
	-- SetTexture(r,g,b,a) is the older solid-colour form.
	if tex.SetColorTexture then
		tex:SetColorTexture(1, 0.82, 0, 1)
	else
		tex:SetTexture(1, 0.82, 0, 1)
	end
end

local function GoldBar(parent, width, height, x, y)
	local tex = parent:CreateTexture(nil, "ARTWORK")
	SolidPaint(tex)
	tex:SetSize(width, height)
	tex:SetPoint("CENTER", x, y)
	return tex
end

-- Reset-position icon: a 12px square target (2px ring + 2px center dot), the
-- same stroke and gold as the minus/plus, pixel-aligned in a 20px button.
local function GoldTarget(parent)
	local outer, stroke = 12, 2
	local mid = (outer - stroke) / 2 -- 5: centre of each edge bar
	GoldBar(parent, outer, stroke, 0, mid)
	GoldBar(parent, outer, stroke, 0, -mid)
	GoldBar(parent, stroke, outer - 2 * stroke, -mid, 0)
	GoldBar(parent, stroke, outer - 2 * stroke, mid, 0)
	return GoldBar(parent, stroke, stroke, 0, 0)
end

local TITLE_BTN_SIZE, TITLE_BTN_GAP = 20, 2

-- ButtonFrameTemplate / PortraitFrameTemplate regions, and what happens
-- when the window is collapsed to MINIMIZED_HEIGHT (32px):
--   NineSlice (TopLeftCorner, TopRightCorner, BottomLeftCorner,
--     BottomRightCorner, TopEdge, BottomEdge, LeftEdge, RightEdge)
--     HIDE. The corners are larger than a title strip and are drawn slightly
--     outside the frame, so the left edge sticks out above and below the bar
--     and the right edge runs past the close button.
--   TopTileStreaks  HIDE. Title ornament sized for a full window header.
--   Bg              HIDE. Full-window background; the minimized bar paints
--     its own fill so no corner of this texture can poke out.
--   Inset           already always hidden (the list has its own inset).
--     Leave hidden; do not show it again on restore.
--   PortraitContainer, portrait, Portrait
--     already hidden by ButtonFrameTemplate_HidePortrait. Leave hidden.
--   TitleContainer, TitleText, CloseButton, min and reset buttons
--     KEEP. Title and chrome buttons stay on the strip.
--   panel.body (Scan, profitable, brackets, list + its NineSlice and
--     scroll bar, status)  already hidden by SetBodyShown.
--   minChrome (fill + 1px border, all points inside the frame)
--     SHOW while minimized, HIDE on restore so the template looks as before.
local WINDOW_CHROME = { "NineSlice", "TopTileStreaks", "Bg" }

local function PaintRGBA(tex, r, g, b, a)
	if tex.SetColorTexture then
		tex:SetColorTexture(r, g, b, a or 1)
	else
		tex:SetTexture(r, g, b, a or 1)
	end
end

local function EnsureMinChrome()
	if not panel or panel.minChrome then return end
	local chrome = CreateFrame("Frame", nil, panel)
	chrome:SetAllPoints()
	chrome:EnableMouse(false)
	local fill = chrome:CreateTexture(nil, "BACKGROUND")
	-- Dark inner fill, close to the usual button-frame background.
	PaintRGBA(fill, 0.07, 0.06, 0.05, 1)
	fill:SetPoint("TOPLEFT", 1, -1)
	fill:SetPoint("BOTTOMRIGHT", -1, 1)
	-- 1px border fully inside the frame, so nothing draws outside the strip.
	local br, bg, bb = 0.55, 0.45, 0.28
	local top = chrome:CreateTexture(nil, "BORDER")
	PaintRGBA(top, br, bg, bb, 1)
	top:SetPoint("TOPLEFT")
	top:SetPoint("TOPRIGHT")
	top:SetHeight(1)
	local bottom = chrome:CreateTexture(nil, "BORDER")
	PaintRGBA(bottom, br, bg, bb, 1)
	bottom:SetPoint("BOTTOMLEFT")
	bottom:SetPoint("BOTTOMRIGHT")
	bottom:SetHeight(1)
	local left = chrome:CreateTexture(nil, "BORDER")
	PaintRGBA(left, br, bg, bb, 1)
	left:SetPoint("TOPLEFT")
	left:SetPoint("BOTTOMLEFT")
	left:SetWidth(1)
	local right = chrome:CreateTexture(nil, "BORDER")
	PaintRGBA(right, br, bg, bb, 1)
	right:SetPoint("TOPRIGHT")
	right:SetPoint("BOTTOMRIGHT")
	right:SetWidth(1)
	chrome:Hide()
	panel.minChrome = chrome
end

local function SetWindowChromeShown(shown)
	if not panel then return end
	for _, key in ipairs(WINDOW_CHROME) do
		local r = panel[key]
		if r and r.SetShown then r:SetShown(shown) end
	end
	if not shown then EnsureMinChrome() end
	if panel.minChrome then panel.minChrome:SetShown(not shown) end
end

function UpdateTitle()
	if not panel then return end
	if not IsMinimized() then
		SetTitle(panel, "Disenchant Deals")
		return
	end
	if scanning then
		SetTitle(panel, "Disenchant Deals — scanning " .. #results)
	else
		local n = 0
		for _, r in ipairs(results) do
			if r.profit and r.profit > 0 then n = n + 1 end
		end
		if #results > 0 then
			SetTitle(panel, "Disenchant Deals — " .. n .. " profitable")
		else
			SetTitle(panel, "Disenchant Deals")
		end
	end
end

local function SetBodyShown(shown)
	if not (panel and panel.body) then return end
	for _, region in ipairs(panel.body) do
		region:SetShown(shown)
	end
end

local function UpdateMinButton()
	if not (panel and panel.minButton) then return end
	local minimized = IsMinimized()
	if panel.minButton.minus then panel.minButton.minus:SetShown(not minimized) end
	if panel.minButton.plusH then
		panel.minButton.plusH:SetShown(minimized)
		panel.minButton.plusV:SetShown(minimized)
	end
end

-- Collapse to the title bar, or restore the full list. The frame stays shown
-- and a running scan is not stopped (unlike closing or /dv deals).
local function SetMinimized(minimized)
	local d = DB()
	if d then d.ahPanelMinimized = minimized and true or false end
	if not panel then return end
	ApplyPosition()
	SetBodyShown(not IsMinimized())
	SetWindowChromeShown(not IsMinimized())
	UpdateTitle()
	UpdateMinButton()
end

local function InitRow(row, r)
	if not row.cells then
		-- No row stripes: the auction house's Browse list hides them too.
		local hl = row:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAtlas("auctionhouse-ui-row-highlight")
		hl:SetBlendMode("ADD")
		hl:SetAllPoints()

		-- Item icon in the auction house's small icon border, like its item cells.
		row.Icon = row:CreateTexture(nil, "BACKGROUND", nil, 1)
		row.Icon:SetSize(14, 14)
		row.IconBorder = row:CreateTexture(nil, "BACKGROUND", nil, 2)
		row.IconBorder:SetAtlas("auctionhouse-itemicon-small-border")
		row.IconBorder:SetSize(16, 16)

		row.cells = {}
		local x = 0
		for ci, c in ipairs(COLUMNS) do
			if c.money then
				row.cells[ci] = CreateMoneyCell(row, x + c.width - CELL_PADDING)
			else
				local fs = row:CreateFontString(nil, "ARTWORK", ci == 1 and NAME_FONT or NUMBER_FONT)
				fs:SetJustifyH(c.justify)
				fs:SetWordWrap(false)
				if ci == 1 then
					row.Icon:SetPoint("LEFT", CELL_PADDING, 0)
					row.IconBorder:SetPoint("CENTER", row.Icon)
					fs:SetPoint("LEFT", row.Icon, "RIGHT", 4, -1)
					fs:SetWidth(c.width - 14 - 4 - CELL_PADDING)
				else
					fs:SetPoint("LEFT", x, 0)
					fs:SetWidth(c.width - CELL_PADDING)
				end
				row.cells[ci] = fs
			end
			x = x + c.width + COLUMN_GAP
		end

		-- Orange tint for "price went up".
		row.Warn = row:CreateTexture(nil, "BACKGROUND")
		row.Warn:SetAllPoints()
		row.Warn:SetColorTexture(1, 0.5, 0, 0.18)

		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		row:SetScript("OnEnter", function(self)
			hoveredRow = self
			Prefetch(self)
			if not (self.result and self.result.link) then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			local key = self.result.itemKey
			if GameTooltip.SetItemKey and key then
				-- Shows the item with its random suffix stats, like the auction house does.
				GameTooltip:SetItemKey(key.itemID, key.itemLevel, key.itemSuffix)
			else
				GameTooltip:SetHyperlink(self.result.link)
			end
			local res = self.result
			GameTooltip:AddLine(" ")
			if res.priceUp then
				GameTooltip:AddLine(("Price went up from %s to %s."):format(ns.CoinString(res.oldPrice), ns.CoinString(res.buyout)), 1, 0.5, 0)
				GameTooltip:AddLine("Click to confirm the new price.", 1, 1, 1)
			elseif OfferReady(res) then
				GameTooltip:AddLine("Click to buy the cheapest one for " .. ns.CoinString(res.buyout) .. ".", 0.1, 1, 0.1)
			else
				GameTooltip:AddLine("Checking the current price...", 0.7, 0.7, 0.7)
			end
			GameTooltip:AddLine("Right-click to open it in the auction house.", 0.7, 0.7, 0.7)
			if res.stale then
				GameTooltip:AddLine("DE value uses a saved price: Auctionator has no current price for one of its materials.", 0.6, 0.6, 0.6, true)
			end
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", function(self)
			if hoveredRow == self then hoveredRow = nil end
			GameTooltip:Hide()
		end)
		row:SetScript("OnClick", function(self, button)
			local res = self.result
			if not res then return end
			if IsModifiedClick() and res.link and HandleModifiedItemClick(res.link) then return end
			if button == "RightButton" then
				OpenInAuctionHouse(res)
			else
				QuickBuy(res)
			end
		end)
	end

	row.result = r
	row.Icon:SetTexture(C_Item.GetItemIconByID and C_Item.GetItemIconByID(r.itemID) or select(5, C_Item.GetItemInfoInstant(r.itemID)))

	local c = row.cells
	local color = r.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[r.quality]
	-- displayName carries its own quality color code; the color below is for the plain name.
	c[1]:SetText(r.displayName or r.name or "")
	if color then c[1]:SetTextColor(color.r, color.g, color.b) else c[1]:SetTextColor(1, 1, 1) end
	c[2]:SetText(r.ilvl)
	c[3]:SetText(r.quantity)
	row.Warn:SetShown(r.priceUp and true or false)
	if r.priceUp then
		SetMoney(c[4], r.buyout, 1, 0.5, 0)
	else
		SetMoney(c[4], r.buyout)
	end
	if r.stale then
		SetMoney(c[5], r.value, 0.6, 0.6, 0.6)
	else
		SetMoney(c[5], r.value)
	end
	if r.profit and r.profit > 0 then
		SetMoney(c[6], r.profit, 0.1, 1, 0.1)
	elseif r.profit then
		SetMoney(c[6], r.profit, 1, 0.3, 0.3)
	else
		SetMoney(c[6], nil)
	end
end

local function CreateBracketButtons(parent, anchor)
	local function SaveBrackets()
		local d = DB()
		if d then
			d.ahBrackets = {}
			for i in pairs(brackets) do d.ahBrackets[i] = true end
		end
		panel:UpdateBrackets()
		Rebuild()
	end

	-- The auction house's own category button (Weapons, Armor, ...), stretched
	-- to the button's width the way Auctionator does on the modern auction house.
	local function MakeButton(label, width)
		local b = CreateFrame("Button", nil, parent, "AuctionCategoryButtonTemplate")
		b:SetSize(width, 21)
		b:SetText(label)
		b.NormalTexture:ClearAllPoints()
		b.NormalTexture:SetPoint("TOPLEFT")
		b.NormalTexture:SetPoint("BOTTOMRIGHT")
		b.SelectedTexture:ClearAllPoints()
		b.SelectedTexture:SetAllPoints(b.NormalTexture)
		b.HighlightTexture:ClearAllPoints()
		b.HighlightTexture:SetAllPoints(b.NormalTexture)
		if b.Lines then b.Lines:Hide() end
		b.Text:ClearAllPoints()
		b.Text:SetPoint("LEFT", 2, 0)
		b.Text:SetPoint("RIGHT", -2, 0)
		b.Text:SetJustifyH("CENTER")
		return b
	end

	-- Hook instead of replacing OnEnter/OnLeave: the template's own scripts show the hover highlight.
	local function SetTooltip(b, fill)
		b:HookScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			fill()
			GameTooltip:Show()
		end)
		b:HookScript("OnLeave", function() GameTooltip:Hide() end)
	end

	local all = MakeButton("All", 40)
	all:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -8)
	all:SetScript("OnClick", function()
		wipe(brackets)
		SaveBrackets()
	end)
	SetTooltip(all, function()
		GameTooltip:AddLine("Show every disenchant bracket")
	end)

	local list = {}
	local n = #ns.DISENCHANT_BRACKETS
	local width = math.floor((PANEL_WIDTH - 24 - 40 - 2 * n) / n)
	local prev = all
	for i, br in ipairs(ns.DISENCHANT_BRACKETS) do
		local label = br.max >= 999 and (br.min .. "+") or (br.min .. "-" .. br.max)
		local b = MakeButton(label, width)
		b:SetPoint("LEFT", prev, "RIGHT", 2, 0)
		b:SetScript("OnClick", function()
			brackets[i] = not brackets[i] or nil
			SaveBrackets()
		end)
		SetTooltip(b, function()
			GameTooltip:AddLine("Item level " .. label)
			GameTooltip:AddLine("Uncommon items give:", 0.7, 0.7, 0.7)
			local function AddMaterial(itemID, suffix)
				local name = C_Item.GetItemInfo(itemID)
				if not name and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
				GameTooltip:AddLine((name or ("item " .. itemID)) .. (suffix or ""), 1, 1, 1)
			end
			for mi, itemID in ipairs(br.materials) do
				AddMaterial(itemID, (mi == 2 and br.weaponEssence) and " (armor)" or nil)
			end
			if br.weaponEssence then AddMaterial(br.weaponEssence, " (weapons)") end
			GameTooltip:AddLine("Click to show or hide this bracket.", 0.7, 0.7, 0.7)
		end)
		list[i] = b
		prev = b
	end

	-- Selected brackets look like the selected auction house category (blue).
	local function Paint(b, on)
		b.SelectedTexture:SetShown(on and true or false)
		b:SetNormalFontObject(on and GameFontHighlightSmall or GameFontNormalSmall)
	end

	function panel:UpdateBrackets()
		Paint(all, next(brackets) == nil)
		for i, b in ipairs(list) do Paint(b, brackets[i]) end
	end

	panel.bracketButtons = { all }
	for i, b in ipairs(list) do
		panel.bracketButtons[#panel.bracketButtons + 1] = b
	end
end

local function CreateHeaders(parent)
	local x = 0
	for _, c in ipairs(COLUMNS) do
		local h = CreateFrame("Button", nil, parent, "ColumnDisplayButtonShortTemplate")
		h:SetSize(c.width, 19)
		h:SetPoint("TOPLEFT", x, 0)
		h:SetText(c.label)
		-- Like AuctionHouseTableHeaderStringTemplate: text where the template puts
		-- it (left), sort arrow right after it.
		h.Arrow = h:CreateTexture(nil, "OVERLAY")
		h.Arrow:SetAtlas("auctionhouse-ui-sortarrow", true)
		h.Arrow:SetPoint("LEFT", h:GetFontString() or h, "RIGHT", 3, 0)
		h:SetScript("OnClick", function()
			if sortKey == c.key then
				sortDesc = not sortDesc
			else
				sortKey = c.key
				sortDesc = c.key ~= "name" -- numbers start high, names start at A
			end
			Rebuild()
		end)
		c.header = h
		x = x + c.width + COLUMN_GAP
	end
end

local function CreatePanel()
	panel = CreateFrame("Frame", "DisenchantValueAuctionPanel", AuctionHouseFrame, "ButtonFrameTemplate")
	ns.auctionPanel = panel
	-- Above the auction house and Auctionator (MEDIUM). SetToplevel keeps this
	-- window's children together when it is raised, so their text cannot draw
	-- through one another or sit under the auction house list.
	panel:SetFrameStrata("HIGH")
	panel:SetToplevel(true)
	if ButtonFrameTemplate_HidePortrait then ButtonFrameTemplate_HidePortrait(panel) end
	panel:SetWidth(PANEL_WIDTH)
	panel:EnableMouse(true)
	ApplyPosition()

	-- Drag by the title bar or any empty spot (rows and buttons keep their clicks).
	panel:SetMovable(true)
	panel:RegisterForDrag("LeftButton")
	panel:SetScript("OnDragStart", function(self)
		-- Swap the two-point anchor to the auction house for a single corner
		-- point with a fixed height first, so the panel keeps its size while moving.
		local left, top, height = self:GetLeft(), self:GetTop(), self:GetHeight()
		if left and top and height then
			self:ClearAllPoints()
			self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
			self:SetHeight(height)
		end
		self:SetClampedToScreen(true)
		self:StartMoving()
	end)
	panel:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		-- Our own saved position is used, not the client's layout cache.
		if self.SetUserPlaced then self:SetUserPlaced(false) end
		SavePosition()
	end)
	SetTitle(panel, "Disenchant Deals")
	panel:Hide()

	-- The close button hides the panel until the tab opens it again.
	if panel.CloseButton then
		panel.CloseButton:SetScript("OnClick", function() SetPanelWanted(false) end)
	end

	-- Title-bar chrome: reset position, then minimize/restore, then close.
	-- 20px gold line icons, vertically centred on the close button, 2px apart.
	local function TitleBarButton(tooltip)
		local b = CreateFrame("Button", nil, panel)
		b:SetSize(TITLE_BTN_SIZE, TITLE_BTN_SIZE)
		b:EnableMouse(true)
		b:RegisterForClicks("LeftButtonUp")
		b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
			GameTooltip:AddLine(tooltip(self))
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		return b
	end

	local function MatchCloseLevel(b)
		if not panel.CloseButton then return end
		local lvl = panel.CloseButton.GetFrameLevel and panel.CloseButton:GetFrameLevel()
		if type(lvl) == "number" then b:SetFrameLevel(lvl) end
	end

	local minBtn = TitleBarButton(function()
		return IsMinimized() and "Restore" or "Minimize"
	end)
	minBtn.minus = GoldBar(minBtn, 8, 2, 0, 0)
	minBtn.plusH = GoldBar(minBtn, 8, 2, 0, 0)
	minBtn.plusV = GoldBar(minBtn, 2, 8, 0, 0)
	minBtn.plusH:Hide()
	minBtn.plusV:Hide()
	minBtn:SetScript("OnClick", function()
		SetMinimized(not IsMinimized())
	end)
	if panel.CloseButton then
		minBtn:SetPoint("RIGHT", panel.CloseButton, "LEFT", -TITLE_BTN_GAP, 0)
		MatchCloseLevel(minBtn)
	else
		minBtn:SetPoint("TOPRIGHT", -(6 + TITLE_BTN_GAP), -6)
	end
	panel.minButton = minBtn

	-- Target (ring + dot): put the window back beside the auction house.
	local resetBtn = TitleBarButton(function()
		return "Reset position"
	end)
	resetBtn.dot = GoldTarget(resetBtn)
	resetBtn:SetPoint("RIGHT", minBtn, "LEFT", -TITLE_BTN_GAP, 0)
	resetBtn:SetScript("OnClick", function()
		ResetPanelPosition()
	end)
	MatchCloseLevel(resetBtn)
	panel.resetButton = resetBtn

	-- Item name column takes whatever width the others leave.
	local inner = PANEL_WIDTH - 16 - 4 - 26 -- list insets, then header container insets
	local used = 0
	for i = 2, #COLUMNS do used = used + COLUMNS[i].width + COLUMN_GAP end
	COLUMNS[1].width = inner - used

	local scan = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	scan:SetSize(110, 22)
	scan:SetPoint("TOPLEFT", 12, -30)
	scan:SetScript("OnClick", function()
		if scanning then StopScan("Scan stopped.") else StartScan() end
	end)
	panel.scan = scan

	local profitable = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	profitable:SetSize(26, 26)
	profitable:SetPoint("LEFT", scan, "RIGHT", 12, 0)
	profitable:SetScript("OnClick", function(self)
		onlyProfitable = self:GetChecked() and true or false
		local d = DB()
		if d then d.ahOnlyProfitable = onlyProfitable end
		Rebuild()
	end)
	local profitableLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	profitableLabel:SetPoint("LEFT", profitable, "RIGHT", 2, 0)
	profitableLabel:SetText("Only show profitable")
	panel.profitable = profitable

	CreateBracketButtons(panel, scan)

	-- The list area, laid out like Blizzard's AuctionHouseItemListTemplate (the
	-- Mainline version, which this client uses): a header strip on top, then the
	-- Browse list's background in an inset border, and the minimal scroll bar.
	-- That template is load-on-demand and drags in Blizzard's list logic, so it
	-- is rebuilt here with the same values.
	panel.Inset:Hide()
	local list = CreateFrame("Frame", nil, panel)
	list:SetPoint("TOPLEFT", 8, -90)
	list:SetPoint("BOTTOMRIGHT", -8, 28)
	list.layoutType = "InsetFrameTemplate"

	-- The background art stops just before the scroll bar, like Blizzard's list:
	-- its right edge is the divider line, and the scroll bar sits on the darker
	-- window background beside it. (The rows end 26 pixels from the right.)
	local bg = list:CreateTexture(nil, "BACKGROUND")
	bg:SetAtlas("auctionhouse-background-index")
	bg:SetPoint("TOPLEFT", 3, -22)
	bg:SetPoint("BOTTOMRIGHT", -22, 3)

	local border = CreateFrame("Frame", nil, list, "NineSlicePanelTemplate")
	border:SetPoint("TOPLEFT", 0, -19)
	border:SetPoint("BOTTOMRIGHT")
	if NineSliceUtil and NineSliceUtil.ApplyLayoutByName then
		NineSliceUtil.ApplyLayoutByName(border, "InsetFrameTemplate")
	end

	local headerRow = CreateFrame("Frame", nil, list)
	headerRow:SetPoint("TOPLEFT", 4, -1)
	headerRow:SetPoint("TOPRIGHT", -26, -1)
	headerRow:SetHeight(19)
	CreateHeaders(headerRow)

	local scrollBox = CreateFrame("Frame", nil, list, "WowScrollBoxList")
	scrollBox:SetPoint("TOPLEFT", headerRow, "BOTTOMLEFT", 0, -6)
	scrollBox:SetPoint("RIGHT", headerRow, "RIGHT")
	scrollBox:SetPoint("BOTTOM", 0, 3)
	local scrollBar = CreateFrame("EventFrame", nil, list, "MinimalScrollBar")
	scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 9, 0)
	scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 9, 4)
	local scrollView = CreateScrollBoxListLinearView()
	scrollView:SetElementExtent(ROW_HEIGHT)
	scrollView:SetElementInitializer("DisenchantValueDealRowTemplate", InitRow)
	ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, scrollView)
	panel.scrollBox = scrollBox

	local status = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	status:SetPoint("BOTTOMLEFT", 14, 8)
	status:SetPoint("BOTTOMRIGHT", -14, 8)
	status:SetJustifyH("LEFT")
	status:SetText("Press Scan to search the auction house for weapons and armor to disenchant.")
	panel.status = status
	panel.list = list
	panel.profitableLabel = profitableLabel

	panel.body = { scan, profitable, profitableLabel, list, status }
	if panel.bracketButtons then
		for _, b in ipairs(panel.bracketButtons) do
			panel.body[#panel.body + 1] = b
		end
	end

	function panel:UpdateButtons()
		self.scan:SetText(scanning and "Stop" or "Scan")
	end

	panel:SetScript("OnShow", function(self)
		self:Raise()
		SetMinimized(IsMinimized())
		Rebuild()
		UpdateTab()
	end)
	panel:SetScript("OnHide", function()
		if scanning then StopScan() end
		UpdateTab()
	end)

	panel:UpdateButtons()
	panel:UpdateBrackets()
	SetMinimized(IsMinimized())
end

-- A tab under the auction house, after its own tabs, that shows or hides the panel.
local function CreateTab()
	tab = CreateFrame("Button", "DisenchantValueAuctionTab", AuctionHouseFrame, "PanelTabButtonTemplate")
	tab:SetText("Disenchant")
	if PanelTemplates_TabResize then PanelTemplates_TabResize(tab, 0) end
	tab:SetPoint("TOPRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -8, 2)
	tab:SetScript("OnClick", function()
		PlaySound(SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB or 841)
		SetPanelWanted(not (panel and panel:IsShown()))
	end)
	tab:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Disenchant Deals")
		GameTooltip:AddLine("Show or hide the disenchant deals panel.", 1, 1, 1)
		GameTooltip:Show()
	end)
	tab:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

Update = function()
	if not panel or not panel:IsShown() then return end

	for _, c in ipairs(COLUMNS) do
		local arrow = c.header.Arrow
		if c.key == sortKey then
			-- The atlas points down; flip it for ascending (up), like the auction house's own headers.
			if sortDesc then arrow:SetTexCoord(0, 1, 0, 1) else arrow:SetTexCoord(0, 1, 1, 0) end
			arrow:Show()
		else
			arrow:Hide()
		end
	end

	local data = {}
	for i, r in ipairs(view) do
		r.index = i
		data[i] = r
	end
	panel.scrollBox:SetDataProvider(CreateDataProvider(data), ScrollBoxConstants.RetainScrollPosition)
	panel:UpdateButtons()
end

function ns.ShowAuctionPanel()
	if not (AuctionHouseFrame and C_AuctionHouse and C_AuctionHouse.SendBrowseQuery) then return end
	if not panel then
		CreatePanel()
		CreateTab()
	end
	local d = DB()
	onlyProfitable = d and d.ahOnlyProfitable or false
	panel.profitable:SetChecked(onlyProfitable)
	wipe(brackets)
	for i in pairs(d and d.ahBrackets or {}) do brackets[i] = true end
	panel:UpdateBrackets()
	SetMinimized(IsMinimized())
	panel:SetShown(IsPanelWanted())
	UpdateTab()
end

-- Re-price everything (e.g. after new Auctionator prices).
function ns.RefreshAuctionValues()
	for _, r in ipairs(results) do Evaluate(r) end
	Rebuild()
end

function ns.AuctionSlash(msg)
	local cmd, arg = (msg or ""):lower():match("^(%S*)%s*(%S*)")
	if cmd ~= "ah" and cmd ~= "deals" and cmd ~= "ahreset" and cmd ~= "ahscale" and cmd ~= "min" then return false end
	local d = DB()
	if cmd == "ahreset" then
		ResetPanelPosition()
		Print("auction house panel is back beside the auction house")
		return true
	elseif cmd == "min" then
		SetMinimized(not IsMinimized())
		Print("auction house panel " .. (IsMinimized() and "minimized" or "restored"))
		return true
	elseif cmd == "ahscale" then
		local scale = tonumber(arg)
		if not scale or scale < MIN_SCALE or scale > MAX_SCALE then
			Print(("usage: /dv ahscale %.1f-%.1f (now %s)"):format(MIN_SCALE, MAX_SCALE, tostring(d and d.ahPanelScale or 1)))
		else
			SetScaleSaved(scale)
			Print("auction house panel scale " .. scale)
		end
		return true
	end
	local wanted = not IsPanelWanted()
	SetPanelWanted(wanted)
	Print("auction house panel " .. (wanted and "shown" or "hidden"))
	return true
end
