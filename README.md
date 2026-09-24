# Disenchant Value

**Shows what a green or blue item is worth disenchanted, priced from Auctionator, plus a one-button disenchanter.**

Should you vendor that green, sell it on the auction house, or disenchant it? Disenchant Value adds the answer to every weapon and armor tooltip: the expected gold value of the materials you would get from disenchanting it, priced from your own Auctionator scans.

## Tooltip values

Weapon and armor tooltips get two extra lines:

- **Disenchant value (era):** the expected value from the known Classic disenchant tables (uncommon and rare items, item level 1–30), priced from Auctionator.
- **Actual:** the value based on your own disenchants. The addon records what every disenchant gives you and builds its own drop rates from that, grouped by item type, quality and item level. The number in brackets is how many disenchants it is based on.
	- `~` means there are no samples for that exact item level yet, so a nearby level range is used.
	- `*` means some of the materials have no auction price yet.

Tooltips also show the item level of any weapon or armor, if the game doesn't already.

Prices come from Auctionator (optional, but without it the addon has no prices). Choose between Auctionator's average price over recent days (`/dv mean`, the default) or the latest scan (`/dv latest`).

## Disenchant button

A **Disenchant** button sits under your backpack and shows how many items are waiting. Each press disenchants the next green weapon or armor piece in your bags. WoW allows one spell per click, so you press once per item.

- It skips items on your ignore list.
- With the auction house check on, it also skips items that sell for more on the auction house than they would give disenchanted.
- Bind it to a key under Game Menu → Options → Keybindings → AddOns → Disenchant Value.
- Turn on auto loot (`/console autoLootDefault 1`) so the materials go straight to your bags.

## Commands

| Command | What it does |
|---|---|
| `/dv stats` | How many disenchants have been recorded |
| `/dv mean` / `/dv latest` | Price by recent average or by latest scan |
| `/dv reset` | Clear all learned disenchant data |
| `/dv button` | Show or hide the disenchant button |
| `/dv list` | List what the button will disenchant, and what it skips and why |
| `/dv ignore [item]` / `/dv unignore [item]` | Never (or again) disenchant an item. Shift-click the item into chat |
| `/dv ahcheck on\|off` | Skip items worth more on the auction house |
| `/dv attach on\|off` | Attach the button to your bags, or make it free-floating (right-drag to move) |

## For addon authors

Other addons can read the values. Both take an item link or item ID and return copper, or `nil` if the item can't be disenchanted or has no price:

- `DisenchantValueAPI.GetValue(item)`: the learned value, or the era table value if there is no learned data yet.
- `DisenchantValueAPI.GetEraValue(item)`: the era table value only.

Auctionator's "DE Value" column uses this.
