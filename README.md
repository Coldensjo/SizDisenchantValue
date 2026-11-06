# Disenchant Value

**Shows what a green or blue item is worth disenchanted, priced from Auctionator, plus a one-button disenchanter.**

Should you vendor that green, sell it on the auction house, or disenchant it? Disenchant Value adds the answer to every weapon and armor tooltip: the expected gold value of the materials you would get from disenchanting it, priced from your own Auctionator scans.

## Tooltip value

Uncommon, rare and epic weapon and armor tooltips get a **Disenchant value** line: the average worth of what the item disenchants into. Every possible result in the Classic disenchant table counts by its chance and average quantity, priced at its latest auction house price. It is the same value as the **DE value** column in the auction house panel.

- `*` means some of the materials have no auction price yet, so the value is too low.

Prices come from your latest Auctionator scan (Auctionator is optional, but without it the addon has no prices).

## Disenchant button

A **Disenchant** button sits under your backpack and shows how many items are waiting. Each press disenchants the next green weapon or armor piece in your bags. WoW allows one spell per click, so you press once per item.

- It only shows while your bags are open. It works with Blizzard's bags and with bag addons such as Bagnon, Baganator, AdiBags, ArkInventory and ElvUI.
- **Hold Alt and drag** the button to move it. Drop it on any window to attach it there, or anywhere on the screen. Wherever it is, it still only shows while your bags are open. `/dv attach` puts it back under your bags.
- It skips items on your ignore list.
- With the auction house check on, it also skips items that sell for more on the auction house than they would give disenchanted.
- Bind it to a key under Game Menu → Options → Keybindings → AddOns → Disenchant Value.
- Turn on auto loot (`/console autoLootDefault 1`) so the materials go straight to your bags.

## Auction house deals

When you open the auction house, a **Disenchant Deals** panel opens next to it, styled like the auction house itself. The **Disenchant** tab under the auction house window shows or hides it, and it remembers your choice. Press **Scan** to search the auction house for every uncommon, rare and epic weapon and armor piece. Each item is listed with its lowest price, its expected disenchant value and the profit (disenchant value minus price).

- Click a column header to sort by it; click again to reverse the order. The default is highest profit first.
- Tick **Only show profitable** to hide items that cost more than they disenchant for.
- The bracket buttons (1-15, 16-20, ... 61+) filter by disenchant item level bracket, so you can hunt for the materials you want. Tick several to combine them; **All** clears the filter. Hover a bracket to see which dust, essence and shard it gives.
- Prices are shown in gold, silver and copper with coin icons.
- **Quick buy:** click a row to buy the cheapest one of that item straight away, with no confirmation prompt.
	- Resting the mouse on a row checks its current price, so the click can buy at once. If the price isn't checked yet, the click checks it, and the next click buys.
	- A click only ever buys at the price the row shows. After a buy, the row updates to the next cheapest one, so you can keep clicking to buy more at that price.
	- If the cheapest one now costs more than the list showed, the row turns orange with a **Price went up** warning. Your next click only confirms the new price; the click after that buys.
	- Your own auctions are never bought.
- Right-click a row to open the item in the auction house's buy view. Shift-click links it in chat.
- **DE value** is the average worth of what the item disenchants into, priced from your latest Auctionator scan. Every possible result in the disenchant table counts by its chance and average quantity. For example, 75% for 1-2 Strange Dust and 25% for 1-2 Lesser Magic Essence is worth 0.75 × 1.5 × the dust price + 0.25 × 1.5 × the essence price. Your own disenchant results are not used here. The disenchant button's auction house check uses the same value.

## Commands

| Command | What it does |
|---|---|
| `/dv stats` | How many disenchants have been recorded |
| `/dv reset` | Clear all learned disenchant data |
| `/dv button` | Show or hide the disenchant button |
| `/dv list` | List what the button will disenchant, and what it skips and why |
| `/dv ignore [item]` / `/dv unignore [item]` | Never (or again) disenchant an item. Shift-click the item into chat |
| `/dv ahcheck on\|off` | Skip items worth more on the auction house |
| `/dv ah` | Show or hide the auction house deals panel (same as the Disenchant tab) |
| `/dv attach` | Put the disenchant button back under your bags |

## For addon authors

Other addons can read the values. Both take an item link or item ID and return copper, or `nil` if the item can't be disenchanted or has no price:

- `DisenchantValueAPI.GetValue(item)`: the learned value, or the era table value if there is no learned data yet.
- `DisenchantValueAPI.GetEraValue(item)`: the era table value only.

Auctionator's "DE Value" column uses this.
